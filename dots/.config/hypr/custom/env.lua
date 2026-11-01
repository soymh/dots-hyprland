-- This file will not be overwritten across dots-hyprland updates.
-- The file name is for the sake of organization and does not matter
-- See the corresponding files in ~/.config/hypr/hyprland for examples

-- fcitx5 for Wayland (wlroots/Hyprland)
-- GTK_IM_MODULE intentionally omitted: Gtk3/4 use text-input-v3 natively on Wayland
hl.env("XMODIFIERS", "@im=fcitx")
hl.env("QT_IM_MODULE", "fcitx")
hl.env("SDL_IM_MODULE", "fcitx")