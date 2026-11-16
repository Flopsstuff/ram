---
# Keep this settings page out of the page tree and the page picker.
pageDecoration:
  hide: true
---
# Wiki style

Look of the ram wiki. Copied in from the infra repo (`wiki/space/`) on every
start; `Library/` is excluded from the vault repo.

```space-style
html {
  --ui-font: -apple-system, BlinkMacSystemFont, "Segoe UI", "Inter", "Roboto", sans-serif !important;
  --editor-font: -apple-system, BlinkMacSystemFont, "Segoe UI", "Inter", "Roboto", sans-serif !important;
  /* notes are hard-wrapped at about 100 characters; the default 800px breaks every line */
  --editor-width: 1000px;
}
/* code stays monospace */
#sb-editor .sb-code,
#sb-editor [class*="sb-line-fenced-code"],
#sb-editor .sb-frontmatter {
  font-family: "iA-Mono", "Menlo", monospace;
}
```
