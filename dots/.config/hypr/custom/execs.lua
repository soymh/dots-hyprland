-- This file will not be overwritten across dots-hyprland updates.
-- The file name is for the sake of organization and does not matter
-- See the corresponding files in ~/.config/hypr/hyprland for examples

-- exec-once for initial Hyprland startup
hl.exec_cmd("sleep 4 && fcitx5 -d --replace")

-- Restart portal after Hyprland env is ready so xdg-desktop-portal-hyprland
-- backend is picked up (fixes OBS/GlobalShortcuts/ScreenCast on cold login)
hl.exec_cmd("sleep 6 && systemctl --user restart xdg-desktop-portal.service")

-- Re-start on config reload (exec-once doesn't re-run on reload)
hl.on("config.reloaded", function()
    hl.exec_cmd("fcitx5 -d --replace")
end)

-- BEGIN ext:ext-selfheal (dots-hyprland-extensions; re-layers the overlay after upstream updates)
-- If the upstream ./setup install wiped the extension markers, put them back.
hl.on("hyprland.start", function()
    hl.exec_cmd("~/.config/hypr/custom/scripts/ext-selfheal.sh")
end)
-- END ext:ext-selfheal
