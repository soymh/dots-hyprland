hl.window_rule({match = {class = "^(ankipop)$"}, float = true})
hl.window_rule({match = {class = "^(ankipop)$"}, size = {900, 700}})
hl.window_rule({match = {class = "^(ankipop)$"}, center = true})

-- Re-enable blur for all windows (overrides framework no_blur rule)
hl.window_rule({ match = { class = ".*" }, no_blur = false })

-- Frosted-glass translucency for Electron apps
hl.window_rule({ match = { class = "codium" },   opacity = "0.9 0.85" })
hl.window_rule({ match = { class = "obsidian" }, opacity = "0.9 0.85" })
hl.window_rule({ match = { class = "kitty" },    opacity = "0.9 0.85" })
