#!/bin/bash
# Open or reveal a DigUp search hit.
#   digup-open.sh open|reveal -- <path> <kind> <loc> [focus-line]
# loc: PDF page number or media seconds (may be empty).
mode="$1"; shift
[ "$1" = "--" ] && shift
path="$1"; kind="$2"; loc="$3"; focus="$4"

if [ "$mode" = "reveal" ]; then
    dolphin --select "$path" 2>/dev/null \
        || nautilus "$path" 2>/dev/null \
        || xdg-open "$(dirname "$path")" 2>/dev/null &
    exit 0
fi

case "$kind" in
    video|audio)
        if [ -n "$loc" ]; then
            exec mpv "--start=${loc%.*}" "$path"
        fi
        exec xdg-open "$path"
        ;;
    code)
        line="${focus:-${loc%.*}}"
        if command -v codium >/dev/null 2>&1; then
            exec codium --goto "$path${line:+:$line}"
        elif command -v code >/dev/null 2>&1; then
            exec code --goto "$path${line:+:$line}"
        elif command -v geany >/dev/null 2>&1; then
            if [ -n "$line" ]; then exec geany -l "$line" "$path"; fi
            exec geany "$path"
        fi
        exec xdg-open "$path"
        ;;
    *)
        exec xdg-open "$path"
        ;;
esac
