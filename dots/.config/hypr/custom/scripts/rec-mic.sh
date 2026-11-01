#!/bin/bash
# Microphone / voice recorder for the dots-hyprland-extensions quick toggle.
#
#   rec-mic.sh start
#   rec-mic.sh pause | resume | toggle-pause
#   rec-mic.sh stop [--discard]
#   rec-mic.sh toggle
#   rec-mic.sh status
#
# Records 48 kHz WAV with pw-record. Pause/resume is done by finalising the
# current WAV segment and starting a new one (SIGCONT/SIGSTOP on a PipeWire
# stream leaves an unreliable header and a hole in the timeline); stop then
# concatenates the segments losslessly. Final files go to audioDir from
# ~/.config/illogical-impulse/recorder.json (default ~/Music/Recordings).

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=rec-lib.sh
. "$HERE/rec-lib.sh"

say() { printf '[rec-mic] %s\n' "$*" >&2; }

mic_json() { rec_state_get '.mic'; }

mic_running() {
    local json pid
    json="$(mic_json)"
    [[ -n "$json" ]] || return 1
    pid="$(jq -r '.pid // empty' <<<"$json" 2>/dev/null)"
    rec_pid_alive "$pid"
}

channels() {
    local c; c="$(rec_cfg '.audioChannels')"
    [[ "$c" =~ ^[0-9]+$ ]] || c=2
    printf '%s' "$c"
}

spawn_segment() { # spawn_segment <file> -> echoes pid
    local file="$1"
    pw-record --rate 48000 --channels "$(channels)" "$file" >> "$REC_CACHE/mic.log" 2>&1 &
    local pid=$!
    sleep 0.2
    if ! rec_pid_alive "$pid"; then
        return 1
    fi
    printf '%s' "$pid"
}

clear_state() { rec_state_edit '.mic = null'; }

start_recording() {
    if mic_running; then
        say "already recording"
        return 0
    fi
    # A dead pid with leftover state means a crash; start clean.
    if [[ -n "$(mic_json)" ]]; then
        clear_state
    fi

    local audio_dir
    audio_dir="$(rec_cfg '.audioDir')"
    [[ -n "$audio_dir" ]] || audio_dir="$HOME/Music/Recordings"
    mkdir -p "$audio_dir" || { rec_notify "Recorder failed" "Cannot create $audio_dir"; return 1; }

    local dir="$REC_CACHE/mic-session-$(date +%s)-$$"
    mkdir -p "$dir" || return 1
    : > "$REC_CACHE/mic.log"

    local pid
    if ! pid="$(spawn_segment "$dir/seg-000.wav")"; then
        rm -rf "$dir"
        rec_notify "Recorder failed" "pw-record could not open the microphone"
        return 1
    fi

    local now; now="$(date +%s)"
    rec_state_edit \
        --argjson pid "$pid" \
        --argjson started "$now" \
        --argjson segmentStart "$now" \
        --argjson segmentIndex 0 \
        --argjson elapsed 0 \
        --arg dir "$dir" \
        '.mic = {
            running: true, paused: false, pid: $pid,
            started: $started, segmentStart: $segmentStart,
            segmentIndex: $segmentIndex, elapsed: $elapsed, dir: $dir
        }'

    rec_notify "Recording audio" "Microphone · WAV"
    say "started pid=$pid dir=$dir"
}

pause_recording() {
    local json; json="$(mic_json)"
    [[ -n "$json" ]] || return 0

    local pid paused dir idx elapsed seg_start now
    pid="$(jq -r '.pid // empty' <<<"$json")"
    paused="$(jq -r '.paused // false' <<<"$json")"
    dir="$(jq -r '.dir // empty' <<<"$json")"
    idx="$(jq -r '.segmentIndex // 0' <<<"$json")"
    elapsed="$(jq -r '.elapsed // 0' <<<"$json")"
    seg_start="$(jq -r '.segmentStart // 0' <<<"$json")"
    now="$(date +%s)"

    [[ "$paused" == "true" ]] && return 0

    if rec_pid_alive "$pid"; then
        kill -INT "$pid" 2>/dev/null
        rec_wait_exit "$pid" 60 || kill -TERM "$pid" 2>/dev/null
    fi
    sleep 0.1

    # Discard a segment that never produced usable audio.
    local seg
    seg="$(printf '%s/seg-%03d.wav' "$dir" "$idx")"
    if [[ -f "$seg" && "$(stat -c %s "$seg" 2>/dev/null || echo 0)" -lt 1024 ]]; then
        rm -f "$seg"
    fi

    local add=$(( now - seg_start ))
    (( add < 0 )) && add=0

    rec_state_edit --argjson elapsed "$(awk -v a="$elapsed" -v b="$add" 'BEGIN{printf "%.2f", a+b}')" \
        '.mic.paused = true | .mic.pid = 0 | .mic.elapsed = $elapsed'
    rec_notify "Recording paused" "Tap resume in the Recorder"
}

