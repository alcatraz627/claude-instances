# DashboardKit

A reusable scaffold for building floating-panel dashboards in a macOS
status-bar app. Lives inside `native/claude-instances-bar.swift` between
two banner comments:

```
// MARK: - ▼▼▼ DashboardKit — reusable scaffolding ▼▼▼ ────
...
// MARK: - ▲▲▲ End DashboardKit ▲▲▲ ────
```

**This is not a Swift package.** It's a curated set of components in one
file that's been kept generic enough that another macOS app can copy them
out and adapt to its own data. The boundary markers + this doc are the
contract.

---

## What you get

| Component | Purpose | Lines (current) |
|---|---|---|
| `DashboardController` | Manages an `NSPanel` window backed by `NSHostingView`. Open/show/close, refresh timer, focus handling. | ~80 |
| `DashboardTab` (enum) | Tabs the dashboard exposes. Conforms to `CaseIterable + Identifiable`. | ~30 |
| `SidebarButton` (View) | Sidebar nav row with icon + label + selected state. | ~40 |
| `DashboardRootView` (View) | The shell — `NavigationSplitView` with a sidebar (grouped by section) and a content area that switches on `selectedTab`. | ~100 |
| `OverviewSection<Content>` (View) | Generic section container with an icon header and a body slot. Used by every tab to wrap content blocks. | ~30 |
| `StatCard` (View) | Labeled stat box with a value, label, and optional accent color. | ~30 |
| `AggregateMetric` (View) | Bigger stat tile with a value + caption + accent. Used for top-of-tab summaries. | ~60 |
| `MetadataItem` (View) | Generic key/value pair, used inside content tabs. Lives outside the kit boundary today but is itself generic — copy it too if you need it. | ~20 |

Total: ~390 lines of SwiftUI.

## What's app-specific (don't copy)

- Tab content views: `OverviewTabView`, `LiveTabView`, `HistoryTabView`,
  `EventsTabView`, `AllSessionsTabView`, `SettingsTabView`, `AboutTabView`.
  These reference `LiveInstance`, `ScanResult`, etc. — Claude-specific
  data structures.
- `DashboardData` (`ObservableObject`) — bridges scanned Claude session
  data into SwiftUI. Replace with your own published model.
- All action callbacks (`onFocus`, `onResume`, `onOpenTranscript`, ...) —
  Ghostty / Claude-specific.
- `PaletteStore` and `PaletteToken` — the color-token system. The
  **pattern** is reusable (UserDefaults-backed, notification-on-change,
  computed-var accessors at the bar's color call sites); the **token
  list** is Claude-specific.

## Contract for the consumer

To use the kit you need to provide:

1. **An `ObservableObject` data source** for SwiftUI. Pattern:
   ```swift
   final class MyData: ObservableObject {
       @Published var foo: FooState?
       func reload() { /* fetch / replace foo */ }
   }
   ```
2. **A list of tab cases.** Replace `DashboardTab`'s cases with your own.
   Keep the protocol conformance (`String, CaseIterable, Identifiable`).
3. **Tab content views** — one `View` per tab case, picked from inside
   `DashboardRootView`'s `switch selectedTab`.
4. **Action handlers** — closures the controller passes down to leaf views.
   The kit doesn't care what they do; it just routes them.

## Minimal "Hello World" recipe

```swift
// 1. Your data
final class HelloData: ObservableObject {
    @Published var greeting = "world"
}

// 2. Your tab cases
enum HelloTab: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case about    = "About"
    var id: String { rawValue }
    var symbol: String { self == .overview ? "house" : "info.circle" }
    var section: String { "Main" }
}

// 3. Replace DashboardRootView's switch with:
switch selectedTab {
case .overview: HelloOverview(data: dataSource)
case .about:    HelloAbout()
}

// 4. Open the dashboard
let controller = DashboardController(/* point at HelloData */)
controller.show()
```

## Patterns worth understanding before copying

### NSPanel + NSHostingView

`DashboardController` creates an `NSPanel` (not `NSWindow`) so the
dashboard floats above other windows without stealing focus. The
content is an `NSHostingView` wrapping the SwiftUI `DashboardRootView`.
This is the canonical AppKit + SwiftUI bridge for menu-bar apps.

### NavigationSplitView with grouped sidebar

`DashboardRootView.sidebarSections` groups `DashboardTab.allCases` by
`tab.section` so the sidebar can render a section header before each
group (e.g., "Dashboard" / "Details" / "Help"). Replace `section`
returns to regroup; the rendering logic is generic.

### Generic `OverviewSection<Content>`

```swift
OverviewSection(title: "Stats", icon: "chart.bar", iconColor: .blue) {
    HStack { /* anything */ }
}
```

The `<Content: View>` makes it work with any SwiftUI body. We use it 12+
times across all the tab content views. **Single biggest leverage point
in the kit** — anytime you want a "section with an icon header," reach
for this instead of inventing a new container.

### Light/dark mode adapts automatically

The kit doesn't hardcode any colors that don't auto-adapt. All text uses
`.primary` / `.secondary` semantic colors. Backgrounds use
`.ultraThinMaterial`. The user's `AppearancePref` (System/Light/Dark)
just sets `NSApp.appearance` — the kit views re-render.

## Things deliberately NOT in the kit

- **No DI container.** The data source is passed in plainly. If you want
  property wrappers or factories, layer them on top.
- **No theming abstraction.** Use SwiftUI's environment + your own palette
  if you want one. Don't bring `PaletteStore` over unless you're also
  importing the Settings UI that drives it.
- **No persistence layer.** UserDefaults for prefs, your own model for
  data. The kit reads from `@ObservedObject` / `@StateObject` only.
- **No menu bar icon code.** That's the parent app's concern; the kit
  is the *window* part of a status-bar app, not the *menu* part.

## When you'd reach for something else

- **Want a single-window standalone app, not a status-bar dashboard?**
  Replace `NSPanel` with `NSWindow`. Otherwise the kit applies as-is.
- **Want to use SwiftUI's `App` lifecycle instead of AppKit's
  `NSApplicationDelegate`?** The `Controller` part of the kit is
  AppKit-flavored. Rewrite that one struct using `WindowGroup`; the
  views below are pure SwiftUI and port unchanged.
- **Want to publish the kit as a Swift package?** Extract the marked
  region into its own `.swift` file, move it under `Sources/DashboardKit/`,
  add a `Package.swift`. The content of the kit doesn't change; only
  its packaging does.

## Maintenance contract

When editing `claude-instances-bar.swift`:

- **Anything inside the kit markers stays project-agnostic.** If you
  find yourself referencing `LiveInstance` or other app-specific types
  inside the kit region, move that code out into a tab view.
- **Anything outside the kit markers is fair game** for app-specific
  references. Tab views can reference whatever they like.
- **If you add a new generic component**, put it inside the kit. If
  you add a new tab content view, put it outside.

This README is itself part of the kit contract. Update it when the
kit boundary shifts.
