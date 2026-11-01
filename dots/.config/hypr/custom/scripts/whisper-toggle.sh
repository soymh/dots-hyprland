#!/usr/bin/env bash
# whisper-toggle.sh
# -----------------
# Start / stop the whisper.cpp transcription server (whisper-server).
#
#   * Server NOT running -> start it from config.env, notify loading -> loaded
#   * Server running      -> show a Quickshell confirmation popup; on confirm,
#                            kill the server, notify unloaded
#
# Bound to SUPER+CTRL+SEMICOLON in custom/keybinds.lua.
set -euo pipefail

CONFIG_FILE="$HOME/.config/whisper-server/config.env"
if [[ ! -f "$CONFIG_FILE" ]]; then
    notify-send -a "Whisper Server" -i dialog-error -u critical \
        "Config Not Found" "$CONFIG_FILE is missing"
    exit 1
fi
# shellcheck disable=SC1090
source "$CONFIG_FILE"

server_is_running() {
    curl -sf "$HEALTH_URL" >/dev/null 2>&1
}

# Used by WhisperConfirm.qml when the user confirms unloading.
if [[ "${1:-}" == "force-stop" ]]; then
    if [[ -f "$WHISPER_PIDFILE" ]]; then
        kill "$(cat "$WHISPER_PIDFILE")" 2>/dev/null || true
    fi
    local_pids() {
        ss -tlnp "sport = :$WHISPER_PORT" 2>/dev/null | grep -oP 'pid=\K[0-9]+' | sort -u || true
    }
    pids=$(local_pids)
    if [[ -n "$pids" ]]; then
        echo "$pids" | xargs kill 2>/dev/null || true
    fi
    rm -f "$WHISPER_PIDFILE"
    for _ in 1 2 3; do
        server_is_running || break
        sleep 1
    done
    if [[ -n "$pids" ]]; then
        echo "$pids" | xargs kill -9 2>/dev/null || true
    fi
    sleep 1
    if ! server_is_running; then
        notify-send -a "Whisper Server" -i media-playback-stop -u normal \
            "Whisper Server Unloaded" "Model unloaded, server stopped"
    fi
    exit 0
fi

kill_server() {
    if [[ -f "$WHISPER_PIDFILE" ]]; then
        local pid
        pid=$(cat "$WHISPER_PIDFILE")
        kill "$pid" 2>/dev/null || true
    fi
    # also kill any listener on the port (orphans)
    local pids
    pids=$(ss -tlnp "sport = :$WHISPER_PORT" 2>/dev/null | grep -oP 'pid=\K[0-9]+' | sort -u || true)
    if [[ -n "$pids" ]]; then
        echo "$pids" | xargs kill 2>/dev/null || true
    fi
    rm -f "$WHISPER_PIDFILE"
    # wait up to 3s
    for _ in 1 2 3; do
        server_is_running || return 0
        sleep 1
    done
    # escalate
    if [[ -n "${pids:-}" ]]; then
        echo "$pids" | xargs kill -9 2>/dev/null || true
    fi
}

if server_is_running; then
    # ---- SERVER RUNNING -> ask for unload confirmation ----
    # WhisperConfirm.qml runs the kill itself on confirm (via Quickshell.execDetached)
    # and merely dismisses on cancel. After it closes, we re-check health.
    qs -p "$HOME/.config/hypr/custom/WhisperConfirm.qml" 2>/dev/null || true
    sleep 1
    if ! server_is_running; then
        notify-send -a "Whisper Server" -i media-playback-stop -u normal \
            "Whisper Server Unloaded" "Model unloaded, server stopped"
    else
        notify-send -a "Whisper Server" -i dialog-information -u low \
            "Whisper Server" "Unload cancelled"
    fi
    exit 0
fi

# ---- SERVER NOT RUNNING -> start it ----
if [[ ! -f "$MODEL" ]]; then
    notify-send -a "Whisper Server" -i dialog-error -u critical \
        "Model not found" "$MODEL"
    exit 1
fi
if [[ ! -f "$VAD_MODEL" ]]; then
    notify-send -a "Whisper Server" -i dialog-error -u critical \
        "VAD model not found" "$VAD_MODEL"
    exit 1
fi

mkdir -p "$(dirname "$WHISPER_LOGFILE")"
eval "$WHISPER_SERVER_CMD" >"$WHISPER_LOGFILE" 2>&1 &
SERVER_PID=$!
echo "$SERVER_PID" > "$WHISPER_PIDFILE"

notify-send -a "Whisper Server" -i media-playback-start -u low \
    "Whisper Server loading…" "Loading large-v3-turbo model"

# wait up to 60s for readiness
for i in $(seq 1 60); do
    if server_is_running; then
        notify-send -a "Whisper Server" -i media-playback-start -u normal \
            "Whisper Server Ready" \
            "Hold SUPER+CTRL+SPACE to transcribe with the mic"
        exit 0
    fi
    sleep 1
done

# timeout
kill "$SERVER_PID" 2>/dev/null || true
rm -f "$WHISPER_PIDFILE"
notify-send -a "Whisper Server" -i dialog-error -u critical \
    "Whisper Server Failed" "Did not become ready in 60s\nCheck $WHISPER_LOGFILE"
exit 1