resume_recording() {
    local json; json="$(mic_json)"
    [[ -n "$json" ]] || return 0

    local paused dir idx
    paused="$(jq -r '.paused // false' <<<"$json")"
    dir="$(jq -r '.dir // empty' <<<"$json")"
    idx="$(jq -r '.segmentIndex // 0' <<<"$json")"
    [[ "$paused" == "true" ]] || return 0

    local nidx=$(( idx + 1 ))
    local pid
    if ! pid="$(spawn_segment "$(printf '%s/seg-%03d.wav' "$dir" "$nidx")")"; then
        rec_notify "Recorder failed" "Could not resume the microphone"
        return 1
    fi

    rec_state_edit --argjson pid "$pid" --argjson segmentStart "$(date +%s)" --argjson segmentIndex "$nidx" \
        '.mic.paused = false | .mic.pid = $pid | .mic.segmentStart = $segmentStart | .mic.segmentIndex = $segmentIndex'
}

stop_recording() { # stop_recording [--discard]
    local discard=0
    [[ "${1:-}" == "--discard" ]] && discard=1

    local json; json="$(mic_json)"
    if [[ -z "$json" ]]; then
        say "not recording"
        return 0
    fi

    local pid paused dir audio_dir elapsed seg_start now
    pid="$(jq -r '.pid // empty' <<<"$json")"
    paused="$(jq -r '.paused // false' <<<"$json")"
    dir="$(jq -r '.dir // empty' <<<"$json")"
    elapsed="$(jq -r '.elapsed // 0' <<<"$json")"
    seg_start="$(jq -r '.segmentStart // 0' <<<"$json")"
    now="$(date +%s)"

    if [[ "$paused" != "true" ]] && rec_pid_alive "$pid"; then
        kill -INT "$pid" 2>/dev/null
        rec_wait_exit "$pid" 60 || kill -TERM "$pid" 2>/dev/null
    fi
    sleep 0.15

    if [[ "$paused" != "true" ]]; then
        local add=$(( now - seg_start ))
        (( add < 0 )) && add=0
        elapsed="$(awk -v a="$elapsed" -v b="$add" 'BEGIN{printf "%.2f", a+b}')"
    fi

    local -a segs=()
    while IFS= read -r f; do
        [[ -s "$f" ]] && segs+=("$f")
    done < <(find "$dir" -maxdepth 1 -name 'seg-*.wav' 2>/dev/null | sort)

    if (( ${#segs[@]} == 0 )); then
        clear_state
        rm -rf "$dir"
        rec_notify "Nothing recorded" "The microphone produced no audio"
        return 0
    fi

    audio_dir="$(rec_cfg '.audioDir')"
    [[ -n "$audio_dir" ]] || audio_dir="$HOME/Music/Recordings"
    mkdir -p "$audio_dir"

    local out="$audio_dir/mic_$(rec_tag).wav"
    if [[ "$discard" == 1 ]]; then
        clear_state
        rm -rf "$dir"
        rec_notify "Recording discarded" "Nothing was saved"
        return 0
    fi

    if (( ${#segs[@]} == 1 )); then
        mv -f "${segs[0]}" "$out"
    else
        local list="$dir/segments.txt"
        : > "$list"
        local f
        for f in "${segs[@]}"; do
            printf "file '%s'\n" "$f" >> "$list"
        done
        if ! ffmpeg -hide_banner -loglevel error -y -f concat -safe 0 -i "$list" -c copy "$out" >> "$REC_CACHE/mic.log" 2>&1; then
            rec_notify "Recorder failed" "Could not join the recording segments"
            clear_state
            return 1
        fi
    fi

    clear_state
    rm -rf "$dir"

    local dur size
    dur="$(rec_ffprobe_duration "$out")"
    if [[ -z "$dur" ]] || awk -v d="$dur" 'BEGIN{exit !(d < 0.5)}'; then
        rm -f "$out"
        rec_notify "Recording too short" "Nothing was saved"
        return 0
    fi
    size="$(rec_human_size "$(stat -c %s "$out" 2>/dev/null || echo 0)")"
    rec_notify "Audio saved" "$(basename "$out") · $(rec_clock "$dur") · $size"
    say "saved $out duration=$dur size=$size elapsed=$elapsed"
}

case "${1:-toggle}" in
    start)        start_recording ;;
    pause)        pause_recording ;;
    resume)       resume_recording ;;
    toggle-pause) if [[ "$(mic_json | jq -r '.paused // false' 2>/dev/null)" == "true" ]]; then resume_recording; else pause_recording; fi ;;
    stop)         shift; stop_recording "${1:-}" ;;
    toggle)       if mic_running; then stop_recording; else start_recording; fi ;;
    status)       mic_json ;;
    *)            say "unknown command: $1"; exit 2 ;;
esac
