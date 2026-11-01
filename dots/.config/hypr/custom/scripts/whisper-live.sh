#!/usr/bin/env bash
# whisper-live.sh
# ---------------
# Hold-to-talk dictation.
#
#   start   (SUPER+CTRL+SPACE press):
#             - detect mic input (wireless/BT first, else default)
#             - write cava config that visualizes that mic
#             - record the mic to a growing wav
#             - launch the WhisperLive.qml popup (live spectrum)
#   stop    (SUPER+CTRL+SPACE release):
#             - stop recording
#             - transcribe the whole wav:
#                 * if whisper-server is loaded  -> POST /inference (fast)
#                 * otherwise                    -> one-shot whisper-cli
#                   (model loads for this call, then frees itself "unloads")
#             - copy transcript to clipboard + notify
#             - signal the popup to fade out
#
# Bound via custom/keybinds.lua press/release pair.
set -euo pipefail

CONFIG_FILE="$HOME/.config/whisper-server/config.env"
# shellcheck disable=SC1090
source "$CONFIG_FILE"

MARKER="$WHISPER_TMP/done"
REC_PCM="$WHISPER_TMP/rec.pcm"   # raw s16le capture (valid even if killed)
REC_WAV="$WHISPER_TMP/rec.wav"   # final wav, kept for debugging
REC_PIDFILE="$WHISPER_TMP/rec.pid"
CAVA_CONF="$WHISPER_TMP/cava-config.txt"

mkdir -p "$WHISPER_TMP"

resolve_mic() {
    # 0) Explicit pin wins: WHISPER_MIC=<source name> in config.env
    if [[ -n "${WHISPER_MIC:-}" ]]; then
        echo "$WHISPER_MIC"
        return
    fi
    # 1) Prefer an external / USB / wireless mic over the built-in one
    local ext
    ext=$(pactl list sources short 2>/dev/null | awk '{print $2}' \
        | grep -iE 'usb|composite|jieli|bluetooth|airpods|wireless|headset|freebuds|buds|mic' \
        | grep -viE 'analog-stereo' | head -n1 || true)
    if [[ -n "$ext" ]]; then
        echo "$ext"
        return
    fi
    # 2) Fallback to the default source
    pactl get-default-source 2>/dev/null || echo "@DEFAULT_SOURCE@"
}

write_cava_conf() {
    local source="$1"
    cat >"$CAVA_CONF" <<EOF
[general]
mode = normal
framerate = 60
autosens = 1
bars = 48

[input]
method = pulse
source = $source

[output]
method = raw
raw_target = /dev/stdout
data_format = ascii
channels = mono
mono_option = average

[smoothing]
noise_reduction = 20
EOF
}

server_ready() {
    curl -sf "$HEALTH_URL" >/dev/null 2>&1
}

# Transcribe the recorded wav with one-shot whisper-cli (GPU, retry CPU on fail).
oneshot_transcribe() {
    local try ng="$WHISPER_BIN/whisper-cli" out
    local args=(-m "$MODEL" -f "$REC_WAV" -l "$WHISPER_LANG"
                -tp 0.7 --vad -vm "$VAD_MODEL"
                -vt 0.05 -vspd 100 -vsd 50 -vmsd 60 -vp 500 -vo 0.5
                -nt -np)
    for try in gpu cpu; do
        if [[ "$try" == cpu ]]; then
            args+=(-ng)
        fi
        out=$("$ng" "${args[@]}" 2>/dev/null || true)
        out=$(printf '%s' "$out" | sed 's/^\s*//;s/\s*$//')
        [[ -n "$out" ]] && { printf '%s' "$out"; return 0; }
    done
    return 1
}

case "${1:-}" in
start)
    # always record (one-shot fallback handles a not-yet-loaded server)
    MIC=$(resolve_mic)
    write_cava_conf "$MIC"

    rm -f "$REC_PCM" "$REC_WAV" "$MARKER"

    # Record raw s16le PCM (16k mono). Not a wav: parec only writes the RIFF
    # header on graceful exit, so a SIGTERM would leave a truncated wav.
    # We wrap into a valid wav on stop.
    parec --raw --format=s16le --rate=16000 --channels=1 \
        --device="$MIC" > "$REC_PCM" &

    echo $! > "$REC_PIDFILE"

    qs -p "$HOME/.config/hypr/custom/WhisperLive.qml" &

    notify-send -a "Whisper Live" -i audio-input-microphone -u low \
        "Recording…" "release SUPER+CTRL+SPACE to transcribe"
    ;;
stop)
    if [[ -f "$REC_PIDFILE" ]]; then
        kill "$(cat "$REC_PIDFILE")" 2>/dev/null || true
        rm -f "$REC_PIDFILE"
        # let parec flush remaining bytes before we finalize
        sleep 0.3
    fi

    if [[ ! -s "$REC_PCM" ]]; then
        # nothing recorded; just dismiss popup
        rm -f "$REC_PCM"
        touch "$MARKER"
        exit 0
    fi

    # Wrap the raw PCM into a valid 16k mono wav
    ffmpeg -y -loglevel error \
        -f s16le -ar 16000 -ac 1 -i "$REC_PCM" \
        -c:a pcm_s16le "$REC_WAV"

    TEXT=""
    if server_ready; then
        # whisper-server is loaded: POST the whole wav to /inference
        [[ "$WHISPER_LANG" == "auto" ]] || LANG_FLAG=(-F "language=$WHISPER_LANG")
        TEXT=$(curl -sf -X POST "$INFERENCE_URL" \
            -F "file=@$REC_WAV;type=audio/wav" \
            -F "temperature=0.7" \
            -F "response_format=text" \
            "${LANG_FLAG[@]}" 2>/dev/null || true)
        TEXT=$(printf '%s' "$TEXT" | sed 's/^\s*//;s/\s*$//')
    else
        # server not loaded: one-shot whisper-cli (loads → transcribes → frees)
        notify-send -a "Whisper Live" -i system-run -u low \
            "Server not loaded" "one-shot transcription (may be slower)" &
        TEXT=$(oneshot_transcribe || true)
    fi

    if [[ -n "$TEXT" ]]; then
        printf '%s' "$TEXT" | wl-copy
        notify-send -a "Whisper Live" -i "edit-paste" -u normal \
            "Transcribed" "$TEXT" &
    else
        notify-send -a "Whisper Live" -i "dialog-information" -u low \
            "No speech detected" "Recording saved at $REC_WAV"
    fi

    # keep the wav + raw for debugging
    touch "$MARKER"
    ;;
*)
    echo "Usage: $0 start|stop" >&2
    exit 2
    ;;
esac