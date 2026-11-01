#!/bin/bash
# Shared helpers for the dots-hyprland-extensions recorders.
# Sourced by rec-screen.sh and rec-mic.sh; not meant to be executed directly.

REC_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/qs-recorder"
REC_STATE="$REC_CACHE/state.json"
REC_CFG="$HOME/.config/illogical-impulse/recorder.json"

mkdir -p "$REC_CACHE"

rec_cfg_init() {
    mkdir -p "$(dirname "$REC_CFG")"
    [[ -f "$REC_CFG" ]] && return 0
    cat > "$REC_CFG" <<EOF
{
  "videoDir": "$HOME/Videos",
  "audioDir": "$HOME/Music/Recordings",
  "screenArea": "region",
  "screenAudio": "system",
  "audioChannels": 2
}
EOF
}

# rec_cfg <jq filter> -> prints the value or nothing
rec_cfg() {
    rec_cfg_init
    jq -r "$1 // empty" "$REC_CFG" 2>/dev/null
}

rec_cfg_set() { # rec_cfg_set <key> <value>
    rec_cfg_init
    local tmp="$REC_CFG.tmp.$$"
    jq --arg v "$2" ".[\"$1\"] = \$v" "$REC_CFG" > "$tmp" 2>/dev/null && mv "$tmp" "$REC_CFG" || rm -f "$tmp"
}

rec_state_init() {
    [[ -s "$REC_STATE" ]] && return 0
    printf '{"screen":null,"mic":null}\n' > "$REC_STATE"
}

# Read-only accessor. Missing file / bad JSON both yield empty output.
rec_state_get() {
    jq -r "$1 // empty" "$REC_STATE" 2>/dev/null
}

# Atomic, lock-protected state edit.
# Usage: rec_state_edit [jq args...] '<filter>'   (filter must be the last argument)
rec_state_edit() {
    local filter="${!#}"
    local -a jqargs=("${@:1:$#-1}")
    (
        flock 9
        rec_state_init
        local tmp="$REC_STATE.tmp.$$"
        if jq "${jqargs[@]}" "$filter" "$REC_STATE" > "$tmp" 2>/dev/null; then
            # In-place copy (same inode): atomic rename would silently break the
            # inotify watches used by the panel toggles and the recorder popup.
            cat "$tmp" > "$REC_STATE"
        fi
        rm -f "$tmp"
    ) 9>"$REC_CACHE/state.lock"
}

rec_notify() { # rec_notify <summary> <body> [icon-app-name]
    notify-send -a "${3:-Recorder}" "$1" "$2" >/dev/null 2>&1 &
}

rec_tag() { date '+%Y-%m-%d_%H.%M.%S'; }

# A pid of 0/empty must never reach kill: 0 means "the caller's process group".
rec_pid_alive() {
    [[ "${1:-}" =~ ^[1-9][0-9]*$ ]] || return 1
    kill -0 "$1" 2>/dev/null
}

rec_wait_exit() { # rec_wait_exit <pid> <tenths-of-a-second>
    local pid="$1" tries="${2:-60}"
    local i=0
    while rec_pid_alive "$pid" && (( i < tries )); do
        sleep 0.1
        (( i++ ))
    done
    ! rec_pid_alive "$pid"
}

rec_ffprobe_duration() { # seconds, with 2 decimals
    ffprobe -v error -show_entries format=duration -of csv=p=0 "$1" 2>/dev/null | cut -d, -f1
}

rec_human_size() {
    local b="${1:-0}"
    if (( b < 1024 )); then echo "${b} B"
    elif (( b < 1048576 )); then awk -v b="$b" 'BEGIN{printf "%.1f KB", b/1024}'
    elif (( b < 1073741824 )); then awk -v b="$b" 'BEGIN{printf "%.1f MB", b/1048576}'
    else awk -v b="$b" 'BEGIN{printf "%.1f GB", b/1073741824}'
    fi
}

rec_clock() { # seconds -> m:ss or h:mm:ss
    awk -v t="${1:-0}" 'BEGIN{
        t = int(t + 0.5)
        if (t >= 3600) printf "%d:%02d:%02d", int(t/3600), int((t%3600)/60), t%60
        else printf "%d:%02d", int(t/60), t%60
    }'
}
