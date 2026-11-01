#!/bin/bash
# Overview bridge (illogical-impulse dotfiles): type `/digup zebra in a video`
# in Super-overview. Args arrive split on spaces (overview splits naively);
# rejoin with spaces.
exec ~/.config/hypr/custom/scripts/digup-search.sh "$*"
