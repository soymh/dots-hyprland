#!/bin/bash
# Screen recorder for the dots-hyprland-extensions quick toggle.
#
#   rec-screen.sh start [--area region|full] [--audio silent|system|mic|both]
#   rec-screen.sh stop
#   rec-screen.sh toggle
#   rec-screen.sh configure [--area ...] [--audio ...]
#   rec-screen.sh status
#
# Records with wf-recorder. Audio modes:
#   silent  no audio
#   system  default sink monitor
#   mic     default input source
#   both    monitor in the mp4 + mic to a temp WAV, mixed into one AAC track on stop
#
# State is kept in $XDG_CACHE_HOME/qs-recorder/state.json so the panel toggles and
# the popups can follow it without polling the process table.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=rec-lib.sh
. "$HERE/rec-lib.sh"

log_file="$REC_CACHE/screen.log"

say() { printf '[rec-screen] %s\n' "$*" >&2; }

focused_monitor() {
    hyprctl monitors -j 2>/dev/null | jq -r '.[] | select(.focused == true) | .name' 2>/dev/null | head -n1
}

monitor_source() {
    local sink
    sink="$(pactl get-default-sink 2>/dev/null)"
    if [[ -n "$sink" ]]; then
        printf '%s.monitor' "$sink"
        return 0
    fi
    pactl list short sources 2>/dev/null | awk '/monitor/ {print $2; exit}'
}

input_source() {
    pactl get-default-source 2>/dev/null \
        || pactl list short sources 2>/dev/null | awk '$2 !~ /monitor/ {print $2; exit}'
}

mic_is_muted() {
    wpctl get-volume @DEFAULT_AUDIO_SOURCE@ 2>/dev/null | grep -q MUTED
}

screen_json() { rec_state_get '.screen'; }

screen_running() {
    local json pid
    json="$(screen_json)"
    [[ -n "$json" ]] || return 1
    pid="$(jq -r '.pid // empty' <<<"$json" 2>/dev/null)"
    rec_pid_alive "$pid"
}

screen_pid() { screen_json | jq -r '.pid // empty' 2>/dev/null; }

cleanup_temp_mic() { # cleanup_temp_mic <path>
    [[ -n "${1:-}" && -f "${1:-}" ]] && rm -f "$1"
}

start_recording() {
    local area="" audio=""

    while (( $# )); do
        case "$1" in
            --area)  area="${2:-}"; shift 2 ;;
            --audio) audio="${2:-}"; shift 2 ;;
            *) say "ignoring unknown argument: $1"; shift ;;
        esac
    done

    rec_cfg_init
    area="${area:-$(rec_cfg '.screenArea')}"
    audio="${audio:-$(rec_cfg '.screenAudio')}"
    [[ "$area" =~ ^(region|full)$ ]] || area="region"
    [[ "$audio" =~ ^(silent|system|mic|both)$ ]] || audio="system"
    rec_cfg_set screenArea "$area"
    rec_cfg_set screenAudio "$audio"

    if screen_running; then
        say "already recording"
        return 0
    fi
    # Reached here without a live recorder: any leftover state is stale.
    if [[ -n "$(screen_json)" ]]; then
        rec_state_edit '.screen = null'
    fi

    local video_dir
    video_dir="$(rec_cfg '.videoDir')"
    [[ -n "$video_dir" ]] || video_dir="$HOME/Videos"
    mkdir -p "$video_dir" || { rec_notify "Screen recording failed" "Cannot create $video_dir"; return 1; }

    local geometry=""
    if [[ "$area" == "region" ]]; then
        if ! geometry="$(slurp 2>/dev/null)" || [[ -z "$geometry" ]]; then
            rec_notify "Recording cancelled" "No region selected"
            return 0
        fi
    fi

    local out="$video_dir/recording_$(rec_tag).mp4"
    local wfout="$out"
    local mic_tmp=""
    [[ "$audio" == "both" ]] && wfout="$out.video.mp4"

    local -a wfargs=(--pixel-format yuv420p -f "$wfout")
    if [[ "$area" == "region" ]]; then
        wfargs+=(-g "$geometry")
    else
        local mon; mon="$(focused_monitor)"
        [[ -n "$mon" ]] && wfargs+=(-o "$mon")
    fi

    local sys_src="" in_src=""
    case "$audio" in
        system)
            sys_src="$(monitor_source)"
            [[ -n "$sys_src" ]] && wfargs+=("--audio=$sys_src")
            ;;
        mic)
            in_src="$(input_source)"
            [[ -n "$in_src" ]] && wfargs+=("--audio=$in_src")
            ;;
        both)
            sys_src="$(monitor_source)"
            in_src="$(input_source)"
            [[ -n "$sys_src" ]] && wfargs+=("--audio=$sys_src")
            ;;
    esac

    if [[ "$audio" =~ ^(mic|both)$ ]] && mic_is_muted; then
        rec_notify "Microphone is muted" "Recording will contain silence until you unmute it"
    fi

    local pid
    : > "$log_file"
    wf-recorder "${wfargs[@]}" >> "$log_file" 2>&1 &
    pid=$!
    sleep 0.4
    if ! rec_pid_alive "$pid"; then
        rec_notify "Screen recording failed" "$(tail -n 3 "$log_file" | tr '\n' ' ' | cut -c1-180)"
        cleanup_temp_mic "$mic_tmp"
        return 1
    fi

    local mic_pid=0
    if [[ "$audio" == "both" ]]; then
        mic_tmp="$REC_CACHE/screen-mic-$$.wav"
        local channels; channels="$(rec_cfg '.audioChannels')"
        [[ "$channels" =~ ^[0-9]+$ ]] || channels=2
        pw-record --rate 48000 --channels "$channels" "$mic_tmp" >> "$log_file" 2>&1 &
        mic_pid=$!
        sleep 0.25
        if ! rec_pid_alive "$mic_pid"; then
            kill -INT "$pid" 2>/dev/null
            rec_notify "Screen recording failed" "pw-record could not open the default microphone"
            cleanup_temp_mic "$mic_tmp"
            return 1
        fi
    fi

    rec_state_edit \
        --argjson pid "$pid" \
        --argjson micPid "$mic_pid" \
        --argjson started "$(date +%s)" \
        --arg file "$out" \
        --arg tempFile "$wfout" \
        --arg tempMic "$mic_tmp" \
        --arg audio "$audio" \
        --arg area "$area" \
        '.screen = {
            running: true, pid: $pid, micPid: $micPid, started: $started,
            file: $file, tempFile: $tempFile, tempMic: $tempMic,
            audio: $audio, area: $area
        }'

    local label
    case "$audio" in
        silent) label="no audio" ;;
        system) label="system audio" ;;
        mic)    label="microphone" ;;
        both)   label="system + mic" ;;
    esac
    rec_notify "Recording" "$(basename "$out") · $label"
    say "started pid=$pid audio=$audio area=$area file=$out"
}

