# V2 Phases 5–10 — Final Review

> **Date:** 2026-05-16 · **Branch:** `v2` (commit `e26e6c3`) · **Author:** main agent
>
> This report covers everything shipped between the Phase 4 halt and now.
> Five phases (5–10) plus the design-system phase 3.5 and the ScriptExec
> timeout-detection fix.

---

## 1. What's in the bundle right now

```
~/.claude/widgets/claude-instances-v2/
├── Package.swift                  SPM workspace with 5 targets
├── Resources/Info.plist           LSUIElement bundle metadata
├── build.sh                       SPM build + .app assembly + plugin bundling
├── scaffolding/
│   └── claude-widget              CLI: new / validate / doctor
├── Sources/
│   ├── HostKernel/                runtime contract (no UI)
│   │   ├── HostKernel.swift          version = "2.0.0"
│   │   ├── Manifest.swift            Codable manifest envelope
│   │   ├── ContributionPoint.swift   10 contribution-point types
│   │   ├── Registry.swift            manifest discovery + validation
│   │   ├── SemVer.swift              caret / tilde / exact / >= ranges
│   │   ├── PluginError.swift         19 closed error codes
│   │   ├── Plugin.swift              @MainActor protocol
│   │   ├── HostContext.swift         services bundle for native plugins
│   │   ├── PaneContent.swift         5 pane payload schemas
│   │   ├── PaneSource.swift          tagged source-string parser
│   │   ├── ScriptExec.swift          Process wrapper w/ timeout enforcement
│   │   ├── FSEventsWatcher.swift     macOS CoreServices wrapper
│   │   ├── EventBusImpl.swift        NotificationCenter-backed pub/sub
│   │   ├── FileLogger.swift          per-source ring-truncated log files
│   │   ├── ResourceSampler.swift     per-plugin runtime metrics
│   │   ├── SettingsSchema.swift      minimal JSON Schema decoder
│   │   ├── HostSettings.swift        appearance + plugins + plugin_settings
│   │   └── DemoPaneData.swift        sample PaneContent for tests
│   ├── HostShell/                 macOS NSApplication shell + UI
│   │   ├── main.swift             @MainActor bootstrap
│   │   ├── AppDelegate.swift      lifecycle owner
│   │   ├── StatusBarController.swift  NSStatusItem + dropdown
│   │   ├── DashboardController.swift  NSPanel + NSHostingController
│   │   ├── DashboardRootView.swift    SwiftUI entrypoint
│   │   ├── HostSettingsStore.swift    @Published wrapper + NSApp.appearance bridge
│   │   ├── PlatformRegistry.swift     @ObservableObject — bus, sampler, loggers
│   │   ├── BundledPluginRegistry.swift native plugin instance table
│   │   ├── DesignSystem/
│   │   │   ├── DesignTokens.swift     7 token namespaces
│   │   │   └── SurfaceModifiers.swift HoverRow, paneBackground, chipBackground
│   │   ├── Panes/                  PaneRenderer + 5 pane views + ErrorPaneView
│   │   ├── Surfaces/
│   │   │   └── DashboardSurface.swift sidebar + content + PaneHolder
│   │   └── Settings/
│   │       ├── SettingsTab.swift      appearance + per-plugin sections
│   │       ├── PluginManagerTab.swift health + toggles + drill-in
│   │       └── SchemaForm.swift       JSON Schema -> SwiftUI form
│   ├── ManifestTest/              CLI smoke driver (since no XCTest)
│   ├── AboutPlugin/               native plugin (one per dir)
│   ├── OverviewPlugin/
│   └── EventsPlugin/
└── plugins/                       data side of every plugin
    ├── about/manifest.json        (Swift code lives in Sources/AboutPlugin)
    ├── overview/manifest.json
    ├── events/manifest.json
    ├── atone/{manifest.json,fetch.sh,actions.sh,settings.schema.json}
    ├── sessions/{manifest.json,fetch.sh}
    ├── scheduled/{manifest.json,fetch.sh}
    └── _test-fixtures/            17 manifest fixtures for ManifestTest
```

