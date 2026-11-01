#!/bin/bash
# Launches the DigUp semantic-search popup. Optional initial query as argv
# (used by the /digup overview action); passed via tmpfile since `qs -p`
# has no argv channel for the QML side.
if [ $# -gt 0 ]; then
    printf '%s' "$*" > "${TMPDIR:-/tmp}/digup-query"
else
    rm -f "${TMPDIR:-/tmp}/digup-query"
fi
QS_BIN="$(command -v qs || echo /usr/bin/qs)"
exec "$QS_BIN" -p ~/.config/hypr/custom/DigUpSearch.qml