stop_recording() {
    local json
    json="$(screen_json)"
    if [[ -z "$json" ]]; then
        say "not recording"
        return 0
    fi

    local pid mic_pid file temp_file temp_mic audio
    pid="$(jq -r '.pid // empty' <<<"$json")"
    mic_pid="$(jq -r '.micPid // 0' <<<"$json")"
    file="$(jq -r '.file // empty' <<<"$json")"
    temp_file="$(jq -r '.tempFile // empty' <<<"$json")"
    temp_mic="$(jq -r '.tempMic // empty' <<<"$json")"
    audio="$(jq -r '.audio // empty' <<<"$json")"

    if rec_pid_alive "$pid"; then
        kill -INT "$pid" 2>/dev/null
        rec_wait_exit "$pid" 100 || kill -TERM "$pid" 2>/dev/null
    fi
    if rec_pid_alive "$mic_pid"; then
        kill -INT "$mic_pid" 2>/dev/null
        rec_wait_exit "$mic_pid" 50 || kill -TERM "$mic_pid" 2>/dev/null
    fi
    sleep 0.3

    local have_output=0
    if [[ "$audio" == "both" && -n "$temp_file" && -s "$temp_file" ]]; then
        if [[ -n "$temp_mic" && -s "$temp_mic" ]] && ffmpeg -hide_banner -loglevel error -y \
                -i "$temp_file" -i "$temp_mic" \
                -filter_complex "[0:a][1:a]amix=inputs=2:duration=longest:dropout_transition=0[a]" \
                -map 0:v -map "[a]" -c:v copy -c:a aac -b:a 192k "$file" >> "$log_file" 2>&1; then
            rm -f "$temp_file"
            have_output=1
        else
            # Keep both halves rather than losing the recording.
            [[ "$temp_file" != "$file" ]] && mv -f "$temp_file" "$file"
            [[ -n "$temp_mic" && -s "$temp_mic" ]] && mv -f "$temp_mic" "${file%.mp4}.mic.wav"
            rec_notify "Recording finished (not mixed)" "Mixing failed; mic kept as $(basename "${file%.mp4}").mic.wav"
            have_output=1
        fi
    elif [[ -s "$file" ]]; then
        have_output=1
    elif [[ -n "$temp_file" && "$temp_file" != "$file" && -s "$temp_file" ]]; then
        mv -f "$temp_file" "$file"
        have_output=1
    fi

    if [[ "$have_output" == 0 ]]; then
        rec_notify "Recording failed" "No output file was produced"
        cleanup_temp_mic "$temp_mic"
        rec_state_edit '.screen = null'
        return 1
    fi

    cleanup_temp_mic "$temp_mic"

    if [[ -s "$file" ]]; then
        local dur size
        dur="$(rec_ffprobe_duration "$file")"
        size="$(rec_human_size "$(stat -c %s "$file" 2>/dev/null || echo 0)")"
        rec_notify "Recording saved" "$(basename "$file") · $(rec_clock "${dur:-0}") · $size"
        say "saved $file duration=${dur:-?} size=$size"
    fi

    rec_state_edit '.screen = null'
    return 0
}

configure() {
    while (( $# )); do
        case "$1" in
            --area)  rec_cfg_set screenArea "${2:-}"; shift 2 ;;
            --audio) rec_cfg_set screenAudio "${2:-}"; shift 2 ;;
            *) shift ;;
        esac
    done
}

case "${1:-toggle}" in
    start)     shift; start_recording "$@" ;;
    stop)      stop_recording ;;
    toggle)    if screen_running; then stop_recording; else start_recording; fi ;;
    configure) shift; configure "$@" ;;
    status)    screen_json ;;
    *)         say "unknown command: $1"; exit 2 ;;
esac