**Bundle on disk:** `claude-instances-v2.app/Contents/Resources/plugins/`
contains `about`, `events`, `overview`, `atone`, `sessions`, `scheduled` —
each with its manifest.json + script files where applicable.

---

## 2. Phase-by-phase summary

### Phase 5 — Script plugin executor + FSEvents + atone

```
                     ┌──────────────────────────┐
                     │  PaneHolder.refresh()    │
                     │                          │
                     │  PaneSource(spec.source) │
                     └────┬─────────────────┬───┘
                          │                 │
              ┌───────────▼──┐      ┌───────▼──────┐
              │ native:method│      │ fetch:args…  │
              └──┬───────────┘      └──┬───────────┘
                 │                     │
   ┌─────────────▼──────────┐   ┌─────▼─────────────────┐
   │ BundledPluginRegistry  │   │ ScriptExec.run(       │
   │   .instance(forId:)    │   │   executable: dir/exe │
   │   .render(method)      │   │   timeout, payload    │
   └────────────┬───────────┘   │   cap, env merge      │
                │               │ )                     │
                │               └──┬────────────────────┘
                │                  │ JSON parsed by kind
                ▼                  ▼
              ┌─────────────────────┐
              │   PaneContent       │
              └─────────────────────┘
```

- `ScriptExec`: forks Process, captures stdout to ring buffer (256 KB
  default), drains stderr to tail. Watchdog Task SIGTERMs at
  `fetch_timeout_ms` (1s grace → SIGKILL). **Detection of timeout uses
  `proc.terminationReason == .uncaughtSignal`** — not the watchdog's
  return value (that was Phase-5 follow-up bug fix).
- `FSEventsWatcher`: wraps CoreServices, 200ms debounce, main-queue dispatch,
  tilde expansion. PaneHolder installs one per visible contribution.
- Atone plugin: reads `~/.claude/atone/events.jsonl` + `derived/_meta.json`
  for real counts. Touch the file → FSEvents → re-fetch → re-render.

### Phase 6 — EventBus + FileLogger + ResourceSampler

```
            ┌─────────────────────────────────────┐
            │       PlatformRegistry              │
            │                                     │
            │  EventBus  ResourceSampler  Logger  │
            │     │            │            │     │
            └─────┼────────────┼────────────┼─────┘
                  │            │            │
         ┌────────┴──┐    ┌────┴───┐    ┌──┴────────┐
         │ publish/  │    │ record │    │ host.log  │
         │ subscribe │    │ Fetch  │    │ plugins/  │
         │           │    │        │    │  <id>.log │
         └───────────┘    └────────┘    └───────────┘
            host.startup
            host.tick.5s        every fetch -> latency,
            host.tick.minute    payload size, error
            host.appearance.change
            host.plugin.enabled/disabled
```

- `EventBus`: NotificationCenter-backed publish/subscribe. Topics namespaced
  `host.*` / `claude.*` / `<plugin-id>.*`. Monotonic seq + timestamp per event.
- `FileLogger`: per-source `<source>.log` files under
  `~/Library/Application Support/dev.claude-instances-v2/logs/`. Ring-truncated
  to 10 MB (drop oldest 20% on overflow). Async writes on a dedicated queue.
- `ResourceSampler`: per-plugin `PluginMetrics` with total fetches, errors,
  spawns-per-minute, last-100 latency window (for p50/p95), last fetch
  timestamp, last error message, last payload size.
- 5s timer bumps `samplerTick` so Plugin Manager UI re-renders live.
- 60s timer resets `spawnsLastMinute` window.

### Phase 7 — Plugin Manager UI

Sidebar gets a "Plugins" entry under System. Opens a split view: list on
the left (one row per registered plugin with status dot + last-fetch),
detail on the right (identity + contribution counts + runtime metrics +
actions).

- Status dot: green = healthy, red = errored, grey = disabled, amber = idle.
- Per-plugin master toggle persists to `state.json` under `"plugins"` key.
- Toggle off → DashboardSurface filters the plugin out of the sidebar
  (no force-quit; lazy disable).
- "Panic disable all" footer button.
- Detail "Reveal in Finder" opens the plugin source dir.
- Detail "Open log" opens `~/Library/Application Support/.../logs/plugins/<id>.log`.

