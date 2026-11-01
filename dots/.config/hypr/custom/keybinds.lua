hl.bind("CTRL + SUPER + A", hl.dsp.exec_cmd("kitty --class ankipop -e ~/.local/bin/ankipop.sh"),
    { description = "Anki: Popup Chinese vocab card creator" })

hl.bind("CTRL + SUPER + L", hl.dsp.exec_cmd("~/.local/bin/llm-toggle.sh"),
    { description = "LLM: Toggle llama-server on/off" })

hl.bind("SUPER + T", hl.dsp.exec_cmd("~/.config/hypr/custom/scripts/qs-task-open.sh"),
    { description = "Task: Quick add task" })

-- Whisper: start/stop whisper.cpp server (load/unload)
hl.bind("CTRL + SUPER + Semicolon", hl.dsp.exec_cmd("~/.config/hypr/custom/scripts/whisper-toggle.sh"),
    { description = "Whisper: Start/stop whisper-server" })

-- Whisper: hold SUPER+CTRL+SPACE to record live mic (press=start, release=commit)
hl.bind("CTRL + SUPER + Space", hl.dsp.exec_cmd("~/.config/hypr/custom/scripts/whisper-live.sh start"),
    { description = "Whisper: Record mic (hold)", transparent = true, ignore_mods = false })
hl.bind("CTRL + SUPER + Space", hl.dsp.exec_cmd("~/.config/hypr/custom/scripts/whisper-live.sh stop"),
    { description = "Whisper: Commit transcription (release)", transparent = true, ignore_mods = false, release = true })


-- BEGIN ext:digup-keybind (dots-hyprland-extensions; safe to re-apply, removed by uninstall)
hl.bind("CTRL + SUPER + D", hl.dsp.exec_cmd("~/.config/hypr/custom/scripts/digup-search.sh"),
    { description = "DigUp: Semantic file search" })
-- END ext:digup-keybind
