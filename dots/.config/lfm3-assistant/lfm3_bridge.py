#!/usr/bin/env python3
"""JSON-lines bridge between the native Quickshell UI and llama-server.

Reads one JSON command per line on stdin, writes one JSON event per line on
stdout. Logs and any child process output go to stderr (or a log file), never
to stdout. See docs/bridge.md for the full protocol.
"""

from __future__ import annotations

import argparse
import base64
import json
import logging
import math
import mimetypes
import os
import queue
import re
import shlex
import shutil
import signal
import subprocess
import sys
import threading
import time
from array import array
from collections import Counter
from datetime import datetime
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import quote, urlsplit

try:
    import httpx
except ImportError:  # pragma: no cover - checked at startup
    httpx = None  # type: ignore[assignment]

try:
    from websockets.exceptions import WebSocketException
    from websockets.sync.client import connect as ws_connect
except ImportError:  # pragma: no cover - checked at startup
    WebSocketException = Exception  # type: ignore[assignment,misc]
    ws_connect = None  # type: ignore[assignment]


LOG = logging.getLogger("lfm3-bridge")

DEFAULT_CONFIG_HOME = Path.home() / ".config" / "lfm3-assistant"
DEFAULT_MODELS_CACHE = Path.home() / ".models/hub"
DEFAULT_MODELS_PRESET = DEFAULT_CONFIG_HOME / "models.ini"
DEFAULT_LLAMA_SERVER = "/home/soymh/SoyMH/llama.cpp/build/bin/llama-server"
DEFAULT_DIGUP = Path.home() / ".local/bin/digup-linux"
DEFAULT_MCP_CONFIG = DEFAULT_CONFIG_HOME / "mcp.json"
DEFAULT_STATE_DIR = Path.home() / ".local/state/lfm3-assistant"

# Sharded GGUF: model-00001-of-00004.gguf
SHARD_RE = re.compile(r"^(?P<prefix>.+?)-(?P<index>\d{5})-of-(?P<total>\d{5})$")
# Quantization suffix in a file stem: Q4_K_M, IQ4_NL, UD-Q4_K_XL, BF16, ...
QUANT_RE = re.compile(
    r"(?:^|[-_])(?P<tag>(?:UD-)?(?:IQ|Q)\d[0-9A-Za-z_]*|BF16|F16|F32|F64)$",
    re.IGNORECASE,
)
# llama-server canonicalizes only the last [-.] token of a preset tag.
CANON_TAG_RE = re.compile(r"[-.]([A-Z0-9_]+)$", re.IGNORECASE)

MAX_TOOL_ROUNDS = 6
MAX_TOOL_RESULT_CHARS = 8000
MAX_DIGUP_QUERY = 256
MAX_DIGUP_RESULTS = 20
MAX_DIGUP_EXCERPT = 400

# Localhost control API (Translator tab and other local clients).
TRANSLATE_BACKENDS = {"llama", "trans"}
TRANSLATE_ENGINES = {"auto", "google", "bing", "yandex"}
MAX_TRANSLATE_CHARS = 6000
TRANS_BIN = "/usr/bin/trans"
TRANS_TIMEOUT = 30.0

# Text attachments.
MAX_ATTACHMENTS = 8
# llama-server checks file:// paths against this limit (fs_validate_filename).
MAX_MEDIA_REL_CHARS = 255
IMAGE_MIME = {
    ".png": "image/png",
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
    ".webp": "image/webp",
    ".gif": "image/gif",
    ".bmp": "image/bmp",
}
VIDEO_MIME = {
    ".mp4": "video/mp4",
    ".mkv": "video/x-matroska",
    ".webm": "video/webm",
    ".mov": "video/quicktime",
    ".avi": "video/x-msvideo",
    ".m4v": "video/x-m4v",
}
AUDIO_MIME = {
    ".wav": "audio/wav",
    ".mp3": "audio/mpeg",
    ".flac": "audio/flac",
    ".ogg": "audio/ogg",
    ".opus": "audio/opus",
    ".m4a": "audio/mp4",
    ".aac": "audio/aac",
}
MEDIA_RESULT_KINDS = {"screenshot", "image", "video", "audio"}

# Voice (push-to-talk over /v1/realtime).
VOICE_CHUNK_MS = 100
VOICE_RESPONSE_TIMEOUT = 300.0
VOICE_WS_MAX_SIZE = 64 * 1024 * 1024

SYSTEM_PROMPT = (
    "You are a concise local desktop assistant running on the user's Linux "
    "machine. Answer in the user's language. Use digup_search when the user "
    "asks about local files, screenshots, audio, video, PDFs, or documents. "
    "Use the other tools only when they are clearly needed. Tool results are "
    "JSON; do not invent file paths."
)