### Phase 8 — Settings auto-form from JSON Schema

```
plugins/atone/settings.schema.json
            │
            │ (loaded at render time, relative to plugin dir)
            ▼
    SettingsSchema (HostKernel)
            │
            │ (rendered into Settings tab)
            ▼
       SchemaForm
            │
            │ type dispatch:
            │   boolean -> Toggle
            │   integer -> Stepper (with min/max)
            │   string  -> TextField
            │   enum    -> Picker
            ▼
   HostSettings.pluginSettings[id][key]
            │
            ▼
       state.json
```

- Minimal JSON Schema (draft 2020-12 subset): `type`, `title`, `description`,
  `default`, `enum`, `minimum`, `maximum`, optional `order` for property
  sequence.
- Atone shipped a schema with 3 properties (toggle, integer with bounds,
  string-enum) — verify in Settings → there's now an "ATONE" section
  between APPEARANCE and ABOUT with three controls.
- Values persist to `state.json` under `"plugin_settings"` key (atomic
  writes, debounced 200ms, preserves other top-level keys).
- Plugins (Phase 4+ native, Phase 5+ script) can read their own settings —
  native via HostContext, script via `CLAUDE_PLUGIN_SETTINGS` env var
  (wired up but not yet consumed by atone fetch.sh).

### Phase 9 — `claude-widget` CLI

Three subcommands shipped:

| Command | What it does |
|---|---|
| `claude-widget new <id>` | Scaffolds `plugins/<id>/` with manifest + fetch.sh + README. Idempotent guard against overwriting existing dirs. |
| `claude-widget validate <dir>` | Smoke-tests a plugin: manifest JSON parses, engines field present (warns on exact-pin), fetch.sh executable, each declared pane source actually returns the right `kind` field, settings schema parses. |
| `claude-widget doctor` | Lists every plugin with id/exec.kind/status/tool deps. Flags missing tool dependencies (jq, flock, etc.). Tails recent ERROR lines from host.log. |

Tested end-to-end: `new test-scaffold` produces a working plugin, `validate`
passes it, all 6 existing plugins also validate clean.

### Phase 10 — Sessions + Scheduled script plugins

Pragmatic subset of "port V1 tabs." Two new script plugins reading directly
from disk (no scanner port needed):

- **sessions** — Reads `~/.claude/projects/*/<uuid>.jsonl`. Shows
  total/today/week transcript counts + largest, plus a table of the 25
  most-recent sessions with project decoded from the `--`-joined directory
  name.
- **scheduled** — Walks `~/Library/LaunchAgents/*.plist` via `plutil` and
  `crontab -l`. Unified schedule pane with source pill (cron/launchd) +
  human "when" + command + enabled state (loaded vs not).

Both auto-refresh on FSEvents (`~/.claude/projects/` and
`~/Library/LaunchAgents/`).

**Deferred from this phase** (DX-review-flagged): Live tab (needs running-
process detection, not pure on-disk read) and AllSessions (search-as-you-
type SwiftUI port; "demolition not migration" per DX reviewer §7.2).

---

## 3. End-to-end demo flow

What happens when you click Atone in the sidebar:

```
1. User clicks "Atone" in sidebar
2. DashboardSurface.selection = "atone-main"
3. ContributionView iterates 2 PaneSpecs (summary, events)
4. Each spawns a PaneHolder
5. PaneHolder.task fires
6. PaneSource.init("fetch:summary") -> .fetch(args: ["summary"])
7. PaneHolder.renderFetch:
   - resolves dir = plugins/atone/, exec = ./fetch.sh
   - reads timeoutMs = 3000 from manifest.limits
   - logs "fetch start summary" to plugins/atone.log
   - awaits ScriptExec.run(...) on background queue
8. fetch.sh runs:
   - reads ~/.claude/atone/events.jsonl (95 events)
   - tallies severities, finds top slug, reads _meta.json
   - prints JSON to stdout (summary kind)
9. ScriptExec drains stdout, waitUntilExit (~100ms)
10. terminationReason = .exit -> timedOut = false
11. parseStdoutAsPane decodes by "kind" -> .summary(SummaryContent(...))
12. PaneHolder.content = PaneContent.summary(...) -> SwiftUI re-renders
13. PaneRenderer wraps in PaneFrame -> SummaryPaneView grid of tiles
14. Sampler.recordFetch(plugin: "atone", latencyMs: 102, payloadBytes: 612, error: nil)
15. Logger writes "fetch ok in 102ms (612 bytes)"
16. PluginManagerTab (if open) re-renders on next samplerTick
17. FSEventsWatcher started on events.jsonl + derived/_meta.json
18. User touches events.jsonl -> FSEvents fires after 200ms -> back to step 7
```

