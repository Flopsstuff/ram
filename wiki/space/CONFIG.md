---
# Keep this settings page out of the page tree and the page picker.
pageDecoration:
  hide: true
---
# Configuration

Settings of the ram wiki. This file comes from the infra repo (`wiki/space/`):
wiki-sync copies it into the wiki's clone on every start, so an edit made here
in the browser is overwritten by the next deploy. It is excluded from the vault
repo (`.git/info/exclude`), so agents never see it.

```space-lua
-- Open the page tree on the left on first load. Each browser then keeps its
-- own choice; "Navigate: Reset All Views" brings this default back.
config.set("view.defaults", {
  ["std.spaceTree"] = { dock = "lhs", open = true, width = 280 },
})

-- Log out: the wiki has no login of its own, Authelia's logout page ends the
-- session. Also in the command palette as "Log out".
command.define {
  name = "Log out",
  run = function()
    editor.openUrl("/sso/logout", true)
  end
}
actionButton.define {
  icon = "log-out",
  description = "Log out",
  priority = -1,   -- after the built-in buttons
  run = function()
    editor.invokeCommand("Log out")
  end
}
```
