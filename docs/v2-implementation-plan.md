# claude-instances V2 — Implementation Plan

> **Status:** in progress · **Date:** 2026-05-15
> **Companion:** [`v2-architecture.md`](./v2-architecture.md) — the durable contract.
>
> This is the **build sequence** for V2. The architecture doc defines what
> we're building; this doc defines what to build first and how to know each
> phase is done. Halt-points are explicit — at each one, I stop, ask, and
> wait for confirmation before the next phase.

---

## 0. Working ground rules

- **V1 remains the daily driver until V2 reaches parity.** Don't touch
  `main` branch unless explicitly asked.
- **All V2 work happens on `v2` branch** in the worktree at
  `~/.claude/widgets/claude-instances-v2/`.
- **Frequent commits** — after each phase, before each halt-point.
  Push every 2-3 commits.
- **`legacy/v1` branch** is the unchanging recovery snapshot. Never
  commit to it.
- **No destructive ops on V1.** `launchctl unload` is the only V1-side
  action we touch, and only in the final switch-over phase (12+).
- **Halt + ask** at every phase boundary. Don't proceed assuming approval.

---

## 1. Phase overview

```
   Phase  Title                              Duration  Halt after
   ─────  ─────────────────────────────────  ────────  ──────────
   0     Migration safety + docs            0.5 day   ✓ (here)
   1     Swift package skeleton              0.5 day   ✓
   2     Manifest schema + registry          1 day     ✓
   3     Surface router + pane renderers     1.5 days  ✓
   4     Native plugin protocol + 3 ports    2 days    ✓
   5     Script plugin executor + FSEvents   2 days    ✓
   6     Event bus + resource sampler        1 day     ✓
   7     Plugin Manager UI                   1.5 days  ✓
   8     Settings auto-form                  1 day     ✓
   9     Scaffolding CLI                     0.5 day   ✓
   10    First-party plugin ports (rest)     2 days    ✓
   11    Atone + scheduled + 2 more plugins  2 days    ✓
   12    Menubar/badge surfaces (delta)      2 days    ✓
   13    Parity verification + switch-over   1 day     (last halt)
```

Total estimate: ~18 days of focused work. Real calendar time depends on
how aggressively we iterate. Halt-points create natural breakpoints if
we want to pause for unrelated work.

---

## 2. Phase 0 — Migration safety + docs (now)

**Goal:** V2 has its own branch + worktree; V1 is preserved; both
architecture and implementation plan are written.

**Done when:**
- ✅ `legacy/v1` branch exists, pushed to origin
- ✅ `v2` branch exists, pushed to origin
- ✅ `v2` worktree at `/Users/alcatraz627/.claude/widgets/claude-instances-v2/`
- ✅ `docs/v2-architecture.md` written
- ✅ `docs/v2-implementation-plan.md` written (this file)
- ✅ V1 reference docs copied to `docs/_v1-reference/`
- ✅ First commit on `v2` branch
- ✅ Memory entry written for this session
- ✅ Claude Code todos created for Phase 1+

**Halt and ask:** review of the architecture doc + this plan. Any
adjustments, additions, removals?

---

## 3. Phase 1 — Swift package skeleton

**Goal:** A buildable, runnable Swift package that produces an empty
menu-bar app under bundle id `dev.claude-instances-v2.menubar`.
Identical to V1 in launch behavior, but otherwise empty.

**Files created:**
- `Package.swift` — SPM manifest
- `Sources/HostKernel/HostKernel.swift` — empty target
- `Sources/HostShell/HostShellApp.swift` — `@main` SwiftUI App with
  `MenuBarExtra`
- `Sources/HostShell/AppDelegate.swift` — NSStatusItem setup (port from V1)
- `Sources/HostShell/Info.plist` (in resources)
- `build.sh` — wraps `swift build` + bundle id stamping
- `Tests/HostKernelTests/SmokeTest.swift` — `XCTAssertTrue(true)` placeholder

**Why a Swift package and not a copy of V1's structure?** V1 is a single
`.swift` file built ad-hoc. V2 wants modules: HostKernel (no UI), HostShell
(UI + NSStatusItem), and one module per native plugin. SPM is the simplest
way to express this without an Xcode project.