Every step is observable: tail `~/Library/Application Support/dev.claude-
instances-v2/logs/plugins/atone.log` to watch it live.

---

## 4. What's working (verified)

| Capability | How to verify |
|---|---|
| Six plugins discovered + rendered | Sidebar shows: Events / Overview / Sessions (Dashboard) · About (System) · Atone / Scheduled (Tools) · Plugins · Settings |
| Native plugins (3) | About / Overview / Events tabs render via Swift `render(_:)` |
| Script plugins (3) | Atone / Sessions / Scheduled render via fetch.sh stdout |
| FSEvents auto-refresh | `touch ~/.claude/atone/events.jsonl` → Atone pane updates within 200ms |
| Timeout enforcement | `sleep 6` in a fetch.sh → error pane with `fetch.timeout` code at 5s |
| Plugin Manager toggles | Toggle Atone off → it disappears from sidebar; toggle on → reappears. Survives quit. |
| Resource stats | Click any plugin in Plugins → see total fetches, p50/p95 latency, last payload size, ticks every 5s |
| Per-plugin logs | `tail -f ~/Library/Application Support/dev.claude-instances-v2/logs/plugins/atone.log` |
| Settings auto-form | Settings → ATONE section shows 3 controls; toggle persists to state.json |
| Dark/light theme | Settings → Color scheme: System/Light/Dark — flips host + plugins + chrome |
| Text-size scaling | Settings → Text size XL — every font in every pane grows |
| Density scaling | Settings → Density Spacious — gaps grow |
| Scaffolding CLI | `bash scaffolding/claude-widget new my-test` → working plugin in 1 second |
| Manifest fixtures | `swift run manifest-test` → 17/17 pass |

---

## 5. Architecture diagrams

### Sidebar composition

```
┌─────────────────────────────────┐
│ Dashboard      ← section name   │
│   • Events       ← from events plugin
│   • Overview     ← from overview plugin
│   • Sessions     ← from sessions plugin (new)
│                                 │
│ Tools                           │
│   • Atone        ← from atone plugin
│   • Scheduled    ← from scheduled plugin (new)
│                                 │
│ System                          │
│   • About        ← from about plugin
│   • Plugins      ← host UI (Plugin Manager)
│   • Settings     ← host UI
└─────────────────────────────────┘
```

Sections come from `dashboard.pane.section` in each manifest. The host
also injects a "System" group with Plugins + Settings (these are host
chrome, not plugins themselves — they manage everything else).

### State persistence layout

```
~/Library/Application Support/dev.claude-instances-v2/
├── state.json
│   {
│     "appearance":      { color_scheme, text_size, density },
│     "plugins":         { "atone": {enabled: true}, ... },
│     "plugin_settings": { "atone": {show_s3_only: false, max_events: 20, ...} }
│   }
└── logs/
    ├── host.log              host events + plugin lifecycle
    └── plugins/
        ├── atone.log         per-plugin fetch trace + errors
        ├── sessions.log
        └── scheduled.log
```

### Plugin discovery layers

```
At app launch, PlatformRegistry.bootstrap():
  1. BundledPluginRegistry.bootstrap()
       -> registers AboutPlugin(), OverviewPlugin(), EventsPlugin() instances
          by their static id
  2. PlatformRegistry.locatePluginsDir() finds the manifest dir:
       (a) Bundle.main.resourceURL/plugins/ (production .app)
       (b) ./plugins/ (development swift run)
  3. kernel.loadAll(in: pluginsDir)
       -> for each <id>/manifest.json: parse, validate envelope + engines,
          warn on unknown contribution keys, attach pluginDir
  4. Per-plugin logger created lazily on first fetch
```

