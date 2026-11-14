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
```