**Acceptance criteria:**
- `bash build.sh` produces `claude-instances-v2.app` bundle.
- Launching it shows an icon in the menu bar.
- Quitting via the icon's "Quit" menu item works.
- V1 is still running, unaffected.

**Risks:**
- SPM doesn't natively produce `.app` bundles without help. We may need a
  small Python or shell wrapper to assemble `Contents/MacOS/`,
  `Contents/Info.plist`, etc.
- Bundle id collision is impossible (different ids); plist collision
  is impossible (different filenames). Verify before launch.

**Halt and ask:** confirm the SPM-based structure (vs single-file V1
style). If the user prefers a single-file V2, the structure changes
significantly — better to clarify now.

---

## 4. Phase 2 — Manifest schema + registry

**Goal:** Host parses `plugins/*/manifest.json`, validates against the
schema in `v2-architecture.md` §3, builds a registry of contributions.
No rendering yet.

**Files created:**
- `Sources/HostKernel/Manifest.swift` — Codable types for the manifest
- `Sources/HostKernel/ContributionPoint.swift` — closed enum + per-point
  payload types
- `Sources/HostKernel/Registry.swift` — load, validate, query
- `Sources/HostKernel/PluginError.swift` — the closed error code enum
- `Tests/HostKernelTests/ManifestTests.swift` — round-trip + validation
  tests
- `plugins/_test-fixture/manifest.json` — a hand-written manifest used
  in tests only

**Decoder strategy:**
- Top-level: standard `Codable`.
- `contributes` is a dictionary of `String → ContributionEntry[]` where
  unknown keys are collected separately (preserved + warned).
- Per-contribution-point: typed decoder per kind.
- Path tokens: `$pluginDir` expansion happens at use-time, not parse-time
  (paths can move; manifest is data).

**Acceptance criteria:**
- 10 hand-written fixture manifests parse correctly.
- 5 deliberately-broken fixtures fail with the right error codes.
- `Registry.contributions(point: "dashboard.pane")` returns expected items.
- Unknown contribution-point keys produce warnings, not errors.

**Risks:**
- Codable + heterogeneous values (contribution payloads vary by kind) is
  fiddly. Use a two-pass decode: first pass extracts `kind`, second pass
  decodes the right concrete type.
- The `engines` field needs semver parsing. Use a minimal in-house parser
  (no external dependency) — the only operations we need are
  `satisfies(range, version)`.