Matching native plugin Swift class to JSON manifest is by **id**: the
`static var id` on the Swift class must match the `"id"` field in the
JSON manifest. The kernel doesn't know about Swift classes; the
BundledPluginRegistry doesn't know about manifests; they meet in
`PlatformRegistry.plugin(for: manifest)`.

---

## 6. What's deferred

| Item | Why | Where |
|---|---|---|
| **Live tab** (running sessions) | Needs process inspection, not on-disk; Phase 12-ish work | impl plan §12 |
| **AllSessions tab** (search-as-you-type) | DX reviewer: 4-day rewrite for worse product; recommended to keep V1's native view | reviews/dx-migration.md §7.2 |
| **Rate-limit bar** (statusbar.badge) | Surface stubbed in V1 of V2; Phase 12 implements badge | impl plan §14 |
| **Menubar.item dropdown contributions** | Same — Phase 12 | impl plan §14 |
| **Hotkey contribution dispatch** | Schema exists; surface implementation Phase 12 | impl plan §14 |
| **Tier-2 daemon execution model** | No concrete consumer yet; user-decided defer in earlier review | architecture §1 non-goals |
| **In-process Swift bundles for first-party tabs** | Would replace `Sources/<PluginName>` SPM targets — already works fine | impl plan §12 |
| **Quick-action / notification.handler / floater surfaces** | Stubbed in schema; not yet rendered | architecture §4.2 |
| **Table row hover layout shift** | Three fixes attempted, shift persists ~1px; known-issues.md TABLE-001 | docs/known-issues.md |
| **Xcode-based tests** | No Xcode on this machine; `swift test` can't find XCTest/Testing modules | impl plan Phase 1 risk note |

---

## 7. Open questions for you

1. **AllSessions tab** — DX reviewer recommended keeping V1's native impl
   forever rather than porting. Comfortable with that, or want to attempt
   a port later?
2. **Settings tab name conflict** — both Plugin Manager and the
   per-plugin settings auto-form are accessed via the sidebar. Currently
   "Plugins" and "Settings" are separate entries. Should the per-plugin
   settings sections live inside Plugin Manager's detail view instead?
3. **Should fetch.sh receive `$CLAUDE_PLUGIN_SETTINGS` JSON?** Wired the
   env var contract but atone doesn't read it. Worth ensuring before
   building more script plugins that need settings.
4. **State.json schema versioning** — currently bare JSON. Worth adding a
   `state_version` field so future host changes can migrate safely?
5. **Should `claude-widget validate` be wired into a pre-commit hook?**
   Easy to forget to validate before checking in a new plugin.

---

## 8. Suggested next phases

Per impl plan §1, remaining phases:

- **Phase 11** — More script plugins: proposals queue, memory browser,
  hooks/skills inspector. All on-disk reads, very fast to ship now that
  the platform is stable.
- **Phase 12** — Menubar + badge + hotkey surface implementations.
  Rate-limit badge migration. The user-stated original goal of "manage
  scheduled crons in the dashboard" is already partly delivered via
  Phase 10's `scheduled` plugin.
- **Phase 13** — Parity verification + V1 retirement decision.

If you want to keep the same pace, Phase 11 is the cheapest win
(3 more plugins, all script-only, each ~1 hour). Phase 12 is the
biggest visible improvement (menubar + badges = the V1 vibes).

---

## 9. Commits in this batch

```
e26e6c3  Phase 10: Sessions + Scheduled script plugins
d1f7b4f  Phase 9: claude-widget scaffolding CLI
d03a1e4  Phase 8: Settings auto-form from JSON Schema
61fe721  Phase 7: Plugin Manager UI
bf383b5  Phase 6: EventBus + FileLogger + ResourceSampler
bf76bae  ScriptExec: detect timeout via terminationReason
667ab97  Phase 5: Script plugin executor + FSEvents + atone plugin
```

7 commits, all pushed to `origin/v2`.

V1 untouched on `main` + `legacy/v1`.

---

*End of report.*