# Tools that are implemented inside this bridge rather than by llama-server.
LOCAL_TOOLS: list[dict[str, Any]] = [
    {
        "type": "function",
        "function": {
            "name": "digup_search",
            "description": (
                "Semantic search over the user's local indexed files "
                "(screenshots, images, PDFs, documents, audio, video). "
                "Read-only: returns paths and snippets, never file contents."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "query": {"type": "string", "description": "Search text"},
                    "limit": {
                        "type": "integer",
                        "description": "Max results, 1-20",
                        "minimum": 1,
                        "maximum": 20,
                    },
                    "kind": {
                        "type": "string",
                        "description": "Optional media kind filter",
                        "enum": [
                            "screenshot",
                            "image",
                            "pdf",
                            "doc",
                            "audio",
                            "video",
                        ],
                    },
                },
                "required": ["query"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "get_local_time",
            "description": "Return the current local date and time.",
            "parameters": {"type": "object", "properties": {}},
        },
    },
    {
        "type": "function",
        "function": {
            "name": "set_timer",
            "description": "Start a countdown timer. Fires a timer event later.",
            "parameters": {
                "type": "object",
                "properties": {
                    "seconds": {
                        "type": "integer",
                        "description": "Duration in seconds, 1-86400",
                        "minimum": 1,
                        "maximum": 86400,
                    },
                    "label": {"type": "string", "description": "Timer label"},
                },
                "required": ["seconds"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "cancel_timer",
            "description": "Cancel one timer by label, or all timers.",
            "parameters": {
                "type": "object",
                "properties": {
                    "label": {"type": "string", "description": "Timer label"},
                },
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "get_connection",
            "description": "Report local model server connection status.",
            "parameters": {"type": "object", "properties": {}},
        },
    },
    {
        "type": "function",
        "function": {
            "name": "copy_to_clipboard",
            "description": "Copy plain text to the Wayland clipboard.",
            "parameters": {
                "type": "object",
                "properties": {
                    "text": {"type": "string", "description": "Text to copy"},
                },
                "required": ["text"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "set_theme",
            "description": "Switch the assistant UI theme.",
            "parameters": {
                "type": "object",
                "properties": {
                    "theme": {
                        "type": "string",
                        "enum": ["dark", "light", "auto"],
                    },
                },
                "required": ["theme"],
            },
        },
    },
]

LOCAL_TOOL_NAMES = {t["function"]["name"] for t in LOCAL_TOOLS}


class BridgeError(Exception):
    """A failure that should be reported to the UI as an error event."""


class TurnCancelled(Exception):
    """The current turn was cancelled by the UI."""


class VoiceError(Exception):
    """Voice session failure reported to the UI as an error event."""


class ControlError(Exception):
    """HTTP control API error with a status code."""

    def __init__(self, status: int, message: str):
        super().__init__(message)
        self.status = status


@dataclass
class VoiceState:
    text: str = ""
    chunks: int = 0
    user_emitted: bool = False
    response_seen: bool = False
    response_done: bool = False
    awaiting_response: bool = False
    speech_started: bool = False
    in_rate: int = 16000
    out_rate: int = 24000
    capture_proc: subprocess.Popen[bytes] | None = None
    playback_proc: subprocess.Popen[bytes] | None = None
    playback_failed: bool = False
    error: str | None = None


class Config:
    def __init__(self, values: dict[str, str]):
        # Optional single-model override. When unset the bridge runs a router
        # and scans the Hugging Face cache for GGUF files.
        model = values.get("MODEL") or ""
        self.model_override = Path(os.path.expanduser(model)) if model else None
        mmproj = values.get("MMPROJ") or ""
        self.mmproj_override = Path(os.path.expanduser(mmproj)) if mmproj else None
        self.models_cache = Path(
            os.path.expanduser(
                values.get("MODELS_CACHE") or str(DEFAULT_MODELS_CACHE)
            )
        )
        self.models_preset = Path(
            os.path.expanduser(
                values.get("MODELS_PRESET") or str(DEFAULT_MODELS_PRESET)
            )
        )
        self.models_max = _int(values.get("MODELS_MAX"), 1, 1, 64)
        self.models_memory_margin = _int(
            values.get("MODELS_MEMORY_MARGIN"), 256, 0, 1048576
        )
        self.default_model = (values.get("DEFAULT_MODEL") or "").strip()
        self.llama_server = values.get("LLAMA_SERVER") or DEFAULT_LLAMA_SERVER
        self.host = "127.0.0.1"
        self.port = _int(values.get("PORT"), 8011, 1, 65535)
        self.ctx = _int(values.get("CTX"), 16384, 512, 262144)
        self.idle_timeout = _int(values.get("IDLE_TIMEOUT"), 300, 0, 86400)
        self.load_timeout = _int(values.get("LOAD_TIMEOUT"), 240, 10, 3600)
        self.mcp_config = Path(
            os.path.expanduser(values.get("MCP_CONFIG") or str(DEFAULT_MCP_CONFIG))
        )
        self.digup_bin = Path(
            os.path.expanduser(values.get("DIGUP_BIN") or str(DEFAULT_DIGUP))
        )
        self.digup_limit = _int(values.get("DIGUP_LIMIT"), 8, 1, MAX_DIGUP_RESULTS)
        media_path = values.get("MEDIA_PATH") or os.path.expanduser("~")
        self.media_path = Path(os.path.realpath(os.path.expanduser(media_path)))
        self.media_max_mb = _int(values.get("MEDIA_MAX_MB"), 20, 1, 512)
        self.allow_write_tools = _bool(values.get("ALLOW_WRITE_TOOLS"), False)
        self.log_file = Path(
            os.path.expanduser(
                values.get("LLAMA_LOG") or str(DEFAULT_STATE_DIR / "llama-server.log")
            )
        )
        self.extra_args = _split_args(values.get("EXTRA_ARGS", ""))
        self.mic_device = (values.get("MIC_DEVICE") or "").strip()
        self.mic_rate = _int(values.get("MIC_RATE"), 16000, 8000, 192000)
        self.speaker_device = (values.get("SPEAKER_DEVICE") or "").strip()
        self.voice_output_rate = _int(
            values.get("VOICE_OUTPUT_RATE"), 24000, 8000, 192000
        )
        self.voice_instructions = (
            values.get("VOICE_INSTRUCTIONS")
            or "Respond with interleaved text and audio."
        )
        self.voice_volume = _float(values.get("VOICE_VOLUME"), 0.2, 0.0, 1.0)
        self.speak_text = _bool(values.get("SPEAK_TEXT"), True)
        self.tts_voice = (values.get("TTS_VOICE") or "female").strip()
        self.tts_max_chars = _int(values.get("TTS_MAX_CHARS"), 1200, 80, 4000)
        self.control_port = _int(values.get("CONTROL_PORT"), 8013, 1, 65535)
        backend = (values.get("TRANSLATE_BACKEND") or "llama").strip().lower()
        self.translate_backend = backend if backend in TRANSLATE_BACKENDS else "llama"
        engine = (values.get("TRANSLATE_ENGINE") or "auto").strip().lower()
        self.translate_engine = engine if engine in TRANSLATE_ENGINES else "auto"

    @property
    def base_url(self) -> str:
        return f"http://{self.host}:{self.port}"

    def server_args(self) -> list[str]:
        """Global router arguments, inherited by every model instance."""
        args = [
            "--models-preset", str(self.models_preset),
            "--models-max", str(self.models_max),
            "--models-memory-margin", str(self.models_memory_margin),
            "--ctx-size", str(self.ctx),
            "--no-mmproj-offload",
            "--flash-attn", "on",
            "--cache-type-k", "q8_0",
            "--cache-type-v", "q8_0",
            "--parallel", "1",
            "--host", self.host,
            "--port", str(self.port),
        ]
        if self.mcp_config.is_file():
            args += ["--mcp-servers-config", str(self.mcp_config)]
        # file:// media URLs resolve relative to this directory. It must exist.
        if self.media_path.is_dir():
            args += ["--media-path", str(self.media_path)]
        else:
            LOG.warning("MEDIA_PATH is not a directory: %s", self.media_path)
        args += self.extra_args
        return args


def _int(value: str | None, default: int, low: int, high: int) -> int:
    text = str(value).strip()
    try:
        number = int(text)
    except (TypeError, ValueError):
        try:
            number = int(float(text))
        except (TypeError, ValueError):
            return default
    return max(low, min(high, number))


def _bool(value: str | None, default: bool) -> bool:
    if value is None:
        return default
    return str(value).strip().lower() in {"1", "true", "yes", "on"}


def _float(value: str | None, default: float, low: float, high: float) -> float:
    try:
        number = float(str(value).strip())
    except (TypeError, ValueError):
        return default
    return max(low, min(high, number))


def _media_kind(path: Path) -> tuple[str | None, str | None]:
    """Return (kind, mime) for a media path, or (None, None) when unsupported."""
    suffix = path.suffix.lower()
    if suffix in IMAGE_MIME:
        return "image", IMAGE_MIME[suffix]
    if suffix in VIDEO_MIME:
        return "video", VIDEO_MIME[suffix]
    if suffix in AUDIO_MIME:
        return "audio", AUDIO_MIME[suffix]
    return None, None


def _message_size(message: dict[str, Any]) -> int:
    """Approximate history cost, ignoring base64 payloads of media parts."""
    content = message.get("content")
    size = 64
    if isinstance(content, str):
        return size + len(content)
    if isinstance(content, list):
        for part in content:
            if not isinstance(part, dict):
                continue
            if part.get("type") == "text":
                size += len(str(part.get("text") or ""))
            else:
                size += 4096
    return size


def _pcm16_rms(data: bytes) -> float:
    usable = len(data) - (len(data) % 2)
    if usable <= 0:
        return 0.0
    samples = array("h")
    samples.frombytes(data[:usable])
    if sys.byteorder == "big":
        samples.byteswap()
    if not samples:
        return 0.0
    total = sum(sample * sample for sample in samples)
    return min(1.0, math.sqrt(total / len(samples)) / 32768.0)


def _json_or_none(raw: Any) -> dict[str, Any] | None:
    if isinstance(raw, bytes):
        raw = raw.decode("utf-8", "replace")
    try:
        event = json.loads(raw)
    except (TypeError, ValueError):
        return None
    return event if isinstance(event, dict) else None


def _voice_event_error(event: dict[str, Any]) -> str:
    error = event.get("error")
    if isinstance(error, dict):
        return str(error.get("message") or error.get("type") or error)
    if isinstance(error, str) and error:
        return error
    return str(event.get("message") or "voice server error")


def _voice_rates(created: dict[str, Any], state: VoiceState) -> tuple[int, int]:
    session = created.get("session")
    if not isinstance(session, dict):
        session = {}
    audio = session.get("audio")
    if not isinstance(audio, dict):
        audio = {}

    def rate(block: Any, fallback: int) -> int:
        if not isinstance(block, dict):
            return fallback
        audio_format = block.get("format")
        if not isinstance(audio_format, dict):
            return fallback
        try:
            value = int(audio_format.get("rate") or fallback)
        except (TypeError, ValueError):
            return fallback
        return value if 8000 <= value <= 192000 else fallback

    return (
        rate(audio.get("input"), state.in_rate),
        rate(audio.get("output"), state.out_rate),
    )


def _split_args(value: str) -> list[str]:
    return shlex.split(value) if value else []


@dataclass
class ModelEntry:
    id: str
    name: str
    path: Path
    mmproj: Path | None
    size: int

    def event(self, loaded: bool) -> dict[str, Any]:
        return {
            "id": self.id,
            "name": self.name,
            "size": self.size,
            "loaded": loaded,
        }


def _stat_size(path: Path) -> int:
    try:
        size = path.stat().st_size
    except OSError:
        return 0
    return size if size > 0 else 0


def _repo_id_from_cache_dir(path: Path) -> str:
    name = path.name
    slug = name[len("models--"):] if name.startswith("models--") else name
    org, sep, repo = slug.partition("--")
    return f"{org}/{repo}" if sep else slug


def _sanitize_id(text: str) -> str:
    text = re.sub(r"[\[\]\r\n=]", "", text)
    return re.sub(r"\s+", "-", text.strip())


def _quant_tag(stem: str) -> str:
    match = QUANT_RE.search(stem)
    return match.group("tag").upper() if match else ""


def _group_shards(files: list[Path]) -> list[list[Path]]:
    """Group shards of one model; other files stay on their own."""
    groups = [[f] for f in files if not SHARD_RE.match(f.stem)]
    shards: dict[tuple[str, int], list[tuple[int, Path]]] = {}
    for file in files:
        match = SHARD_RE.match(file.stem)
        if match is None:
            continue
        key = (match.group("prefix"), int(match.group("total")))
        shards.setdefault(key, []).append((int(match.group("index")), file))
    for (prefix, total), items in shards.items():
        items.sort()
        indices = [index for index, _ in items]
        if len(items) == total and indices == list(range(1, total + 1)):
            groups.append([file for _, file in items])
        else:
            LOG.warning(
                "skipping incomplete shard set %s (%d/%d)", prefix, len(items), total
            )
    return groups


def _logical_stem(main: Path) -> str:
    match = SHARD_RE.match(main.stem)
    return match.group("prefix") if match else main.stem


def _pick_mmproj(candidates: list[Path], main_stem: str) -> Path | None:
    if not candidates:
        return None
    if len(candidates) == 1:
        return candidates[0]
    tokens = set(re.split(r"[-_.]", main_stem.lower()))

    def score(path: Path) -> int:
        return len(tokens & set(re.split(r"[-_.]", path.stem.lower())))

    return max(sorted(candidates), key=score)


def _canonical_tag(tag: str) -> str:
    """Match llama-server's preset tag canonicalization."""
    match = CANON_TAG_RE.search(tag)
    return (match.group(1) if match else tag).upper()


def _unique_id(base: str, used: set[str]) -> str:
    candidate = base
    counter = 2
    while candidate in used:
        candidate = f"{base}-{counter}"
        counter += 1
    used.add(candidate)
    return candidate


def _router_id(repo_id: str, stem: str, unique_tag: bool, used: set[str]) -> str:
    """Build an id that survives llama-server preset canonicalization."""
    quant = _quant_tag(stem)
    if unique_tag and quant:
        # org/repo:Q4_K_M survives because the tag is already canonical.
        base = _sanitize_id(f"{repo_id}:{_canonical_tag(quant)}")
    else:
        # No colon: llama-server leaves the section name untouched.
        base = _sanitize_id(f"{repo_id}/{stem}")
    return _unique_id(base, used)


def discover_models(cache_dir: Path) -> list[ModelEntry]:
    """Scan a Hugging Face cache for GGUF snapshots and group mmproj/shard files."""
    if not cache_dir.is_dir():
        LOG.warning("models cache not found: %s", cache_dir)
        return []
    candidates: list[dict[str, Any]] = []
    seen_paths: set[str] = set()
    for repo_dir in sorted(cache_dir.glob("models--*")):
        if not repo_dir.is_dir():
            continue
        snapshots = repo_dir / "snapshots"
        if not snapshots.is_dir():
            continue
        for snapshot in sorted(snapshots.iterdir()):
            if not snapshot.is_dir():
                continue
            directories = {
                file.parent for file in snapshot.rglob("*.gguf") if file.is_file()
            }
            for directory in sorted(directories):
                files = [
                    file
                    for file in sorted(directory.glob("*.gguf"))
                    if file.is_file()
                    and not file.name.startswith(".")
                    and _stat_size(file) > 0
                ]
                if not files:
                    continue
                mmprojs = [
                    file for file in files if file.name.lower().startswith("mmproj")
                ]
                mains = [file for file in files if file not in mmprojs]
                if not mains:
                    continue
                if not mmprojs and directory != snapshot:
                    mmprojs = [
                        file
                        for file in sorted(snapshot.glob("mmproj*.gguf"))
                        if file.is_file() and _stat_size(file) > 0
                    ]
                repo_id = _repo_id_from_cache_dir(repo_dir)
                for group in _group_shards(mains):
                    main = group[0]
                    real = os.path.realpath(main)
                    if real in seen_paths:
                        continue
                    seen_paths.add(real)
                    stem = _logical_stem(main)
                    lowered = stem.lower()
                    mmproj = None
                    if not lowered.startswith(("dflash", "draft")):
                        mmproj = _pick_mmproj(mmprojs, stem)
                    candidates.append(
                        {
                            "repo": repo_id,
                            "stem": stem,
                            "path": main,
                            "mmproj": mmproj,
                            "size": sum(_stat_size(file) for file in group),
                        }
                    )

    # llama-server canonicalizes the tag after ':' to its last [-.] token and
    # collapses sections that end up with the same name. Give such models a
    # colon-free id instead, which the router keeps verbatim.
    by_repo: dict[str, list[dict[str, Any]]] = {}
    for candidate in candidates:
        by_repo.setdefault(candidate["repo"], []).append(candidate)
    used_ids: set[str] = set()
    entries: list[ModelEntry] = []
    for repo_id, items in by_repo.items():
        tag_counts = Counter(
            _canonical_tag(_quant_tag(item["stem"]))
            for item in items
            if _quant_tag(item["stem"])
        )
        for item in items:
            quant = _quant_tag(item["stem"])
            unique_tag = bool(quant) and tag_counts[_canonical_tag(quant)] == 1
            entries.append(
                ModelEntry(
                    id=_router_id(repo_id, item["stem"], unique_tag, used_ids),
                    name=_logical_stem(item["path"]),
                    path=item["path"],
                    mmproj=item["mmproj"],
                    size=item["size"],
                )
            )
    entries.sort(key=lambda entry: entry.id.lower())
    return entries


def _model_id_from_path(path: Path, cache_dir: Path, used: set[str]) -> str:
    real = path.resolve()
    try:
        relative = real.relative_to(cache_dir.resolve())
    except (OSError, ValueError):
        relative = None
    repo_id = "local"
    if (
        relative is not None
        and len(relative.parts) >= 4
        and relative.parts[0].startswith("models--")
    ):
        repo_id = _repo_id_from_cache_dir(Path(relative.parts[0]))
    return _router_id(repo_id, path.stem, True, used)


def single_model_entry(config: "Config") -> ModelEntry | None:
    """Build the one preset used when MODEL overrides cache scanning."""
    path = config.model_override
    if path is None:
        return None
    if not path.is_file() or _stat_size(path) <= 0:
        LOG.warning("MODEL is not a readable non-empty file: %s", path)
        return None
    mmproj = config.mmproj_override
    if mmproj is not None and not mmproj.is_file():
        LOG.warning("MMPROJ is not a readable file: %s", mmproj)
        mmproj = None
    if mmproj is None:
        siblings = [
            file
            for file in sorted(path.parent.glob("mmproj*.gguf"))
            if file.is_file() and _stat_size(file) > 0
        ]
        mmproj = siblings[0] if siblings else None
    return ModelEntry(
        id=_model_id_from_path(path, config.models_cache, set()),
        name=path.stem,
        path=path,
        mmproj=mmproj,
        size=_stat_size(path),
    )


def write_presets(path: Path, models: list[ModelEntry]) -> None:
    """Write router presets atomically. Global args stay on the command line."""
    lines = ["version = 1", ""]
    for model in models:
        lines.append(f"[{model.id}]")
        lines.append(f"model = {model.path}")
        if model.mmproj is not None:
            lines.append(f"mmproj = {model.mmproj}")
        lines.append("load-on-startup = false")
        lines.append("")
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        temporary = path.with_name(path.name + ".tmp")
        temporary.write_text("\n".join(lines), encoding="utf-8")
        os.replace(temporary, path)
    except OSError as exc:
        raise BridgeError(f"cannot write models preset {path}: {exc}") from exc
    LOG.info("wrote %d model preset(s) to %s", len(models), path)


def read_env_file(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[len("export "):].strip()
        key, sep, value = line.partition("=")
        if not sep:
            continue
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        values[key.strip()] = os.path.expandvars(value)
    return values


def load_config(path: str | None) -> Config:
    values: dict[str, str] = {}
    config_path = path or os.environ.get("LFM3_CONFIG")
    if not config_path:
        user_config = DEFAULT_CONFIG_HOME / "config.env"
        if user_config.is_file():
            config_path = str(user_config)
    if config_path:
        file = Path(os.path.expanduser(config_path))
        if file.is_file():
            LOG.info("reading config: %s", file)
            values.update(read_env_file(file))
        else:
            LOG.warning("config file not found: %s", file)
    # Environment overrides the config file.
    for key in (
        "MODEL", "MMPROJ", "MODELS_CACHE", "MODELS_PRESET", "MODELS_MAX",
        "MODELS_MEMORY_MARGIN", "DEFAULT_MODEL", "LLAMA_SERVER", "PORT", "CTX",
        "IDLE_TIMEOUT", "LOAD_TIMEOUT", "MCP_CONFIG", "DIGUP_BIN",
        "DIGUP_LIMIT", "MEDIA_PATH", "MEDIA_MAX_MB", "ALLOW_WRITE_TOOLS",
        "LLAMA_LOG", "EXTRA_ARGS",
        "MIC_DEVICE", "MIC_RATE", "SPEAKER_DEVICE", "VOICE_OUTPUT_RATE",
        "VOICE_INSTRUCTIONS", "VOICE_VOLUME", "SPEAK_TEXT", "TTS_VOICE",
        "TTS_MAX_CHARS", "CONTROL_PORT", "TRANSLATE_BACKEND",
        "TRANSLATE_ENGINE",
    ):
        if os.environ.get(key):
            values[key] = os.environ[key]
    return Config(values)


class Bridge:
    def __init__(self, config: Config):
        self.config = config
        self._out_lock = threading.Lock()
        self._server_lock = threading.RLock()
        self._turn_lock = threading.Lock()
        self._cancel = threading.Event()
        self._stop = threading.Event()
        self._busy = False
        self._turn_thread: threading.Thread | None = None
        self._messages: list[dict[str, Any]] = [
            {"role": "system", "content": SYSTEM_PROMPT}
        ]
        self._timers: dict[str, threading.Timer] = {}
        self._timer_lock = threading.Lock()
        self._theme = "dark"
        self._last_activity = time.monotonic()
        self._client = httpx.Client(
            timeout=httpx.Timeout(connect=10.0, read=300.0, write=30.0, pool=10.0),
            trust_env=False,
        ) if httpx else None
        self._server_proc: subprocess.Popen[bytes] | None = None
        self._server_log = None
        self._owns_server = False
        self._server_tools: list[dict[str, Any]] | None = None
        self._partial_text = ""
        self._models: list[ModelEntry] = []
        self._models_lock = threading.Lock()
        self._current_model: str | None = None
        self._voice_lock = threading.Lock()
        self._voice_thread: threading.Thread | None = None
        self._voice_stop_capture = threading.Event()
        self._voice_cancel = threading.Event()
        self._speak_text = config.speak_text
        self._control: ControlServer | None = None

    # ------------------------------------------------------------------ output

    def emit(self, payload: dict[str, Any]) -> None:
        line = json.dumps(payload, ensure_ascii=False)
        with self._out_lock:
            try:
                sys.stdout.write(line + "\n")
                sys.stdout.flush()
            except (BrokenPipeError, ValueError):
                self._stop.set()

    def emit_error(self, message: str, code: str = "error") -> None:
        LOG.warning("%s: %s", code, message)
        self.emit({"type": "error", "code": code, "message": message})

    def touch(self) -> None:
        self._last_activity = time.monotonic()

    # ----------------------------------------------------------------- models

    def scan_models(self) -> list[ModelEntry]:
        """Rescan the cache (or MODEL override) and rewrite the preset file."""
        if self.config.model_override is not None:
            entry = single_model_entry(self.config)
            models = [entry] if entry is not None else []
        else:
            models = discover_models(self.config.models_cache)
        with self._models_lock:
            self._models = models
        for model in models:
            LOG.info("model %s -> %s", model.id, model.path)
        if models:
            write_presets(self.config.models_preset, models)
        else:
            LOG.warning("no GGUF models found in %s", self.config.models_cache)
        return models

    def models_snapshot(self) -> list[ModelEntry]:
        with self._models_lock:
            return list(self._models)

    def current_model(self) -> str | None:
        # "" is the explicit "everything unloaded" state; None means the user
        # has not picked one yet, so fall back to the first discovered model.
        if self._current_model is not None:
            return self._current_model or None
        models = self.models_snapshot()
        return models[0].id if models else None

    def no_models_message(self) -> str:
        if self.config.model_override is not None:
            return f"MODEL not found or empty: {self.config.model_override}"
        return (
            f"no GGUF models found in {self.config.models_cache}; "
            "set MODELS_CACHE or MODEL"
        )

    def _select_initial_model(self, available: list[str] | None = None) -> str | None:
        models = self.models_snapshot()
        ids = available if available is not None else [m.id for m in models]
        if not ids:
            return None
        wanted = self.config.default_model
        if wanted:
            if wanted in ids:
                return wanted
            for model in models:
                if wanted in (model.name, model.path.name, model.path.stem):
                    return model.id
            LOG.warning("DEFAULT_MODEL %r not found, preferring a local LFM3 model", wanted)
        # The cache contains many unrelated GGUFs. Prefer a conversational
        # LFM3 model when no explicit default is configured.
        for key in ("lfm3-omni", "lfm3-audio", "lfm3"):
            for model_id in ids:
                if key in model_id.lower():
                    return model_id
        return ids[0]

    def _router_entries(
        self, reload: bool = False, timeout: float = 10.0
    ) -> list[dict[str, Any]] | None:
        """GET /models from a running router, without starting one."""
        if self._client is None or not self._health(timeout=1.0):
            return None
        url = f"{self.config.base_url}/models"
        if reload:
            url += "?reload=1"
        try:
            response = self._client.get(url, timeout=timeout)
            response.raise_for_status()
            data = response.json().get("data")
        except Exception as exc:
            LOG.warning("GET /models failed: %s", exc)
            return None
        if not isinstance(data, list):
            return None
        return [entry for entry in data if isinstance(entry, dict) and entry.get("id")]

    def _models_payload(
        self, router_entries: list[dict[str, Any]] | None = None
    ) -> list[dict[str, Any]]:
        """Build the model list shared by the stdout event and the control API."""
        models = self.models_snapshot()
        if router_entries is None:
            router_entries = self._router_entries()
        by_id: dict[str, dict[str, Any]] = {}
        by_path: dict[str, dict[str, Any]] = {}
        for entry in router_entries or []:
            by_id[str(entry["id"])] = entry
            path = entry.get("path")
            if path:
                by_path[os.path.realpath(str(path))] = entry

        def router_entry(model: ModelEntry) -> dict[str, Any] | None:
            entry = by_id.get(model.id)
            if entry is None:
                entry = by_path.get(os.path.realpath(model.path))
            return entry

        def loaded(entry: dict[str, Any] | None) -> bool:
            if not entry:
                return False
            status = entry.get("status") or {}
            return status.get("value") in ("loaded", "sleeping")

        payload = []
        known: set[str] = set()
        for model in models:
            payload.append(model.event(loaded(router_entry(model))))
            known.add(model.id)
        for entry in router_entries or []:
            model_id = str(entry["id"])
            if model_id in known:
                continue
            path = entry.get("path")
            payload.append(
                {
                    "id": model_id,
                    "name": model_id,
                    "size": _stat_size(Path(str(path))) if path else 0,
                    "loaded": loaded(entry),
                }
            )
            known.add(model_id)
        return payload

    def _emit_models(self, router_entries: list[dict[str, Any]] | None = None) -> None:
        self.emit({"type": "models", "models": self._models_payload(router_entries)})

    def emit_current_model(self) -> None:
        model_id = self.current_model()
        if model_id:
            self.emit({"type": "model", "id": model_id})

    def models_list(self) -> None:
        self._emit_models()

    def models_refresh(self) -> None:
        busy = self._busy
        models = self.scan_models()
        if busy:
            LOG.info("models_refresh while busy: preset reload deferred")
        router_entries = self._router_entries(reload=not busy, timeout=30.0)
        self._emit_models(router_entries)
        ids = [model.id for model in models]
        router_only = [
            str(entry["id"]) for entry in router_entries or []
            if str(entry["id"]) not in ids
        ]
        available = ids + router_only
        if self._current_model != "" and self._current_model not in available:
            self._current_model = self._select_initial_model(available)
            self.emit_current_model()
        if not models and not router_only:
            self.emit_error(self.no_models_message(), "no_models")

    def _select_model(self, model_id: str) -> str:
        model_id = model_id.strip()
        if not model_id:
            raise BridgeError("model_select needs an id")
        known = {model.id for model in self.models_snapshot()}
        if model_id not in known:
            router_entries = self._router_entries()
            known.update(str(entry["id"]) for entry in router_entries or [])
        if model_id not in known:
            raise BridgeError(f"unknown model: {model_id}")
        self._current_model = model_id
        LOG.info("selected model %s", model_id)
        self.emit({"type": "model", "id": model_id})
        return model_id

    def model_select(self, model_id: str) -> None:
        try:
            self._select_model(model_id)
        except BridgeError as exc:
            message = str(exc)
            code = "unknown_model" if message.startswith("unknown model") else "bad_command"
            self.emit_error(message, code)

    def unload_model(self, model_id: str) -> str | None:
        """Unload one model from the running router without stopping it."""
        model_id = model_id.strip()
        if not model_id:
            raise BridgeError("model_unload needs an id")
        if self._client is None:
            raise BridgeError("httpx is not installed")
        known = {model.id for model in self.models_snapshot()}
        if model_id not in known:
            router_entries = self._router_entries()
            known.update(str(entry["id"]) for entry in router_entries or [])
        if model_id not in known:
            raise BridgeError(f"unknown model: {model_id}")
        if self._busy:
            raise BridgeError(
                "cannot unload while a turn is active; cancel it first"
            )
        if not self._health(timeout=2.0):
            raise BridgeError(
                f"llama-server router is not running; cannot unload {model_id}"
            )
        current = self.current_model()
        try:
            response = self._client.post(
                f"{self.config.base_url}/models/unload",
                json={"model": model_id},
                timeout=30.0,
            )
        except httpx.HTTPError as exc:
            raise BridgeError(f"connection to llama-server failed: {exc}") from exc
        if response.status_code >= 400:
            body = " ".join(response.text.split())[:300]
            raise BridgeError(
                f"unload failed: HTTP {response.status_code} {body}".rstrip()
            )
        try:
            data = response.json()
        except (ValueError, TypeError):
            data = {}
        if not isinstance(data, dict) or data.get("success") is not True:
            detail = ""
            if isinstance(data, dict):
                detail = str(data.get("error") or data.get("message") or "").strip()
            message = f"router refused to unload {model_id}"
            if detail:
                message = f"{message}: {detail}"
            raise BridgeError(message)
        # The router stops the child asynchronously: POST returns before the
        # status flips. Poll for a moment so the UI does not briefly show the
        # model as still loaded (or a second unload as successful).
        router_entries: list[dict[str, Any]] | None = None
        status: str | None = None
        deadline = time.monotonic() + 5.0
        while time.monotonic() < deadline:
            router_entries = self._router_entries(timeout=2.0)
            if router_entries is None:
                raise BridgeError(
                    f"lost the llama-server router while unloading {model_id}"
                )
            entry = next(
                (item for item in router_entries if str(item["id"]) == model_id),
                None,
            )
            status = ((entry or {}).get("status") or {}).get("value")
            if status not in ("loaded", "loading", "sleeping"):
                break
            time.sleep(0.1)
        else:
            self._emit_models(router_entries)
            raise BridgeError(
                f"router accepted unload but {model_id} is still {status}; "
                "it may be serving a request, try again once idle"
            )
        if current == model_id:
            # Keep an explicit "nothing selected" state so the UI does not fall
            # back to the first discovered model on the next refresh.
            self._current_model = ""
        self._emit_models(router_entries)
        if current == model_id:
            self.emit({"type": "model", "id": ""})
        LOG.info("unloaded model %s", model_id)
        return self.current_model()

    def model_unload(self, model_id: str) -> None:
        try:
            self.unload_model(model_id)
        except BridgeError as exc:
            message = str(exc)
            code = "unknown_model" if message.startswith("unknown model") else "unload_failed"
            self.emit_error(message, code)

    # --------------------------------------------------------- translation

    def translate_llama(self, text: str, source: str, target: str) -> str:
        if self._client is None:
            raise BridgeError("httpx is not installed")
        self.touch()
        self.ensure_server()
        model_id = self.current_model()
        if not model_id:
            if self.models_snapshot():
                raise BridgeError("no model selected")
            raise BridgeError(self.no_models_message())
        payload = {
            "model": model_id,
            "messages": [
                {
                    "role": "system",
                    "content": _translate_instruction(source, target),
                },
                {
                    "role": "user",
                    # Some chat templates drop the system role, so repeat the
                    # instruction in the user turn.
                    "content": f"{_translate_instruction(source, target)}\n\n{text}",
                },
            ],
            "stream": False,
            "temperature": 0.1,
            "max_tokens": min(2048, max(256, len(text) * 4)),
        }
        try:
            response = self._client.post(
                f"{self.config.base_url}/v1/chat/completions",
                json=payload,
                timeout=httpx.Timeout(connect=10.0, read=300.0, write=30.0, pool=10.0),
            )
        except httpx.HTTPError as exc:
            raise BridgeError(f"connection to llama-server failed: {exc}") from exc
        if response.status_code >= 400:
            body = response.text[:400]
            raise BridgeError(
                f"chat request failed: HTTP {response.status_code} {body}"
            )
        try:
            data = response.json()
            content = data["choices"][0]["message"]["content"]
        except (ValueError, KeyError, IndexError, TypeError) as exc:
            raise BridgeError(f"unexpected chat response: {exc}") from exc
        result = str(content or "").strip()
        if not result:
            raise BridgeError("model returned an empty translation")
        self.touch()
        return result

    def translate_shell(self, text: str, source: str, target: str, engine: str) -> str:
        self.touch()
        if not os.access(TRANS_BIN, os.X_OK):
            raise BridgeError(f"Translate Shell not found: {TRANS_BIN}")
        args = [
            TRANS_BIN,
            "-brief",
            "-no-bidi",
            "-engine", engine,
            "-source", source,
            "-target", target,
        ]
        try:
            proc = subprocess.run(
                args,
                input=text if text.endswith("\n") else text + "\n",
                text=True,
                capture_output=True,
                timeout=TRANS_TIMEOUT,
                check=False,
            )
        except subprocess.TimeoutExpired as exc:
            raise BridgeError(f"trans timed out after {TRANS_TIMEOUT:.0f}s") from exc
        except OSError as exc:
            raise BridgeError(f"failed to run trans: {exc}") from exc
        result = (proc.stdout or "").strip()
        if proc.returncode != 0 and not result:
            detail = " ".join((proc.stderr or "").split())[:300]
            raise BridgeError(
                f"trans exited with code {proc.returncode}: {detail or 'no output'}"
            )
        if not result:
            detail = " ".join((proc.stderr or "").split())[:300]
            raise BridgeError(f"trans returned no translation: {detail or 'empty output'}")
        self.touch()
        return result

    # -------------------------------------------------------- control server

    def start_control_server(self) -> bool:
        if self._control is not None:
            return True
        port = self.config.control_port
        server = None
        last_exc: OSError | None = None
        # A previous Quickshell/bridge may still be releasing the port.
        for _ in range(20):
            try:
                server = ControlServer(self, port)
                break
            except OSError as exc:
                last_exc = exc
                time.sleep(0.25)
        if server is None:
            LOG.warning(
                "control API disabled: cannot bind 127.0.0.1:%s: %s", port, last_exc
            )
            return False
        self._control = server
        threading.Thread(
            target=server.serve_forever,
            kwargs={"poll_interval": 0.5},
            name="lfm3-control",
            daemon=True,
        ).start()
        LOG.info("control API listening on http://127.0.0.1:%s", port)
        return True

    def stop_control_server(self) -> None:
        server = self._control
        self._control = None
        if server is None:
            return
        try:
            server.shutdown()
        except Exception:
            LOG.debug("control server shutdown failed", exc_info=True)
        try:
            server.server_close()
        except OSError:
            pass

    # --------------------------------------------------------- llama-server

    def _health(self, timeout: float = 2.0) -> bool:
        if self._client is None:
            return False
        try:
            response = self._client.get(
                f"{self.config.base_url}/health", timeout=timeout
            )
        except Exception:
            return False
        if response.status_code != 200:
            return False
        try:
            return response.json().get("status", "ok") == "ok"
        except ValueError:
            return True

    def _spawn_server(self) -> None:
        config = self.config
        models = self.models_snapshot()
        if not models or not config.models_preset.is_file():
            # Picked up from the cache, or from MODEL when it is set.
            models = self.scan_models()
        if not models:
            raise BridgeError(self.no_models_message())
        if not config.models_preset.is_file():
            raise BridgeError(f"models preset missing: {config.models_preset}")

        server = Path(config.llama_server)
        if server.is_file() and os.access(server, os.X_OK):
            binary = str(server)
        elif shutil.which(config.llama_server):
            binary = shutil.which(config.llama_server) or config.llama_server
        elif shutil.which("llama-server"):
            binary = shutil.which("llama-server") or "llama-server"
        else:
            raise BridgeError(
                f"llama-server not found: {config.llama_server} "
                "(set LLAMA_SERVER or build llama.cpp)"
            )

        try:
            config.log_file.parent.mkdir(parents=True, exist_ok=True)
            self._server_log = open(config.log_file, "ab", buffering=0)
        except OSError as exc:
            LOG.warning("cannot open server log %s: %s", config.log_file, exc)
            self._server_log = None

        args = [binary] + config.server_args()
        LOG.info(
            "starting llama-server router on port %s (%d preset(s))",
            config.port,
            len(models),
        )
        try:
            self._server_proc = subprocess.Popen(
                args,
                stdin=subprocess.DEVNULL,
                stdout=self._server_log or subprocess.DEVNULL,
                stderr=self._server_log or subprocess.DEVNULL,
                close_fds=True,
                start_new_session=True,
            )
        except OSError as exc:
            self._close_log()
            raise BridgeError(f"failed to start llama-server: {exc}") from exc
        self._owns_server = True
        self._server_tools = None

        deadline = time.monotonic() + config.load_timeout
        while time.monotonic() < deadline:
            if self._stop.is_set():
                self.stop_server()
                raise BridgeError("shutdown during router start")
            proc = self._server_proc
            if proc is not None and proc.poll() is not None:
                self.stop_server()
                raise BridgeError(
                    f"llama-server exited with code {proc.returncode}; "
                    f"see {config.log_file}"
                )
            if self._health(timeout=1.0):
                LOG.info("llama-server router is ready")
                break
            time.sleep(0.5)
        else:
            self.stop_server()
            raise BridgeError(
                f"router did not become healthy within {config.load_timeout}s; "
                f"see {config.log_file}"
            )

        router_entries = self._router_entries(timeout=15.0)
        if not router_entries:
            self.stop_server()
            raise BridgeError(
                f"router reports no models; check {config.models_preset} "
                f"and {config.log_file}"
            )
        available = [str(entry["id"]) for entry in router_entries]
        if self._current_model != "" and self.current_model() not in available:
            self._current_model = self._select_initial_model(available)
            self.emit_current_model()
        self._emit_models(router_entries)

    def _close_log(self) -> None:
        if self._server_log is not None:
            try:
                self._server_log.close()
            except OSError:
                pass
            self._server_log = None

    def ensure_server(self) -> None:
        if self._client is None:
            raise BridgeError("httpx is not installed (pip install httpx)")
        with self._server_lock:
            if self._health(timeout=1.0):
                # A server is already up: ours after a previous turn, or external.
                return
            if self._server_proc is not None:
                # Crashed or stopped behind our back.
                self._close_log()
                self._server_proc = None
                self._owns_server = False
                self._server_tools = None
            self._spawn_server()

    def stop_server(self) -> None:
        with self._server_lock:
            proc = self._server_proc
            owned = self._owns_server
            self._server_proc = None
            self._owns_server = False
            self._server_tools = None
            if proc is None or not owned:
                self._close_log()
                return
            if proc.poll() is None:
                LOG.info("stopping owned llama-server (pid %s)", proc.pid)
                try:
                    proc.terminate()
                    proc.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    LOG.warning("llama-server did not stop, killing it")
                    try:
                        os.killpg(proc.pid, signal.SIGKILL)
                    except (ProcessLookupError, PermissionError, OSError):
                        proc.kill()
                    try:
                        proc.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        pass
                except OSError:
                    pass
            self._close_log()

    def idle_loop(self) -> None:
        timeout = self.config.idle_timeout
        if timeout <= 0:
            return
        interval = max(1.0, min(5.0, timeout / 2))
        while not self._stop.wait(interval):
            if self._busy or self.voice_active() or not self._owns_server:
                continue
            if time.monotonic() - self._last_activity < timeout:
                continue
            # Hold the turn lock so a new turn cannot start while stopping.
            with self._turn_lock:
                if self._busy or self.voice_active() or self._stop.is_set():
                    continue
                if time.monotonic() - self._last_activity < timeout:
                    continue
                LOG.info("idle for %ss, stopping llama-server", timeout)
                self.stop_server()

    # ------------------------------------------------------------------ tools

    def server_tools(self) -> list[dict[str, Any]]:
        """Fetch and normalize GET /tools into OpenAI tool definitions."""
        if self._client is None:
            return []
        with self._server_lock:
            if self._server_tools is not None:
                return self._server_tools
            try:
                response = self._client.get(
                    f"{self.config.base_url}/tools", timeout=10.0
                )
                response.raise_for_status()
                raw = response.json()
            except Exception as exc:
                LOG.info("GET /tools unavailable: %s", exc)
                self._server_tools = []
                return []
            tools: list[dict[str, Any]] = []
            seen: set[str] = set()
            if not isinstance(raw, list):
                LOG.warning("GET /tools returned %s, expected list", type(raw))
                raw = []
            for entry in raw:
                if not isinstance(entry, dict):
                    continue
                tool_id = str(entry.get("tool") or "").strip()
                if not tool_id or tool_id in LOCAL_TOOL_NAMES or tool_id in seen:
                    continue
                permissions = entry.get("permissions") or {}
                if permissions.get("write") and not self.config.allow_write_tools:
                    LOG.info("skipping write tool %s", tool_id)
                    continue
                definition = entry.get("definition") or {}
                function = definition.get("function") or {}
                parameters = function.get("parameters")
                if not isinstance(parameters, dict):
                    parameters = {"type": "object", "properties": {}}
                tools.append(
                    {
                        "type": "function",
                        "function": {
                            "name": tool_id,
                            "description": str(
                                function.get("description")
                                or entry.get("display_name")
                                or tool_id
                            ),
                            "parameters": parameters,
                        },
                    }
                )
                seen.add(tool_id)
            self._server_tools = tools
            LOG.info(
                "loaded %d server/MCP tool(s): %s",
                len(tools),
                ", ".join(t["function"]["name"] for t in tools),
            )
            return tools

    def all_tools(self) -> list[dict[str, Any]]:
        return LOCAL_TOOLS + self.server_tools()

    def call_server_tool(self, name: str, args: dict[str, Any]) -> tuple[bool, str, Any]:
        if self._client is None:
            return False, "httpx is not installed", {"error": "httpx_missing"}
        try:
            response = self._client.post(
                f"{self.config.base_url}/tools",
                json={"tool": name, "params": args},
                timeout=httpx.Timeout(connect=10.0, read=120.0, write=30.0, pool=10.0),
            )
        except Exception as exc:
            return False, f"tool request failed: {exc}", {
                "error": "tool_request_failed",
                "message": str(exc),
            }
        try:
            data = response.json()
        except ValueError:
            data = {"error": f"non-JSON response: {response.text[:300]}"}
        if response.status_code >= 400:
            message = _describe_error(data) or f"HTTP {response.status_code}"
            return False, message, {"error": "tool_http_error", "message": message}
        if isinstance(data, dict) and data.get("error"):
            message = _describe_error(data) or "tool error"
            return False, message, {"error": "tool_error", "message": message}
        if isinstance(data, dict) and "plain_text_response" in data:
            text = str(data["plain_text_response"])
            return True, _summary(text), _truncate(text, MAX_TOOL_RESULT_CHARS)
        text = json.dumps(data, ensure_ascii=False)
        return True, _summary(text), _truncate(text, MAX_TOOL_RESULT_CHARS)

    # ------------------------------------------------------------- local tools

    def digup_search(self, args: dict[str, Any]) -> tuple[bool, str, Any]:
        query = str(args.get("query") or "").strip()
        if not query:
            return False, "missing query", {
                "error": "bad_arguments",
                "message": "digup_search needs a non-empty query",
            }
        if len(query) > MAX_DIGUP_QUERY:
            query = query[:MAX_DIGUP_QUERY]
        limit = _int(args.get("limit"), self.config.digup_limit, 1, MAX_DIGUP_RESULTS)
        kind = args.get("kind")
        kind = str(kind).strip() if kind else ""
        allowed_kinds = {"screenshot", "image", "pdf", "doc", "audio", "video"}
        command = [str(self.config.digup_bin), "search", "--json", "-n", str(limit)]
        if kind and kind in allowed_kinds:
            command += ["--kind", kind]
        else:
            kind = ""
        command.append(query[:MAX_DIGUP_QUERY])

        binary = self.config.digup_bin
        if not binary.is_file() and not shutil.which(str(binary)):
            return False, "digup not found", {
                "error": "digup_not_found",
                "message": f"digup binary not found: {binary}",
            }
        try:
            completed = subprocess.run(
                command,
                stdin=subprocess.DEVNULL,
                capture_output=True,
                text=True,
                timeout=45,
                check=False,
            )
        except subprocess.TimeoutExpired:
            return False, "digup timed out", {
                "error": "digup_timeout",
                "message": "digup search timed out after 45s",
            }
        except OSError as exc:
            return False, "digup failed to run", {
                "error": "digup_failed",
                "message": str(exc),
            }
        if completed.returncode != 0:
            detail = (completed.stderr or completed.stdout or "").strip()
            return False, "digup failed", {
                "error": "digup_failed",
                "message": detail[-500:] or f"exit code {completed.returncode}",
            }
        try:
            rows = json.loads(completed.stdout or "[]")
        except ValueError:
            return False, "digup returned invalid JSON", {
                "error": "digup_bad_json",
                "message": (completed.stdout or "")[:300],
            }
        if not isinstance(rows, list):
            return False, "digup returned unexpected JSON", {
                "error": "digup_bad_json",
                "message": "expected a JSON array",
            }
        results = []
        for row in rows[:limit]:
            if not isinstance(row, dict):
                continue
            excerpt = row.get("excerpt")
            if isinstance(excerpt, str):
                excerpt = _truncate(excerpt, MAX_DIGUP_EXCERPT)
            results.append(
                {
                    "path": row.get("path"),
                    "kind": row.get("kind"),
                    "segment": row.get("segment"),
                    "score": row.get("score"),
                    "cosine": row.get("cosine"),
                    "excerpt": excerpt,
                    "loc": row.get("loc"),
                    "loc_end": row.get("loc_end"),
                    "modified": row.get("modified"),
                    "size": row.get("size"),
                    "info": row.get("info"),
                }
            )
        payload = {"query": query, "kind": kind or None, "count": len(results),
                   "results": results}
        summary = f"{len(results)} result" + ("" if len(results) == 1 else "s")
        if not results:
            summary = "no results"
        return True, summary, payload

    def _media_event(self, result: Any) -> dict[str, Any] | None:
        """Normalize digup results for QML previews. Never opens a file."""
        if not isinstance(result, dict):
            return None
        rows = result.get("results")
        if not isinstance(rows, list):
            return None
        entries: list[dict[str, Any]] = []
        for row in rows:
            if not isinstance(row, dict):
                continue
            raw_path = row.get("path")
            if not isinstance(raw_path, str) or not raw_path:
                continue
            path = Path(raw_path)
            kind = str(row.get("kind") or "").strip()
            mime, _encoding = mimetypes.guess_type(raw_path)
            media = kind in MEDIA_RESULT_KINDS or (
                (mime or "").startswith(("image/", "video/", "audio/"))
            )
            excerpt = row.get("excerpt")
            excerpt = excerpt if isinstance(excerpt, str) else ""
            entries.append(
                {
                    "path": raw_path,
                    "kind": kind or ("file" if not media else "media"),
                    "snippet": _summary(excerpt),
                    "match": _truncate(excerpt, MAX_DIGUP_EXCERPT),
                    "media": media,
                    "mime": mime,
                    # Images can be shown directly; video has no still frame.
                    "thumbnail": raw_path if kind in {"image", "screenshot"} else None,
                    "segment": row.get("segment"),
                    "loc": row.get("loc"),
                    "loc_end": row.get("loc_end"),
                    "size": row.get("size"),
                    "modified": row.get("modified"),
                }
            )
        return {"type": "media", "query": result.get("query"), "results": entries}

    def get_local_time(self, _args: dict[str, Any]) -> tuple[bool, str, Any]:
        now = datetime.now().astimezone()
        payload = {
            "iso": now.isoformat(timespec="seconds"),
            "human": now.strftime("%A, %d %B %Y, %H:%M:%S %Z"),
            "timezone": now.tzname(),
            "epoch": int(now.timestamp()),
        }
        return True, payload["human"], payload

    def set_timer(self, args: dict[str, Any]) -> tuple[bool, str, Any]:
        seconds = _int(args.get("seconds"), 0, 0, 86400)
        if seconds <= 0:
            return False, "missing seconds", {
                "error": "bad_arguments",
                "message": "set_timer needs seconds between 1 and 86400",
            }
        label = str(args.get("label") or "").strip() or f"timer {seconds}s"
        with self._timer_lock:
            existing = self._timers.pop(label, None)
            if existing is not None:
                existing.cancel()
            timer = threading.Timer(seconds, self._timer_fired, args=(label, seconds))
            timer.daemon = True
            self._timers[label] = timer
            timer.start()
        payload = {"label": label, "seconds": seconds, "end": int(time.time()) + seconds}
        return True, f"timer '{label}' set for {seconds}s", payload

    def _timer_fired(self, label: str, seconds: int) -> None:
        with self._timer_lock:
            self._timers.pop(label, None)
        self.emit({"type": "timer", "label": label, "seconds": seconds})

    def cancel_timer(self, args: dict[str, Any]) -> tuple[bool, str, Any]:
        label = str(args.get("label") or "").strip()
        with self._timer_lock:
            if label:
                timer = self._timers.pop(label, None)
                if timer is None:
                    return False, f"no timer '{label}'", {
                        "error": "not_found",
                        "message": f"no timer labelled '{label}'",
                    }
                timer.cancel()
                return True, f"timer '{label}' cancelled", {"cancelled": [label]}
            labels = list(self._timers)
            for timer in self._timers.values():
                timer.cancel()
            self._timers.clear()
        return True, f"cancelled {len(labels)} timer(s)", {"cancelled": labels}

    def get_connection(self, _args: dict[str, Any]) -> tuple[bool, str, Any]:
        online = self._health(timeout=1.0)
        model_id = self.current_model()
        models = self.models_snapshot()
        payload = {
            "online": online,
            "model": model_id,
            "models": len(models),
            "port": self.config.port,
            "base_url": self.config.base_url,
            "server": "running" if online else "stopped",
            "owner": ("bridge" if self._owns_server else "external") if online else None,
            "theme": self._theme,
        }
        summary = (
            f"online, {model_id}" if online else "offline, model not loaded"
        )
        return True, summary, payload

    def copy_to_clipboard(self, args: dict[str, Any]) -> tuple[bool, str, Any]:
        text = args.get("text")
        if not isinstance(text, str) or not text:
            return False, "missing text", {
                "error": "bad_arguments",
                "message": "copy_to_clipboard needs non-empty text",
            }
        if shutil.which("wl-copy") is None:
            return False, "wl-copy not found", {
                "error": "wl_copy_missing",
                "message": "wl-clipboard is not installed",
            }
        try:
            # wl-copy forks a child that keeps serving the clipboard; the child
            # would hold capture pipes open, so send both streams to DEVNULL.
            completed = subprocess.run(
                ["wl-copy"],
                input=text,
                text=True,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=5,
                check=False,
            )
        except (OSError, subprocess.TimeoutExpired) as exc:
            return False, "copy failed", {"error": "copy_failed", "message": str(exc)}
        if completed.returncode != 0:
            return False, "copy failed", {
                "error": "copy_failed",
                "message": f"wl-copy exited with code {completed.returncode}",
            }
        return True, f"copied {len(text)} chars", {"chars": len(text)}

    def set_theme(self, args: dict[str, Any]) -> tuple[bool, str, Any]:
        theme = str(args.get("theme") or "").strip().lower()
        if theme not in {"dark", "light", "auto"}:
            return False, "bad theme", {
                "error": "bad_arguments",
                "message": "theme must be dark, light, or auto",
            }
        self._theme = theme
        self.emit({"type": "theme", "theme": theme})
        return True, f"theme set to {theme}", {"theme": theme}

    def execute_local_tool(
        self, name: str, args: dict[str, Any]
    ) -> tuple[bool, str, Any]:
        handlers = {
            "digup_search": self.digup_search,
            "get_local_time": self.get_local_time,
            "set_timer": self.set_timer,
            "cancel_timer": self.cancel_timer,
            "get_connection": self.get_connection,
            "copy_to_clipboard": self.copy_to_clipboard,
            "set_theme": self.set_theme,
        }
        handler = handlers.get(name)
        if handler is None:
            return False, f"unknown local tool {name}", {
                "error": "unknown_tool",
                "message": name,
            }
        try:
            return handler(args)
        except Exception as exc:  # tool code must never kill the turn
            LOG.exception("local tool %s failed", name)
            return False, f"{name} failed", {
                "error": "tool_failed",
                "message": str(exc),
            }

    # ------------------------------------------------------------- attachments

    def _prepare_attachment(self, raw: Any) -> dict[str, Any]:
        """Validate one attachment path, returning UI and request metadata."""
        text = str(raw or "").strip()
        if not text:
            raise BridgeError("attachment path is empty")
        if not os.path.isabs(text):
            raise BridgeError(f"attachment path must be absolute: {text}")
        resolved = Path(os.path.realpath(text))
        root = self.config.media_path
        try:
            relative = resolved.relative_to(root)
        except ValueError as exc:
            raise BridgeError(
                f"attachment is outside MEDIA_PATH ({root}): {resolved}"
            ) from exc
        if not resolved.is_file():
            raise BridgeError(f"attachment is not a file: {resolved}")
        kind, mime = _media_kind(resolved)
        if kind is None:
            raise BridgeError(f"unsupported attachment type: {resolved.suffix or resolved}")
        try:
            size = resolved.stat().st_size
        except OSError as exc:
            raise BridgeError(f"cannot stat attachment: {exc}") from exc
        limit = self.config.media_max_mb * 1024 * 1024
        if size > limit:
            raise BridgeError(
                f"attachment too large ({size} bytes, limit {self.config.media_max_mb} MB)"
            )
        relative_text = relative.as_posix()
        if not relative_text or len(relative_text) > MAX_MEDIA_REL_CHARS:
            # llama-server rejects longer file:// paths.
            raise BridgeError(
                f"attachment path is too long for --media-path "
                f"(limit {MAX_MEDIA_REL_CHARS} chars): {relative_text}"
            )
        return {
            "path": str(resolved),
            "kind": kind,
            "mime": mime,
            "size": size,
            "name": resolved.name,
            "rel": relative_text,
        }

    def _user_content(
        self, text: str, attachments: list[dict[str, Any]]
    ) -> str | list[dict[str, Any]]:
        """Build OpenAI content parts. Text-only turns keep a plain string."""
        if not attachments:
            return text
        parts: list[dict[str, Any]] = []
        if text:
            parts.append({"type": "text", "text": text})
        for item in attachments:
            kind = item["kind"]
            if kind == "image":
                try:
                    data = Path(item["path"]).read_bytes()
                except OSError as exc:
                    raise BridgeError(f"cannot read attachment: {exc}") from exc
                encoded = base64.b64encode(data).decode("ascii")
                parts.append(
                    {
                        "type": "image_url",
                        "image_url": {
                            "url": f"data:{item['mime']};base64,{encoded}"
                        },
                    }
                )
            elif kind == "video":
                # file:// URLs are resolved relative to --media-path.
                parts.append(
                    {
                        "type": "input_video",
                        "input_video": {"url": f"file://{item['rel']}"},
                    }
                )
            elif kind == "audio":
                parts.append(
                    {
                        "type": "input_audio",
                        "input_audio": {"url": f"file://{item['rel']}"},
                    }
                )
        return parts

    # -------------------------------------------------------------------- turn

    def start_turn(self, text: str, attachments: list[Any] | None = None) -> None:
        text = (text or "").strip()
        raw_attachments = attachments or []
        if not isinstance(raw_attachments, list):
            self.emit_error("attachments must be a list", "bad_command")
            return
        if len(raw_attachments) > MAX_ATTACHMENTS:
            self.emit_error(
                f"too many attachments (limit {MAX_ATTACHMENTS})", "bad_command"
            )
            return
        prepared: list[dict[str, Any]] = []
        for raw in raw_attachments:
            try:
                prepared.append(self._prepare_attachment(raw))
            except BridgeError as exc:
                self.emit_error(str(exc), "bad_attachment")
                return
        if not text and not prepared:
            self.emit_error("empty text", "bad_command")
            return
        if self.voice_active():
            self._voice_cancel.set()
            if not self.wait_voice(5.0):
                self.emit_error("voice is still active", "busy")
                return
        with self._turn_lock:
            busy = self._busy
        if busy:
            # Ask the previous turn to stop, then give it a moment to unwind.
            self._cancel.set()
            started = time.monotonic()
            while time.monotonic() - started < 5.0:
                with self._turn_lock:
                    if not self._busy:
                        break
                time.sleep(0.05)
        with self._turn_lock:
            if self._busy:
                self.emit_error("busy with another request", "busy")
                return
            self._busy = True
            self._cancel.clear()
            self._partial_text = ""
            thread = threading.Thread(
                target=self._turn,
                args=(text, prepared),
                name="lfm3-turn",
                daemon=True,
            )
            self._turn_thread = thread
            thread.start()

    def wait_turn(self, timeout: float = 5.0) -> None:
        thread = self._turn_thread
        if thread is not None and thread.is_alive():
            thread.join(timeout)

    def _turn(self, text: str, attachments: list[dict[str, Any]] | None = None) -> None:
        attachments = attachments or []
        try:
            self.touch()
            if attachments:
                self.emit(
                    {
                        "type": "user",
                        "text": text,
                        "attachments": [
                            {
                                "path": item["path"],
                                "kind": item["kind"],
                                "mime": item["mime"],
                                "size": item["size"],
                                "name": item["name"],
                            }
                            for item in attachments
                        ],
                    }
                )
            else:
                self.emit({"type": "user", "text": text})
            self.emit({"type": "state", "state": "thinking"})
            content = self._user_content(text, attachments)
            self.ensure_server()
            model_id = self.current_model()
            if not model_id:
                raise BridgeError("no model selected")
            LOG.info(
                "chat model=%s attachments=%d", model_id, len(attachments)
            )
            self._trim_history()
            self._messages.append({"role": "user", "content": content})
            collected: list[str] = []
            for round_index in range(MAX_TOOL_ROUNDS):
                self._check_cancel()
                content, tool_calls = self._stream_completion(model_id)
                if content:
                    collected.append(content)
                if not tool_calls:
                    break
                self._messages.append(
                    {
                        "role": "assistant",
                        "content": content or "",
                        "tool_calls": tool_calls,
                    }
                )
                for call in tool_calls:
                    self._run_tool_call(call)
                if round_index == MAX_TOOL_ROUNDS - 1:
                    self.emit_error(
                        f"stopped after {MAX_TOOL_ROUNDS} tool rounds", "tool_rounds"
                    )
            answer = "".join(collected).strip()
            self.emit({"type": "text_done", "text": answer})
            self.speak_text(answer, model_id)
            try:
                self._emit_models()
            except Exception:
                LOG.debug("model status update failed", exc_info=True)
            self.emit({"type": "state", "state": "idle"})
        except TurnCancelled:
            self.emit({"type": "text_done", "text": self._partial_text})
            self.emit({"type": "state", "state": "idle"})
        except BridgeError as exc:
            self.emit_error(str(exc), "bridge_error")
            self.emit({"type": "state", "state": "idle"})
        except Exception as exc:
            LOG.exception("turn failed")
            self.emit_error(f"internal error: {exc}", "internal_error")
            self.emit({"type": "state", "state": "idle"})
        finally:
            self.touch()
            with self._turn_lock:
                self._busy = False
                self._turn_thread = None

    def speak_text(self, text: str, model_id: str) -> None:
        """Speak a typed answer through /tts. Failure is non-fatal."""
        if not self._speak_text or not text.strip():
            return
        if self._client is None or shutil.which("pw-play") is None:
            LOG.warning("TTS skipped: httpx or pw-play is unavailable")
            return
        payload = {
            "input": text[: self.config.tts_max_chars],
            "voice": self.config.tts_voice,
            "response_format": "pcm",
            "model": model_id,
        }
        try:
            response = self._client.post(
                f"{self.config.base_url}/tts",
                json=payload,
                timeout=httpx.Timeout(connect=10.0, read=180.0, write=30.0, pool=10.0),
            )
            response.raise_for_status()
            pcm = response.content
            if not pcm:
                LOG.warning("TTS returned no audio")
                return
            content_type = response.headers.get("content-type", "")
            rate_match = re.search(r"rate=(\d+)", content_type)
            rate = int(rate_match.group(1)) if rate_match else self.config.voice_output_rate
            LOG.info("TTS model=%s chars=%d pcm=%d rate=%d", model_id, len(text), len(pcm), rate)
            command = [
                "pw-play",
                "--raw",
                f"--rate={rate}",
                "--channels=1",
                "--format=f32",
                f"--volume={self.config.voice_volume:.2f}",
            ]
            if self.config.speaker_device:
                command += ["--target", self.config.speaker_device]
            command.append("-")
            self.emit({"type": "speech_start"})
            self.emit({"type": "state", "state": "speaking"})
            proc = subprocess.Popen(
                command,
                stdin=subprocess.PIPE,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            try:
                proc.communicate(pcm, timeout=max(30.0, len(pcm) / 48000.0 + 20.0))
            except subprocess.TimeoutExpired:
                proc.terminate()
                proc.wait(timeout=5)
        except (httpx.HTTPError, OSError, ValueError) as exc:
            LOG.warning("TTS skipped: %s", exc)
        finally:
            self.emit({"type": "speech_end"})

    def _check_cancel(self) -> None:
        if self._cancel.is_set() or self._stop.is_set():
            raise TurnCancelled()

    # ------------------------------------------------------------------- voice

    def voice_active(self) -> bool:
        thread = self._voice_thread
        return bool(thread is not None and thread.is_alive())

    def wait_voice(self, timeout: float = 5.0) -> bool:
        thread = self._voice_thread
        if thread is None:
            return True
        thread.join(timeout)
        return not thread.is_alive()

    def start_listen(self) -> None:
        if ws_connect is None:
            self.emit_error(
                "the websockets package is not installed; pip install websockets",
                "dependency_missing",
            )
            return
        if self._busy:
            self.emit_error("busy with a text request", "busy")
            return
        missing = [
            name for name in ("parec", "pw-play") if shutil.which(name) is None
        ]
        if missing:
            self.emit_error(
                "missing voice tool(s): "
                + ", ".join(missing)
                + "; install pipewire/pulseaudio utilities",
                "voice_tool_missing",
            )
            return
        with self._voice_lock:
            if self.voice_active():
                self.emit_error("already listening", "voice_busy")
                return
            self._voice_cancel.clear()
            self._voice_stop_capture.clear()
            thread = threading.Thread(
                target=self._voice_session, name="lfm3-voice", daemon=True
            )
            self._voice_thread = thread
            thread.start()

    def stop_listen(self, commit: bool = True) -> None:
        if not self.voice_active():
            self.emit_error("not listening", "voice_idle")
            self.emit({"type": "state", "state": "idle"})
            return
        if not commit:
            self._voice_cancel.set()
            return
        self.emit({"type": "state", "state": "thinking"})
        self._voice_stop_capture.set()

    def cancel_voice(self, wait: bool = False) -> None:
        self._voice_cancel.set()
        if wait:
            self.wait_voice(5.0)

    def _voice_session(self) -> None:
        state = VoiceState(
            in_rate=self.config.mic_rate,
            out_rate=self.config.voice_output_rate,
        )
        ws = None
        capture_thread: threading.Thread | None = None
        cancelled = False
        finished = False
        try:
            self.touch()
            self.ensure_server()
            model_id = self.current_model()
            if not model_id:
                raise VoiceError("no model selected")
            LOG.info("voice model=%s", model_id)
            url = (
                f"ws://{self.config.host}:{self.config.port}/v1/realtime"
                f"?model={quote(model_id, safe='')}"
            )
            try:
                ws = ws_connect(
                    url,
                    max_size=VOICE_WS_MAX_SIZE,
                    open_timeout=self.config.load_timeout,
                    close_timeout=5,
                )
            except (OSError, WebSocketException) as exc:
                raise VoiceError(f"cannot open voice connection: {exc}") from exc

            created = self._voice_recv_json(ws, 30.0)
            if created.get("type") == "error":
                raise VoiceError(_voice_event_error(created))
            if created.get("type") != "session.created":
                LOG.warning("first voice event is %s", created.get("type"))
            state.in_rate, state.out_rate = _voice_rates(created, state)

            ws.send(
                json.dumps(
                    {
                        "type": "session.update",
                        "session": {
                            "type": "realtime",
                            "instructions": self.config.voice_instructions,
                            "output_modalities": ["text", "audio"],
                        },
                    }
                )
            )
            self._voice_wait_updated(ws, 30.0)

            capture_cmd = [
                "parec",
                "--format=s16le",
                f"--rate={state.in_rate}",
                "--channels=1",
                "--raw",
                f"--latency-msec={VOICE_CHUNK_MS}",
            ]
            if self.config.mic_device:
                capture_cmd += ["--device", self.config.mic_device]
            try:
                state.capture_proc = subprocess.Popen(
                    capture_cmd,
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    bufsize=0,
                )
            except OSError as exc:
                raise VoiceError(f"cannot start parec: {exc}") from exc

            def capture_stderr(proc: subprocess.Popen[bytes]) -> None:
                if proc.stderr is None:
                    return
                for line in proc.stderr:
                    LOG.warning("parec: %s", line.decode("utf-8", "replace").strip())

            threading.Thread(
                target=capture_stderr,
                args=(state.capture_proc,),
                name="lfm3-capture-err",
                daemon=True,
            ).start()

            # A bad device exits immediately; fail fast with a clear message.
            time.sleep(0.3)
            if state.capture_proc.poll() is not None:
                raise VoiceError(
                    "parec exited immediately "
                    f"(code {state.capture_proc.returncode}); check MIC_DEVICE"
                )

            capture_thread = threading.Thread(
                target=self._voice_capture_loop,
                args=(ws, state),
                name="lfm3-voice-capture",
                daemon=True,
            )
            capture_thread.start()
            self.emit({"type": "state", "state": "listening"})
            LOG.info(
                "voice capture: in=%s Hz out=%s Hz mic=%s speaker=%s",
                state.in_rate,
                state.out_rate,
                self.config.mic_device or "default",
                self.config.speaker_device or "default",
            )

            joined = False
            deadline: float | None = None
            while True:
                if self._voice_cancel.is_set() or self._stop.is_set():
                    cancelled = True
                    break
                if self._voice_stop_capture.is_set() and not joined:
                    joined = True
                    LOG.info("voice capture stop requested (chunks=%s)", state.chunks)
                    self._voice_terminate(state.capture_proc)
                    if capture_thread is not None:
                        capture_thread.join(2.0)
                        capture_thread = None
                    if state.error:
                        raise VoiceError(state.error)
                    if state.chunks == 0:
                        raise VoiceError(
                            "no audio captured; check the microphone and MIC_DEVICE"
                        )
                    ws.send(json.dumps({"type": "input_audio_buffer.commit"}))
                    self.emit({"type": "state", "state": "thinking"})
                    if not state.response_seen:
                        ws.send(json.dumps({"type": "response.create"}))
                        state.awaiting_response = True
                    deadline = time.monotonic() + VOICE_RESPONSE_TIMEOUT
                if state.response_done:
                    break
                try:
                    raw = ws.recv(timeout=0.2)
                except TimeoutError:
                    if self._voice_stop_capture.is_set():
                        # The command loop asked us to commit; handle it at the
                        # top of the loop before checking the capture thread.
                        continue
                    if deadline is not None and time.monotonic() > deadline:
                        raise VoiceError("timed out waiting for the voice response")
                    if (
                        not joined
                        and capture_thread is not None
                        and not capture_thread.is_alive()
                    ):
                        if state.error:
                            raise VoiceError(state.error)
                        raise VoiceError(
                            "microphone capture ended; check MIC_DEVICE"
                        )
                    continue
                except WebSocketException as exc:
                    if state.response_done:
                        break
                    raise VoiceError(f"voice connection closed: {exc}") from exc
                self._voice_handle_event(_json_or_none(raw), state)

            if not cancelled:
                self._voice_finish(state)
                finished = True
        except VoiceError as exc:
            cancelled = self._voice_cancel.is_set() or self._stop.is_set()
            if not cancelled:
                self.emit_error(str(exc), "voice_error")
            if state.text:
                self.emit({"type": "text_done", "text": state.text.strip()})
        except Exception as exc:  # voice failures must not kill the bridge
            LOG.exception("voice session failed")
            cancelled = self._voice_cancel.is_set() or self._stop.is_set()
            if not cancelled:
                self.emit_error(f"voice error: {exc}", "voice_error")
        finally:
            self._voice_stop_capture.set()
            self._voice_terminate(state.capture_proc)
            if capture_thread is not None:
                capture_thread.join(2.0)
            if ws is not None and cancelled and not state.response_done:
                try:
                    ws.send(json.dumps({"type": "response.cancel"}))
                except Exception:
                    pass
            if ws is not None:
                try:
                    ws.close()
                except Exception:
                    pass
            self._voice_stop_playback(state, terminate=cancelled or not finished)
            if state.speech_started:
                state.speech_started = False
                self.emit({"type": "speech_end"})
            self.emit({"type": "state", "state": "idle"})
            self.touch()
            with self._voice_lock:
                self._voice_thread = None
            LOG.info("voice session ended")

    def _voice_capture_loop(self, ws: Any, state: VoiceState) -> None:
        proc = state.capture_proc
        if proc is None or proc.stdout is None:
            state.error = "parec did not start"
            return
        chunk_bytes = max(320, int(state.in_rate * 2 * VOICE_CHUNK_MS / 1000))
        try:
            while not self._voice_stop_capture.is_set():
                if self._voice_cancel.is_set() or self._stop.is_set():
                    break
                data = proc.stdout.read(chunk_bytes)
                if not data:
                    LOG.warning("parec ended (code %s)", proc.poll())
                    break
                if self._voice_stop_capture.is_set() or self._voice_cancel.is_set():
                    break
                ws.send(
                    json.dumps(
                        {
                            "type": "input_audio_buffer.append",
                            "audio": base64.b64encode(data).decode("ascii"),
                        }
                    )
                )
                state.chunks += 1
                if not state.user_emitted:
                    state.user_emitted = True
                    self.emit({"type": "user", "text": "Voice message"})
                self.emit(
                    {"type": "level", "value": round(_pcm16_rms(data), 3)}
                )
                self.touch()
        except Exception as exc:
            if not self._voice_cancel.is_set() and not self._stop.is_set():
                state.error = f"audio capture failed: {exc}"
            LOG.warning("voice capture stopped: %s", exc)
        finally:
            self._voice_terminate(proc)

    def _voice_handle_event(
        self, event: dict[str, Any] | None, state: VoiceState
    ) -> None:
        if not event:
            return
        kind = event.get("type")
        if kind == "error":
            raise VoiceError(_voice_event_error(event))
        if kind == "response.created":
            state.response_seen = True
        elif kind == "response.output_text.delta":
            delta = event.get("delta") or ""
            if isinstance(delta, str) and delta:
                state.text += delta
                self.emit({"type": "text_delta", "text": delta})
        elif kind == "response.output_audio.delta":
            encoded = event.get("delta") or ""
            try:
                audio = base64.b64decode(encoded, validate=False)
            except (ValueError, TypeError):
                audio = b""
            if audio:
                self._voice_write_playback(state, audio)
        elif kind == "response.done":
            state.response_done = True
        self.touch()

    def _voice_finish(self, state: VoiceState) -> None:
        self.emit({"type": "text_done", "text": state.text.strip()})
        self._voice_stop_playback(state, terminate=False)
        if state.speech_started:
            state.speech_started = False
            self.emit({"type": "speech_end"})

    def _voice_write_playback(self, state: VoiceState, audio: bytes) -> None:
        proc = state.playback_proc
        if proc is None or proc.poll() is not None:
            proc = self._voice_start_playback(state)
            if proc is None:
                return
        if not state.speech_started:
            state.speech_started = True
            self.emit({"type": "speech_start"})
            self.emit({"type": "state", "state": "speaking"})
        try:
            assert proc.stdin is not None
            proc.stdin.write(audio)
            proc.stdin.flush()
        except (BrokenPipeError, OSError, ValueError):
            LOG.warning("audio playback pipe closed")
            self._voice_stop_playback(state, terminate=True)
            return
        self.emit({"type": "level", "value": round(_pcm16_rms(audio), 3)})

    def _voice_start_playback(
        self, state: VoiceState
    ) -> subprocess.Popen[bytes] | None:
        if state.playback_failed:
            return None
        command = [
            "pw-play",
            "--raw",
            f"--rate={state.out_rate}",
            "--channels=1",
            "--format=s16",
            f"--volume={self.config.voice_volume:.2f}",
        ]
        if self.config.speaker_device:
            command += ["--target", self.config.speaker_device]
        command.append("-")
        try:
            proc = subprocess.Popen(
                command,
                stdin=subprocess.PIPE,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                bufsize=0,
            )
        except OSError as exc:
            LOG.warning("cannot start pw-play: %s", exc)
            state.playback_failed = True
            self.emit_error(f"cannot start audio playback: {exc}", "voice_error")
            return None
        state.playback_proc = proc
        return proc

    def _voice_stop_playback(self, state: VoiceState, terminate: bool) -> None:
        proc = state.playback_proc
        state.playback_proc = None
        if proc is None:
            return
        try:
            if proc.stdin is not None:
                proc.stdin.close()
        except (BrokenPipeError, OSError, ValueError):
            pass
        if terminate and proc.poll() is None:
            self._voice_terminate(proc)
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self._voice_terminate(proc)

    def _voice_terminate(self, proc: subprocess.Popen[bytes] | None) -> None:
        if proc is None or proc.poll() is not None:
            return
        try:
            proc.terminate()
        except OSError:
            return
        try:
            proc.wait(timeout=2)
        except subprocess.TimeoutExpired:
            try:
                proc.kill()
                proc.wait(timeout=2)
            except (OSError, subprocess.TimeoutExpired):
                pass
        except OSError:
            pass

    def _voice_recv_json(self, ws: Any, timeout: float) -> dict[str, Any]:
        event = self._voice_recv_event(ws, timeout)
        if event is None:
            raise VoiceError("voice server sent no session")
        return event

    def _voice_recv_event(
        self, ws: Any, timeout: float
    ) -> dict[str, Any] | None:
        deadline = time.monotonic() + timeout
        while True:
            if self._voice_cancel.is_set() or self._stop.is_set():
                raise VoiceError("voice cancelled")
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise VoiceError("timed out waiting for the voice server")
            try:
                raw = ws.recv(timeout=min(0.2, remaining))
            except TimeoutError:
                continue
            event = _json_or_none(raw)
            if event is not None:
                return event

    def _voice_wait_updated(self, ws: Any, timeout: float) -> None:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            event = self._voice_recv_event(
                ws, max(0.1, deadline - time.monotonic())
            )
            if event is None:
                continue
            kind = event.get("type")
            if kind == "error":
                raise VoiceError(_voice_event_error(event))
            if kind in ("session.updated", "session.created"):
                return
        raise VoiceError("voice session was not acknowledged")

    def _stream_completion(
        self, model_id: str
    ) -> tuple[str, list[dict[str, Any]]]:
        if self._client is None:
            raise BridgeError("httpx is not installed")
        tools = self.all_tools()
        payload: dict[str, Any] = {
            "model": model_id,
            "messages": self._messages,
            "stream": True,
            "temperature": 0.3,
        }
        if tools:
            payload["tools"] = tools
            payload["tool_choice"] = "auto"

        content_parts: list[str] = []
        calls: dict[int, dict[str, Any]] = {}
        try:
            with self._client.stream(
                "POST",
                f"{self.config.base_url}/v1/chat/completions",
                json=payload,
            ) as response:
                if response.status_code >= 400:
                    body = response.read().decode("utf-8", "replace")
                    raise BridgeError(
                        f"chat request failed: HTTP {response.status_code} {body[:400]}"
                    )
                for line in response.iter_lines():
                    self._check_cancel()
                    if not line:
                        continue
                    if line.startswith("data:"):
                        line = line[5:].strip()
                    if not line or line == "[DONE]":
                        continue
                    try:
                        chunk = json.loads(line)
                    except ValueError:
                        LOG.debug("skipping non-JSON stream line: %s", line[:100])
                        continue
                    if chunk.get("error"):
                        raise BridgeError(f"server error: {chunk['error']}")
                    self._consume_chunk(chunk, content_parts, calls)
        except TurnCancelled:
            self._partial_text = "".join(content_parts)
            self._append_partial_assistant(content_parts, calls)
            raise
        except httpx.HTTPError as exc:
            self._append_partial_assistant(content_parts, calls)
            raise BridgeError(f"connection to llama-server failed: {exc}") from exc

        self.touch()
        tool_calls = []
        for index in sorted(calls):
            call = calls[index]
            if not call.get("name"):
                continue
            call["id"] = call.get("id") or f"call_{index}"
            tool_calls.append(
                {
                    "id": call["id"],
                    "type": "function",
                    "function": {
                        "name": call["name"],
                        "arguments": call.get("arguments") or "{}",
                    },
                }
            )
        text = "".join(content_parts)
        if not tool_calls:
            self._messages.append({"role": "assistant", "content": text})
        return text, tool_calls

    def _trim_history(self) -> None:
        """Keep the system prompt and the most recent turn-aligned messages."""
        system = self._messages[0]
        rest = self._messages[1:]
        budget = 40000
        total = 0
        cut = len(rest)
        while cut > 0 and len(rest) - cut < 40:
            message = rest[cut - 1]
            size = _message_size(message)
            if total + size > budget:
                break
            total += size
            cut -= 1
        if cut <= 0:
            return
        while cut < len(rest) and rest[cut].get("role") != "user":
            cut += 1
        if cut >= len(rest):
            return
        LOG.info("trimming %d old message(s) from history", cut)
        self._messages = [system] + rest[cut:]

    def _consume_chunk(
        self,
        chunk: dict[str, Any],
        content_parts: list[str],
        calls: dict[int, dict[str, Any]],
    ) -> None:
        choices = chunk.get("choices") or []
        if not choices:
            return
        delta = choices[0].get("delta") or {}
        content = delta.get("content")
        if isinstance(content, list):
            content = "".join(
                part.get("text", "") for part in content if isinstance(part, dict)
            )
        if content:
            content_parts.append(content)
            self.emit({"type": "text_delta", "text": content})
        for call in delta.get("tool_calls") or []:
            if not isinstance(call, dict):
                continue
            index = int(call.get("index") or 0)
            slot = calls.setdefault(index, {"arguments": ""})
            if call.get("id"):
                slot["id"] = call["id"]
            function = call.get("function") or {}
            if function.get("name"):
                slot["name"] = function["name"]
            if function.get("arguments"):
                slot["arguments"] += str(function["arguments"])

    def _append_partial_assistant(
        self, content_parts: list[str], calls: dict[int, dict[str, Any]]
    ) -> None:
        text = "".join(content_parts)
        if text or calls:
            message: dict[str, Any] = {"role": "assistant", "content": text}
            if calls:
                message["tool_calls"] = [
                    {
                        "id": slot.get("id") or f"call_{index}",
                        "type": "function",
                        "function": {
                            "name": slot.get("name", ""),
                            "arguments": slot.get("arguments") or "{}",
                        },
                    }
                    for index, slot in sorted(calls.items())
                    if slot.get("name")
                ]
            self._messages.append(message)

    def _run_tool_call(self, call: dict[str, Any]) -> None:
        name = call["function"]["name"]
        raw_args = call["function"].get("arguments") or "{}"
        try:
            args = json.loads(raw_args) if isinstance(raw_args, str) else raw_args
            if not isinstance(args, dict):
                raise ValueError("tool arguments must be an object")
        except ValueError as exc:
            args = {}
            ok, summary, result = False, "invalid tool arguments", {
                "error": "bad_arguments",
                "message": f"{exc}: {_truncate(str(raw_args), 300)}",
            }
            self.emit({"type": "tool_start", "name": name, "args": {}})
            self.emit(
                {"type": "tool_end", "name": name, "ok": False,
                 "summary": summary, "result": result}
            )
            self._messages.append(
                {"role": "tool", "tool_call_id": call["id"],
                 "content": json.dumps(result, ensure_ascii=False)}
            )
            return

        self.emit({"type": "tool_start", "name": name, "args": args})
        if name in LOCAL_TOOL_NAMES:
            ok, summary, result = self.execute_local_tool(name, args)
        else:
            ok, summary, result = self.call_server_tool(name, args)
        self.touch()
        self.emit(
            {
                "type": "tool_end",
                "name": name,
                "ok": ok,
                "summary": summary,
                "result": result,
            }
        )
        if name == "digup_search" and ok:
            media_event = self._media_event(result)
            if media_event is not None:
                self.emit(media_event)
        content = result if isinstance(result, str) else json.dumps(result, ensure_ascii=False)
        self._messages.append(
            {
                "role": "tool",
                "tool_call_id": call["id"],
                "content": _truncate(content, MAX_TOOL_RESULT_CHARS),
            }
        )

    # --------------------------------------------------------------- commands

    def new_conversation(self) -> None:
        with self._turn_lock:
            if self._busy:
                self._cancel.set()
        self.cancel_voice(wait=True)
        self.wait_turn(5.0)
        self._messages = [{"role": "system", "content": SYSTEM_PROMPT}]
        self.emit({"type": "state", "state": "idle"})

    def cancel(self) -> None:
        self._cancel.set()
        self._voice_cancel.set()
        if not self._busy and not self.voice_active():
            self.emit({"type": "state", "state": "idle"})

    def shutdown(self) -> None:
        self._stop.set()
        self._cancel.set()
        self._voice_cancel.set()
        self.stop_control_server()
        self.wait_voice(3.0)
        self.wait_turn(3.0)
        with self._timer_lock:
            for timer in self._timers.values():
                timer.cancel()
            self._timers.clear()
        self.stop_server()

    # ------------------------------------------------------------------- loop

    def run(self) -> int:
        if httpx is None:
            self.emit_error("httpx is not installed", "dependency_missing")
            return 1
        scan_error: str | None = None
        try:
            self.scan_models()
        except BridgeError as exc:
            scan_error = str(exc)
            LOG.warning("model scan failed: %s", exc)
        router_entries = self._router_entries()
        available = [model.id for model in self.models_snapshot()]
        available += [
            str(entry["id"]) for entry in router_entries or []
            if str(entry["id"]) not in available
        ]
        self._current_model = self._select_initial_model(available)
        selected = next(
            (
                model
                for model in self.models_snapshot()
                if model.id == self._current_model
            ),
            None,
        )
        ready: dict[str, Any] = {
            "type": "ready",
            "model": selected.name if selected else (self._current_model or ""),
        }
        if self._current_model:
            ready["id"] = self._current_model
        self.emit(ready)
        self.emit({"type": "state", "state": "idle"})
        self._emit_models(router_entries)
        self.emit_current_model()
        if scan_error is not None:
            self.emit_error(scan_error, "preset_error")
        elif not available:
            self.emit_error(self.no_models_message(), "no_models")
        self.start_control_server()
        threading.Thread(target=self.idle_loop, name="lfm3-idle", daemon=True).start()

        try:
            for line in sys.stdin:
                if self._stop.is_set():
                    break
                line = line.strip()
                if not line:
                    continue
                self.touch()
                try:
                    command = json.loads(line)
                except ValueError:
                    self.emit_error("invalid JSON command", "bad_command")
                    continue
                if not isinstance(command, dict):
                    self.emit_error("command must be a JSON object", "bad_command")
                    continue
                try:
                    self.handle(command)
                except BridgeError as exc:
                    self.emit_error(str(exc), "bridge_error")
                except Exception as exc:
                    LOG.exception("command failed")
                    self.emit_error(f"internal error: {exc}", "internal_error")
                if self._stop.is_set():
                    break
        except KeyboardInterrupt:
            LOG.info("interrupted")
        finally:
            self.shutdown()
        return 0

    def handle(self, command: dict[str, Any]) -> None:
        name = str(command.get("cmd") or "")
        if name == "text":
            attachments = command.get("attachments") or []
            self.start_turn(str(command.get("text") or ""), attachments)
        elif name == "start_listen":
            self.start_listen()
        elif name == "stop_listen":
            self.stop_listen(bool(command.get("commit", True)))
        elif name == "cancel":
            self.cancel()
        elif name == "new":
            self.new_conversation()
        elif name == "models_list":
            self.models_list()
        elif name == "models_refresh":
            self.models_refresh()
        elif name == "model_select":
            self.model_select(str(command.get("id") or ""))
        elif name == "model_unload":
            self.model_unload(str(command.get("id") or ""))
        elif name == "set_voice":
            self._speak_text = bool(command.get("enabled", True))
            self.emit({"type": "voice", "enabled": self._speak_text})
        elif name == "shutdown":
            self._stop.set()
        else:
            self.emit_error(f"unknown command: {name}", "bad_command")


class ControlServer(ThreadingHTTPServer):
    """Threaded localhost HTTP server for the Translator tab."""

    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, bridge: Bridge, port: int):
        self.bridge = bridge
        super().__init__(("127.0.0.1", port), ControlHandler)


class ControlHandler(BaseHTTPRequestHandler):
    """Minimal JSON API: /health, /models, /model, /model/unload, /translate."""

    protocol_version = "HTTP/1.1"
    server_version = "lfm3-bridge"
    sys_version = ""
    MAX_BODY = 64 * 1024

    @property
    def bridge(self) -> Bridge:
        return self.server.bridge  # type: ignore[attr-defined]

    def log_message(self, fmt: str, *args: Any) -> None:
        LOG.debug("control API: " + fmt, *args)

    def _cors_headers(self) -> dict[str, str]:
        origin = self.headers.get("Origin") or ""
        if origin and LOCAL_ORIGIN_RE.match(origin):
            return {
                "Access-Control-Allow-Origin": origin,
                "Vary": "Origin",
                "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
                "Access-Control-Allow-Headers": "Content-Type",
                "Access-Control-Max-Age": "600",
            }
        return {}

    def _send(self, status: int, payload: dict[str, Any]) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        for key, value in self._cors_headers().items():
            self.send_header(key, value)
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def _read_json(self) -> dict[str, Any]:
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            raise ControlError(400, "invalid Content-Length") from None
        if length < 0 or length > self.MAX_BODY:
            self.close_connection = True
            raise ControlError(413, "request body too large")
        raw = self.rfile.read(length) if length else b""
        if not raw:
            return {}
        try:
            payload = json.loads(raw)
        except ValueError:
            raise ControlError(400, "invalid JSON body") from None
        if not isinstance(payload, dict):
            raise ControlError(400, "body must be a JSON object")
        return payload

    def do_OPTIONS(self) -> None:
        self.send_response(204)
        for key, value in self._cors_headers().items():
            self.send_header(key, value)
        self.send_header("Allow", "GET, POST, OPTIONS")
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self) -> None:
        try:
            path = urlsplit(self.path).path.rstrip("/") or "/"
            if path == "/health":
                self._send(
                    200, {"ok": True, "model": self.bridge.current_model()}
                )
            elif path == "/models":
                self._send(
                    200,
                    {
                        "models": self.bridge._models_payload(),
                        "current": self.bridge.current_model(),
                    },
                )
            else:
                self._send(404, {"ok": False, "error": "not found"})
        except Exception as exc:
            LOG.exception("control API GET failed")
            self._send(500, {"ok": False, "error": f"internal error: {exc}"})

    def do_POST(self) -> None:
        try:
            path = urlsplit(self.path).path.rstrip("/") or "/"
            payload = self._read_json()
            if path == "/model":
                self._handle_model(payload)
            elif path == "/model/unload":
                self._handle_model_unload(payload)
            elif path == "/translate":
                self._handle_translate(payload)
            else:
                self._send(404, {"ok": False, "error": "not found"})
        except ControlError as exc:
            self._send(exc.status, {"ok": False, "error": str(exc)})
        except BridgeError as exc:
            self._send(500, {"ok": False, "error": str(exc)})
        except Exception as exc:
            LOG.exception("control API POST failed")
            self._send(500, {"ok": False, "error": f"internal error: {exc}"})

    def _handle_model(self, payload: dict[str, Any]) -> None:
        model_id = payload.get("id")
        if not isinstance(model_id, str) or not model_id.strip():
            raise ControlError(400, "id is required")
        try:
            current = self.bridge._select_model(model_id)
        except BridgeError as exc:
            message = str(exc)
            status = 404 if message.startswith("unknown model") else 400
            raise ControlError(status, message) from None
        self._send(200, {"ok": True, "current": current})

    def _handle_model_unload(self, payload: dict[str, Any]) -> None:
        model_id = payload.get("id", payload.get("model"))
        if not isinstance(model_id, str) or not model_id.strip():
            raise ControlError(400, "id is required")
        try:
            current = self.bridge.unload_model(model_id)
        except BridgeError as exc:
            message = str(exc)
            if message.startswith("unknown model"):
                status = 404
            elif message.startswith("llama-server router is not running"):
                status = 503
            else:
                status = 409
            raise ControlError(status, message) from None
        self._send(200, {"ok": True, "current": current})

    def _handle_translate(self, payload: dict[str, Any]) -> None:
        text = payload.get("text")
        if not isinstance(text, str):
            raise ControlError(400, "text must be a string")
        text = text.strip()
        if not text:
            raise ControlError(400, "text is empty")
        if len(text) > MAX_TRANSLATE_CHARS:
            raise ControlError(
                400, f"text is longer than {MAX_TRANSLATE_CHARS} characters"
            )

        source = payload.get("source")
        source = "auto" if source in (None, "") else _language(source, "source")
        target = payload.get("target")
        if target in (None, ""):
            raise ControlError(400, "target language is required")
        target = _language(target, "target")

        backend = payload.get("backend")
        if backend in (None, ""):
            backend = self.bridge.config.translate_backend
        if not isinstance(backend, str):
            raise ControlError(400, "backend must be a string")
        backend = backend.strip().lower()
        if backend not in TRANSLATE_BACKENDS:
            raise ControlError(400, "backend must be llama or trans")

        engine = payload.get("engine")
        if engine in (None, ""):
            engine = self.bridge.config.translate_engine
        if not isinstance(engine, str):
            raise ControlError(400, "engine must be a string")
        engine = engine.strip().lower()
        if engine not in TRANSLATE_ENGINES:
            raise ControlError(
                400, "engine must be auto, google, bing, or yandex"
            )

        try:
            if backend == "llama":
                result = self.bridge.translate_llama(text, source, target)
            else:
                result = self.bridge.translate_shell(text, source, target, engine)
        except BridgeError as exc:
            raise ControlError(502, str(exc)) from None
        self._send(
            200,
            {
                "ok": True,
                "text": result,
                "backend": backend,
                "source": source,
                "target": target,
            },
        )


LANGUAGE_RE = re.compile(r"^[\w\u0080-\uffff .()\-]{1,40}$")
LOCAL_ORIGIN_RE = re.compile(
    r"^https?://(?:localhost|127\.0\.0\.1|\[::1\])(?::\d+)?$"
)


def _translate_instruction(source: str, target: str) -> str:
    return (
        f"Translate the user text from {source} to {target}. "
        "Return only the translation, no commentary."
    )


def _language(value: Any, field: str) -> str:
    """Accept a BCP-47 style code or a native name printed by trans."""
    if not isinstance(value, str):
        raise ControlError(400, f"{field} must be a string")
    text = value.strip()
    if not text:
        raise ControlError(400, f"{field} is empty")
    if text.startswith("-"):
        raise ControlError(400, f"{field} must not start with '-'")
    if not LANGUAGE_RE.fullmatch(text):
        raise ControlError(400, f"{field} is not a language code or name")
    return text


def _truncate(text: str, limit: int) -> str:
    return text if len(text) <= limit else text[:limit] + "..."


def _summary(text: str) -> str:
    line = " ".join(str(text).split())
    return _truncate(line, 120)


def _describe_error(data: Any) -> str:
    if not isinstance(data, dict):
        return str(data).strip()
    error = data.get("error")
    if isinstance(error, dict):
        return str(error.get("message") or error.get("type") or error)
    if error:
        return str(error)
    return str(data.get("message") or "").strip()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="LFM3 Quickshell assistant bridge")
    parser.add_argument("--config", help="path to config.env")
    parser.add_argument(
        "--log-level", default=os.environ.get("LFM3_LOG_LEVEL", "info")
    )
    args = parser.parse_args(argv)

    logging.basicConfig(
        stream=sys.stderr,
        level=getattr(logging, str(args.log_level).upper(), logging.INFO),
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    logging.getLogger("httpx").setLevel(logging.WARNING)

    config = load_config(args.config)
    LOG.info(
        "bridge config: cache=%s preset=%s default=%s max=%s port=%s ctx=%s "
        "idle=%ss mcp=%s digup=%s media=%s (%s MB) control=%s "
        "translate=%s/%s",
        config.models_cache,
        config.models_preset,
        config.default_model or "(first)",
        config.models_max,
        config.port,
        config.ctx,
        config.idle_timeout,
        config.mcp_config if config.mcp_config.is_file() else "none",
        config.digup_bin,
        config.media_path,
        config.media_max_mb,
        config.control_port,
        config.translate_backend,
        config.translate_engine,
    )
    if config.model_override is not None:
        LOG.info("MODEL override enabled: %s", config.model_override)

    bridge = Bridge(config)

    def on_signal(signum: int, _frame: Any) -> None:
        LOG.info("received signal %s", signum)
        bridge._stop.set()
        bridge._cancel.set()

    signal.signal(signal.SIGTERM, on_signal)
    signal.signal(signal.SIGINT, on_signal)
    try:
        return bridge.run()
    except Exception as exc:
        LOG.exception("fatal bridge error")
        bridge.emit_error(f"fatal error: {exc}", "fatal")
        return 1


if __name__ == "__main__":
    sys.exit(main())