**Halt and ask:** review the parser's behavior on a couple of real
manifests (which I'll show as fixture JSON). Confirm semver handling.

---

## 5. Phase 3 — Surface router + pane renderers

**Goal:** Render the 5 pane kinds (summary, table, schedule, assets, log)
from hand-fed JSON. No real plugins yet; the dashboard tab takes a static
list of pane JSON blobs and renders them.

**Files created:**
- `Sources/HostShell/Surfaces/DashboardSurface.swift` — routes
  `dashboard.pane` contributions to a SwiftUI view stack
- `Sources/HostShell/Panes/SummaryPaneView.swift`
- `Sources/HostShell/Panes/TablePaneView.swift`
- `Sources/HostShell/Panes/SchedulePaneView.swift`
- `Sources/HostShell/Panes/AssetsPaneView.swift`
- `Sources/HostShell/Panes/LogPaneView.swift`
- `Sources/HostShell/Panes/ErrorPaneView.swift` — the universal error state
- `Sources/HostShell/PaletteStore.swift` — port from V1 (already token-based)

**Pane visual conventions** (carry over V1):
- Surface bg = `PaletteToken.surface`
- Each pane has a tiny ↻ icon top-right + relative "fetched 12s ago"
- Empty state renders the `empty` string in dim
- Error state shows code + actionable + disclosure for stderr

**Acceptance criteria:**
- Hand-fed JSON for each pane kind renders correctly in a test harness.
- Width responsiveness (sidebar at 200pt, content min 480pt).
- Tones (`ok` / `warn` / `error` / `dim`) all visible and palette-tokened.
- Error pane shows error code + stderr tail.

**Risks:**
- The V1 `LiveRowView` lessons apply: `NSMenuItem.view` is finicky.
  But here we're inside a normal SwiftUI window, not a menu item — much
  more forgiving.
- Long `log` pane output needs ring-buffering on the host side; otherwise
  a misbehaving plugin can pin memory.

**Halt and ask:** screenshot review of each pane kind. Adjust tones,
spacing, accent usage before locking in.

---

## 6. Phase 4 — Native plugin protocol + 3 ports

**Goal:** Define the `Plugin` Swift protocol. Port three of V1's simpler
tab views to native plugins as proof-of-concept and validation of the
protocol.

**Three pilot ports** (smallest-first):
1. **About tab** — static content, no data, no actions. Simplest.
2. **Overview tab** — StatCards + RateLimit rows over in-memory data.
   Tests reading `host.dataFeeds`.
3. **Events tab** — table view over `dataSource.events`. Tests row actions.

**Files created:**
- `Sources/HostKernel/Plugin.swift` — the protocol
- `Sources/HostKernel/HostContext.swift` — the typed services bundle
- `Sources/HostKernel/HostFeeds.swift` — read-only access to scanner data
- `plugins/about/manifest.json` + `plugins/about/Plugin.swift`
- `plugins/overview/manifest.json` + `plugins/overview/Plugin.swift`
- `plugins/events/manifest.json` + `plugins/events/Plugin.swift`
- `Sources/HostShell/BundledPluginRegistry.swift` — registers the 3
  natives at startup
- `BUILD.sh` — wraps `swift build` + plugin compilation

**Decisions to make in this phase:**
- How does a native plugin register itself? Options:
  (a) `@PluginRegister` macro (cleanest but Swift macros add build complexity)
  (b) Static `register()` call in `main.swift` (simplest, manual)
  (c) Manifest-driven: host reads `Plugin.swift`'s manifest `id`, expects
      a type named `<Id>Plugin` to exist (convention, not enforcement)
  **Recommendation:** (b) for V1 of V2. Move to (a) once stable.

**Acceptance criteria:**
- Three plugins load at startup, appear in sidebar (no Plugin Manager yet
  — sidebar is hardcoded order: About, Overview, Events).
- About renders static content.
- Overview renders StatCards using `host.dataFeeds.live` and
  `host.dataFeeds.limits`.
- Events renders rows from `host.dataFeeds.events`; row actions fire
  commands (which initially are no-ops).
- Behavior matches V1 visually.

**Risks:**
- `HostFeeds` design — what's the API? Read-once vs streaming via
  `@Published`? **Recommendation:** start with read-once + manual refresh,
  then layer `@Published` once event bus exists (Phase 6).
- Native plugins compiled into the host means the build is slower (one
  module per plugin). Acceptable if it stays under 30 s clean rebuild.

**Halt and ask:** review the three pilot ports. Did `Plugin.swift` end
up clean? Is the host API too thin / too thick? Adjust the protocol
based on real use.

---

## 7. Phase 5 — Script plugin executor + FSEvents

**Goal:** Host can execute `fetch.sh` for a script plugin's
`dashboard.pane` contribution, validate output JSON against pane schemas,
trigger fetch on FSEvents from declared `on_fs_change` paths.

**Files created:**
- `Sources/HostKernel/ScriptExec.swift` — `Process` invocation with
  timeout, payload size enforcement, spawn-rate budgeting
- `Sources/HostKernel/FSEventsWatcher.swift` — wraps macOS FSEvents API
- `Sources/HostKernel/FetchScheduler.swift` — debouncing, concurrency
  cap, queue
- `plugins/atone/manifest.json` + `plugins/atone/fetch.sh` +
  `plugins/atone/actions.sh` — the first script plugin, end-to-end
- `Tests/HostKernelTests/ScriptExecTests.swift`

**Behavior:**
- Fetch is triggered by: surface activation, FSEvents tick (debounced
  200ms), event-bus event (Phase 6), or safety-net poll.
- Each fetch runs on `userInitiated` queue. Result JSON-decoded on the
  same queue. Final `@Published` write hops to main only if payload-hash
  changed.
- Concurrency cap of 4 simultaneous fetches; queue beyond that.
- Spawn-rate budget enforced per plugin (6/min soft, 12/min hard).
- Hard-kill at 5s wall-clock.

**Acceptance criteria:**
- Atone plugin's 4 panes (summary, table, schedule, assets) render with
  real data.
- Touching `~/.claude/atone/events.jsonl` triggers a refetch within 1s.
- A deliberately-slow `fetch.sh` (e.g., `sleep 6`) gets SIGTERM'd at 1.5s
  soft, SIGKILL'd at 5s.
- A plugin that spawns 20 fetches in 60 seconds gets auto-disabled and
  surfaced as such.

**Risks:**
- FSEvents debouncing — wrong threshold causes either flicker (too short)
  or sluggishness (too long). Start at 200ms.
- macOS sometimes doesn't deliver FSEvents for sub-second changes. The
  poll-second safety net is the backstop.
- Argv passing — `$pluginDir` token expansion happens in Swift before
  `Process` argv is built. No shell.

**Halt and ask:** demo the atone plugin end-to-end. Verify the pane
contents look right (they're the first real V2 user-facing output).

---

## 8. Phase 6 — Event bus + resource sampler

**Goal:** In-process typed event bus. Host emits the standard topics.
Plugins can subscribe (native via method, script via handler script).
Resource sampler runs in the background; metrics queryable.

**Files created:**
- `Sources/HostKernel/EventBus.swift` — typed broker over NotificationCenter
- `Sources/HostKernel/EventTopics.swift` — the closed enum of
  `host.*` and `claude.*` topics
- `Sources/HostKernel/ResourceSampler.swift` — 5s tick, per-plugin
  spawn/payload/latency tracking
- `Tests/HostKernelTests/EventBusTests.swift`

**Topics emitted in V1 of V2:**
- `host.startup`, `host.shutdown`, `host.tick.minute`,
  `host.appear.dashboard`, `host.disappear.dashboard`,
  `host.surface.<surface>.activate/deactivate`
- `claude.session.start/end/idle` (when V1's scanner detects these)
- `claude.rate-limit.update` (when scan refreshes limits)

**Acceptance criteria:**
- Native plugin can subscribe to a topic in its `activate()` and receive
  events.
- Script plugin's event-handler script receives JSON on stdin and is
  invoked within debounce limits.
- Resource sampler shows realistic numbers for the atone plugin (a few
  spawns per minute, <200ms p95 latency).

**Risks:**
- Sampler measurement overhead must itself be cheap (<1% CPU). Use
  `proc_pidinfo` for self; aggregate timer-already-collected fetch
  metrics for plugins (no extra sampling).
- Cross-plugin event leakage — plugin A publishes under its prefix,
  plugin B subscribes; correct. Plugin A tries to publish under `claude.*` —
  host rejects with `events.unauthorized_publish` code.

**Halt and ask:** confirm event topic list before locking in. Adding
topics later is non-breaking; renaming is breaking.

---

## 9. Phase 7 — Plugin Manager UI

**Goal:** The introspection / control surface. List plugins, health,
toggle, drill-in.

**Files created:**
- `Sources/HostShell/PluginManagerTab.swift` — the SwiftUI tab
- `Sources/HostShell/PluginRowView.swift`
- `Sources/HostShell/PluginDetailView.swift`
- `Sources/HostShell/PluginToggleStore.swift` — persists state.json

**State persistence** (`~/Library/Application Support/dev.claude-instances-v2/state.json`):

```jsonc
{
  "plugins": {
    "atone": { "enabled": true, "surfaces": { "dashboard": true, "menubar": false } },
    "scheduled": { "enabled": true, "surfaces": { "dashboard": true } }
  }
}
```

**Acceptance criteria:**
- All registered plugins listed (native + script).
- Health badge accurate (errored plugin shows red).
- Master toggle works instantly.
- Per-surface opt-in for background-active surfaces visible (greyed for
  V1 since none are implemented yet — but the UI exists).
- "Open log", "Reveal in Finder", "Force refresh" work.
- Resource stats visible per plugin + core.
- "Panic disable all" works and persists.

**Risks:**
- Per-surface UI when the surface is stubbed — risk of confusing the user.
  Mitigation: stubbed surfaces show "(coming in vX.Y)" inline.
- Plugin removal — what does "remove" mean for a bundled native plugin?
  **Recommendation:** bundled plugins can be disabled but not removed
  from the UI. Removal requires editing source + rebuild.

**Halt and ask:** screenshot review of Plugin Manager. This is the UI
you'll look at most when V2 is misbehaving — get it right.

---

## 10. Phase 8 — Settings auto-form

**Goal:** Plugins with a `settings.section` get a host-rendered form
inside the Settings tab. Form is generated from JSON Schema.

**Files created:**
- `Sources/HostShell/SettingsTab.swift` — top-level tab
- `Sources/HostShell/SettingsSection.swift` — renders one schema
- `Sources/HostKernel/JSONSchemaForm.swift` — schema → SwiftUI form

**Form primitives supported in V1 of V2:**
- `boolean` → Toggle
- `string` → TextField
- `string` with `enum` → Picker
- `integer` / `number` → Stepper (with min/max if present)
- `string` with `format: "path"` → file picker
- `array` of above → list with add/remove

**Acceptance criteria:**
- Atone plugin gets a settings section (even if just "Disable nudges").
- Changes persist + propagate (via `claude.settings.change.<plugin-id>`
  event).

**Risks:**
- JSON Schema is huge; we support a subset. Document what's supported.
- Atomic write of state.json to prevent corruption on host crash.

**Halt and ask:** form layout review with at least 2 plugins' settings.

---

## 11. Phase 9 — Scaffolding CLI

**Goal:** `claude-widget` CLI: `new`, `validate`, `doctor`.

**Files created:**
- `scaffolding/claude-widget` — Bash wrapper (or Swift binary if it
  grows; Bash for V1)
- `scaffolding/templates/script-plugin/` — template files
- `scaffolding/templates/native-plugin/` — template files
- `Tests/scaffolding/cli-smoke.sh`

**Commands:**
- `claude-widget new <id> [--native|--script] [--dir DIR]` — prompts
  for title, accents, surfaces; produces a working plugin
- `claude-widget validate <plugin-dir>` — checks manifest schema, runs
  fetch.sh once, validates output
- `claude-widget doctor` — lists all installed plugins, missing tools,
  resource warnings (calls into the running host via a tiny IPC socket
  OR by reading state.json + invoking each plugin's `requires` check
  standalone)

**Acceptance criteria:**
- `claude-widget new test-plugin` produces a working plugin in <5s.
- `claude-widget validate plugins/atone` passes; deliberately-broken
  fixtures fail with clear messages.
- `claude-widget doctor` lists all plugins with health summary.

**Halt and ask:** confirm CLI naming, behavior, prompt UX.

---

## 12. Phase 10 — Port remaining first-party tabs

**Goal:** All V1 dashboard tabs exist as V2 native plugins.

**Order** (riskiest last):
1. **Settings tab** — already exists as a host-managed tab; just split
   the per-section settings into per-plugin `settings.section` entries.
2. **History tab** — table over `dataSource.history`. Pattern matches
   Events.
3. **Rate-limit bar** — native plugin contributing two surfaces:
   `dashboard.pane` (the Overview row) + a stub `statusbar.badge` (for
   when Phase 12 lands).
4. **Live tab** — most complex; live data, action buttons, custom row UI.
   Native plugin uses its own SwiftUI view inside the standard pane
   container.
5. **AllSessions tab** — search-sort-table. May warrant a new pane kind
   (`searchable_table`) or remain as a custom-view native plugin. DX
   review (in `_v1-reference/reviews/dx-migration.md` §7.2) recommends
   keeping it custom — i.e., the plugin's `Plugin.swift` provides a
   SwiftUI view directly, not a pane kind.

**Decision needed:** allow native plugins to ship a custom SwiftUI view
that replaces the standard pane stack? **Recommendation: yes.** A
contribution can be `view_kind: "custom"` + `view_factory: "method-name"`,
and the host calls into the plugin to get the SwiftUI view. Script
plugins cannot do this; native plugins can.

**Acceptance criteria:**
- All V1 tabs present and visually equivalent in V2.
- Performance regression <5% on the heaviest tabs (Live, AllSessions).
- Click + hover behaviors preserved.

**Halt and ask:** side-by-side V1 vs V2 comparison after each port.

---

## 13. Phase 11 — Atone + Scheduled + 2 more plugins

**Goal:** Four real script plugins ship with the binary.

**Plugins:**
1. **atone** — already done in Phase 5.
2. **scheduled** — cron + launchd unified view. Fetches via `crontab -l`
   + `~/Library/LaunchAgents/*.plist` parsing.
3. **proposals** — reads `~/.claude/proposals.jsonl`, shows open queue.
4. **memory-browser** — globs `~/.claude/memory/`, shows by type.

**Per-plugin acceptance:** plugin appears in sidebar, renders all
declared panes, actions work, no errors in Plugin Manager.

**Halt and ask:** demo each. Adjust pane layouts based on real content.

---

## 14. Phase 12 — Menubar + status-bar badge surfaces

**Goal:** Implement the menubar.item and statusbar.badge surfaces (still
stubbed at this point). Migrate the rate-limit countdown to use them.

**Files created:**
- `Sources/HostShell/Surfaces/MenubarSurface.swift` — `NSMenu` builder
  from `menubar.item` contributions
- `Sources/HostShell/Surfaces/StatusbarSurface.swift` — status-icon
  badge composition

**Rate-limit migration:** the rate-limit plugin (Phase 10 #3) gains a
`statusbar.badge` contribution sourced from a `claude.rate-limit.update`
event. Same data, two surfaces.

**Acceptance criteria:**
- atone declares a menubar.item; it appears in the dropdown.
- Rate-limit badge updates without polling (event-driven).
- Background-active surface cap enforced (try declaring 11 badges; #11
  refused with clear message).

**Halt and ask:** review the final menu-bar visual. This is the most
user-visible surface.

---

## 15. Phase 13 — Parity verification + switch-over

**Goal:** Confirm V2 reaches parity for everything you actually use.
Decide whether to retire V1.

**Verification checklist** (per V1 feature):
- [ ] Status icon visible
- [ ] Menubar dropdown lists running sessions
- [ ] Dashboard opens via shortcut
- [ ] Live tab shows current sessions
- [ ] History tab shows past
- [ ] Events tab shows recent
- [ ] All Sessions tab searchable
- [ ] Overview shows StatCards + rate-limit
- [ ] Settings persists across restarts
- [ ] No errors in Plugin Manager
- [ ] Resource usage <5% baseline CPU at idle (vs V1 baseline)

Two weeks of daily-driver use. If something is missing or worse: fix
in V2, repeat. Only switch over when **every** box is checked.

**Switch-over:**
1. `launchctl unload ~/Library/LaunchAgents/dev.claude-instances.menubar.plist`
2. Keep V1 binary on disk; can be re-loaded if needed.
3. Merge `v2` → `main`. Tag previous `main` as `v1-final`.
4. Keep `legacy/v1` branch forever as historical reference.

**Halt and ask:** final go/no-go before unloading V1.

---

## 16. Tracking + sync

Each phase has a corresponding Claude Code task (created in Phase 0).
Each phase update also goes into:
- `~/.claude/projects/-Users-alcatraz627--claude-widgets-claude-instances/memory/`
  — durable cross-session context
- `runtime-notes.md` — session-end insights (per skill convention)

This doc gets **status-updated**, not rewritten. When a phase completes,
its acceptance-criteria checkboxes get ticked here; new phases are added
at the end if scope grows.

---

## 17. Open decisions (will halt to ask, listed up front)

These I'd want answers to before the phase that touches them, not now:

| Phase | Question |
|---|---|
| 1 | SPM project vs single-file build like V1? Recommend SPM. |
| 4 | Native plugin registration via macro / static call / convention? Recommend static call. |
| 4 | `HostFeeds` API — read-once vs `@Published`? Recommend read-once first, layer `@Published` in Phase 6. |
| 6 | Final event topic names — confirm before locking. |
| 9 | `claude-widget` CLI in Bash or Swift? Recommend Bash for V1. |
| 10 | Allow native plugins to provide custom SwiftUI views (not just standard pane kinds)? Recommend yes. |
| 12 | Background-surface global cap — 10 reasonable, or higher? Configurable in any case. |
| 13 | Final switch-over criteria — strict (every checkbox) or soft (90% + my judgment)? |

---

*End of plan. Tasks for Phase 1 + setup will be created in Claude Code's
task system before this halt-point closes.*
