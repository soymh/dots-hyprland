#!/bin/bash
# GPU mode switcher: opens the y/n reboot-confirm popup.
# Called by the envycontrol quick toggle in the action center.
TARGET_DIR="$HOME/.config/hypr/custom"
exec qs -p "$TARGET_DIR/GpuConfirm.qml"
