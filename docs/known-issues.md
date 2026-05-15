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
