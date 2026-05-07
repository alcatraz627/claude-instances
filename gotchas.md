# Gotchas

Developer notes on non-obvious behaviors, pitfalls, and lessons learned.
Newest entries at the bottom.

---

## 2026-05-07 — README hero must be a file, not inline `<svg>`

GitHub.com renders inline `<svg>` blocks in `README.md` correctly, so it's tempting
to paste raw SVG markup directly into the README. But almost every other markdown
renderer (Cursor/VS Code preview, terminal viewers like glow/mdcat, Claude
Desktop's reader, npm/crates.io project pages, AI assistants reading the file) strips
the SVG element and dumps the inner `<text>` nodes as plain prose — producing an
unreadable wall of words like "Claude Instances Native macOS menu bar... opus
sonnet haiku RUNNING SESSIONS opus 14t · 482 t/s..." right at the top of the page.

**Fix:** Always write SVG to a file under `assets/` and reference via
`<img src="assets/banner.svg" width="...">`. The banner and UI-preview SVGs in
this repo live at `assets/banner.svg` and `assets/preview.svg` for that reason.
Same rule applies to any future hero/diagram art added to the README.
