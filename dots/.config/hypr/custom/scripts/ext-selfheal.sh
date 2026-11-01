#!/bin/bash
# Re-apply dots-hyprland-extensions if an upstream update removed the overlay.
#
# Called on Hyprland start by the `ext:ext-selfheal` block in
# ~/.config/hypr/custom/execs.lua. It is a fast no-op when the markers are
# present, so it costs nothing on normal logins.

set -uo pipefail

EXT_DIR="${DOTS_EXT_DIR:-$HOME/SoyMH/GitHub/dots-hyprland-extensions}"
QS_II="$HOME/.config/quickshell/ii"
CHOOSER="$QS_II/modules/ii/sidebarRight/quickToggles/androidStyle/AndroidToggleDelegateChooser.qml"
PANEL="$QS_II/modules/ii/sidebarRight/quickToggles/AndroidQuickPanel.qml"
KB="$HOME/.config/hypr/custom/keybinds.lua"
LOG="${XDG_CACHE_HOME:-$HOME/.cache}/qs-recorder/selfheal.log"

[[ -x "$EXT_DIR/setup" ]] || exit 0

need=0
grep -q "ext:ii-generic-fallback" "$CHOOSER" 2>/dev/null || need=1
grep -q "ext:panel-catalog" "$PANEL" 2>/dev/null || need=1
grep -q "ext:digup-keybind" "$KB" 2>/dev/null || need=1
grep -q "ext:ext-selfheal" "$HOME/.config/hypr/custom/execs.lua" 2>/dev/null || need=1

# Upstream's --delete sync also removes the two new quickshell files and can
# wipe custom-toggle installs; check those too.
[[ -f "$QS_II/modules/common/models/quickToggles/EnvyControlToggle.qml" ]] || need=1
[[ -f "$QS_II/modules/ii/sidebarRight/quickToggles/androidStyle/AndroidEnvyControlToggle.qml" ]] || need=1
[[ -f "$HOME/.config/hypr/custom/toggles/screenRecord.qml" ]] || need=1
[[ -f "$HOME/.config/hypr/custom/toggles/audioRecorder.qml" ]] || need=1
(( need == 1 )) || exit 0

mkdir -p "$(dirname "$LOG")"
if "$EXT_DIR/setup" install >> "$LOG" 2>&1; then
    notify-send -a "dots extensions" "Extensions re-applied" \
        "dots-hyprland-extensions was re-layered after an update." >/dev/null 2>&1 &
else
    notify-send -a "dots extensions" "Extensions failed to re-apply" \
        "See $LOG" >/dev/null 2>&1 &
fi

# The keybind block may have just been (re)written after Hyprland parsed its
# config, so make it live immediately.
hyprctl reload >/dev/null 2>&1 || true
