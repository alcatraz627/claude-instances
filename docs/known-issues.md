# Known Issues (V2)

Living list of bugs we've decided to defer rather than block on. Each entry: what's broken, what we tried, what's worth trying next.

---

## TABLE-001: Table row hover triggers subtle vertical layout shift

**Status:** open · **First seen:** 2026-05-15 · **Severity:** cosmetic

When hovering over rows in `TablePaneView`, the row's bounding box shifts a few pixels vertically. Only reproduces in the first table the user encounters (suggests interaction with the surrounding ScrollView or scroll-indicator state). Reported reproducible after the fixes below.

**Attempts that did NOT resolve it:**
1. Locked row to `.frame(height: ...)` exact (not `minHeight`).
2. Hid scroll indicators on the table's inner ScrollView (`.scrollIndicators(.hidden)`).
3. Switched hover background from view-tree swap to constant `Rectangle` with animated opacity (so the view identity stays stable across hover state changes).

All three landed in commit `692eb97`. Layout still shifts on first hover.

**Hypotheses to try next:**
- The outer dashboard ScrollView (in `DashboardSurface.scroll`) re-measures when the inner ScrollView's content size changes. Maybe make the inner ScrollView's height intrinsic so it doesn't compete.
- SwiftUI's `LazyVStack` may be lazy-instantiating rows; the first hover materializes the row's view tree which differs slightly. Try `VStack` instead — table rows are small in count.
- The chip button (`Button(...).buttonStyle(.plain)`) inside the row may have implicit `min` sizing that's content-dependent. Test by removing chips entirely.
- macOS Sequoia / Tahoe-specific SwiftUI behavior — check if it reproduces on the released SDK vs Xcode Beta.

**Workaround for users:** None. The shift is small enough to ignore for now.

---

## Decisions log

### PLUGIN-MGR-001: Per-plugin settings live in Plugin Manager detail (not Settings tab)

**Date:** 2026-05-16 · **Decided:** Option B — settings co-located with health/toggle

**The question:** should per-plugin `settings.section` UI render in the Settings tab (alongside APPEARANCE) or inside Plugin Manager's per-plugin detail view (alongside health stats)?

**Option A — Settings tab** (System-Preferences pattern):
- ✓ Familiar convention (everything user-configurable in one place)
- ✓ Easy to scan all settings at once
- ✗ Settings tab balloons with many plugins (10+ scrolling)
- ✗ Disabled plugins still show settings (or vanish, but inconsistent with "disabled = invisible" rule)
- ✗ Two places to think about one plugin (Plugin Manager for toggle/health, Settings for config)

**Option B — Plugin Manager detail** (chosen):
- ✓ One place for everything-about-a-plugin: enable, health, config, logs
- ✓ Settings tab stays focused on host-level concerns (appearance, density)
- ✓ Settings naturally scoped — only visible when a plugin is selected
- ✓ Disabled plugins naturally hide their settings (you'd toggle on first)
- ✗ Diverges from System-Preferences convention
- ✗ Users hunting for "settings" might check the Settings tab first

**Why B won:** The platform shape makes Plugin Manager the natural locus for everything-about-a-plugin. Settings tab is for the **host**; Plugin Manager is for **plugins**. The sidebar's "System" group already separates them. The fact that disabled-plugins-hide-settings comes free is a bonus alignment with platform-wide consistency.

**Where to find a plugin's settings:** Plugins → click plugin → scroll to "SETTINGS" card.

---

## Contract additions

### PLUGIN-API-001: `CLAUDE_PLUGIN_SETTINGS` env var (Phase 8.5, 2026-05-16)

Every `fetch.sh` / `actions.sh` invocation receives the plugin's current settings as a JSON object string in the `CLAUDE_PLUGIN_SETTINGS` env var. Keys match the plugin's `settings.schema.json` property names; values are JSON scalars/arrays/objects.

If the user hasn't changed a setting, the dict may be missing that key — the plugin is responsible for falling back to the schema's default (the host doesn't currently auto-inject defaults).

**Bash:**
```sh
max_events=$(echo "${CLAUDE_PLUGIN_SETTINGS}" | jq -r '.max_events // 20' 2>/dev/null || echo 20)
```

**Python:**
```python
import os, json
settings = json.loads(os.environ.get('CLAUDE_PLUGIN_SETTINGS', '{}'))
max_events = settings.get('max_events', 20)
```

The atone plugin's `fetch.sh` is the reference implementation.
