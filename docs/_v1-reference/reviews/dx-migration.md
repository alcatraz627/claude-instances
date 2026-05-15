# Plugin Platform Review — DX & Migration Lens

> **Scope:** adversarial critique of the proposed plugin platform for
> `claude-instances`, with a strong bias toward developer experience and
> the practical cost of migrating first-party tabs.
> **Author:** sub-agent (review session) · **Date:** 2026-05-15
> **Inputs read:** `docs/widget-system.md` (v1 spec, 439 lines),
> `docs/dashboard-kit.md` (171 lines), `native/claude-instances-bar.swift`
> lines 3009–4892 (DashboardKit + tab views, including the 200-line
> `AllSessionsTabView` and the `RateLimitRow` view), and
> `assets/reports/20260514-1610-atone-system-design/BUILD.md` (candidate
> first plugin).

---

# 1. Verdict

**Direction is right, ambition is roughly 2× what v1 can sustainably ship.**

The v1 spec in `widget-system.md` is excellent — focused, single-surface
(dashboard tab), declarative, with a deliberately small pane vocabulary.
That spec, if shipped as-is, would deliver "5-line bash + manifest = working
plugin" *today* for the atone use case. It is the smallest credible plugin
platform that meets the stated v1 non-goals.

The *expanded* plan layered on top (extensions/widgets split, six surfaces,
four execution models, event bus, resource budgets, per-surface toggles,
bundled-plugins-via-same-registry, hot-reload, capability declarations) is
where the design starts to over-reach. Several of those items are not
incremental polish on v1 — they are an architecture rewrite that invalidates
v1's "host is a dumb pane renderer" premise. Specifically:

- **Multi-surface** (menubar / badge / floater / quick-action / notification)
  is not orthogonal to "fetch.sh prints JSON". The menubar is an `NSMenu`,
  not a SwiftUI pane. The badge is an `NSStatusItem` title segment, not a
  pane. These need different protocols, different update cadences, different
  failure modes. Pretending they share a manifest schema sounds elegant and
  will collapse the first time someone wants per-second badge updates.
- **Daemon/HTTP execution models** break the "every fetch is a fresh
  `Process`" simplicity that makes v1 robust. Daemons need supervision,
  liveness probes, restart policy, log rotation, port allocation, IPC framing.
  That's its own ~600-line subsystem.
- **Bundled first-party tabs as plugins** is the most expensive idea in the
  whole plan and is partly a polite fiction. `AllSessionsTabView` is a
  search-sort-table-with-hover-actions over an in-process `@Published`
  model. Re-shaping it to fetch-JSON-over-`Process` is a real rewrite with
  real performance loss, not a copy-paste.

The plan is *strategically* coherent but tactically under-budgeted. The
right move is to **ship v1 verbatim**, harden it on 2–3 real third-party
plugins, then add surfaces *one at a time* with explicit per-surface
protocols rather than a unified "any-pane-anywhere" abstraction. Bundled
plugins should be a **separate, deferred decision** — possibly never.

**Confidence:** high on the v1-is-good claim, medium-high on the
expansion-is-over-reach claim, high on the AllSessions-migration-is-a-project
claim, medium on specific UX flow proposals (those depend on user taste).

---

# 2. Critical Flaws (numbered, severity)

### CF-1 — `S1` — "Bundled first-party tabs as plugins" is structurally implausible without significant data-model rewrites

`AllSessionsTabView` (line 4645) is a SwiftUI view that:
- Holds local `@State` for search text and sort order.
- Pulls from `dataSource.allSessions` — an in-process `@Published` array of
  `FullSession` Codable structs, populated by `dataSource.loadAllSessions()`
  on tab activation.
- Renders ~thousands of rows via `LazyVStack` with per-row hover state and
  inline action buttons (resume, open transcript).
- Has zero `Process` calls per render — it's all in-memory after one load.

For this to be a *plugin* under the v1 contract, the plugin would have to:
1. Provide a `fetch.sh all-sessions` that prints potentially thousands of
   rows as a single JSON document. Plausible but **slow** — the scanner
   already takes >1s to populate `allSessions` in Swift; shelling out to
   re-do that scan via JSON is strictly slower.
2. Lose search-as-you-type. Every keystroke either re-runs `fetch.sh`
   (terrible) or filters client-side over the cached JSON (fine, but now
   the "pane" needs a text input — which v1 §12 explicitly defers).
3. Lose hover-only action buttons. Pane row-actions in v1 are a single
   `row_action` chip on the right edge, not "two icons that appear on hover".
   To preserve UX, the pane schema needs hover state + multi-action rows.
4. Replace the in-process `onResume` / `onOpenTranscript` callbacks with
   `Process` invocations of `actions.sh`. Resume currently spawns a Ghostty
   tab via Swift code that already exists. Replicating that in bash means
   re-implementing window targeting in a shell script.

**Verdict:** AllSessions-as-plugin is a 2–3 day rewrite that produces a
*worse* product (slower, fewer affordances). It's not migration; it's
demolition.

The polite fiction is that "bundled plugins via the same registry" gives
the host a clean architecture. Reality: bundled plugins will need a
**privileged in-process execution model** (Tier 3 swift-bundle) that
bypasses `fetch.sh` entirely, which means the unified-registry abstraction
delivers nothing for them — they just happen to register through the same
manifest. Fine, but call it what it is: in-process tab + manifest entry,
not "plugin".

### CF-2 — `S1` — Per-surface toggles will be UX hell at scale

Plan item 6 ("Surface-level toggles") + 12 plugins × 4 surfaces each ≈
**48 toggles**. Even at 8 plugins × 3 surfaces = 24 toggles, the cognitive
load is significant. Compare:

| System | Toggle granularity |
|---|---|
| Obsidian | Per-plugin on/off. Configuration is per-plugin settings page. |
| Raycast | Per-command enabled/disabled. ~5–20 commands per extension. |
| Tampermonkey | Per-script. No surface toggles. |
| BetterTouchTool | Per-action + per-trigger. Known to be confusing; that's a stated complaint. |
| Hammerspoon | Per-Spoon load via Lua. No UI toggles at all. |

**Nobody successful does per-surface toggles.** The closest is Raycast's
per-command pattern, and Raycast commands are atomic (each command is one
thing), not "an extension that exposes the same data on 4 surfaces". The
plan's per-surface toggle is solving a problem (some users want atone in
the dashboard but not the menubar) that's better solved by:

- **Plugin author's manifest decides which surfaces to expose** (good
  defaults from the person who knows the data).
- **Single per-plugin on/off** (user's escape hatch).
- **One opt-in per high-cost surface** (menubar, notification) — gated
  by a single "Expose to menubar?" checkbox per plugin, not a matrix.

A toggle matrix is the kind of feature that *demos well* and *lives badly*.

### CF-3 — `S1` — "5-line bash + manifest = working plugin" only holds for the simplest pane

The v1 spec achieves this for `summary` + `assets`. It does **not** hold
for `table` (must produce columns + rows JSON with row-action wiring) or
`schedule` (must produce ISO timestamps for next_run, fish for launchd
metadata). The "5 lines" claim should be split:

- **Tier 0a — Tile only:** 5 lines truly works (`echo '{"kind":"summary","tiles":[...]}'`).
- **Tier 0b — Table + actions:** ~30 lines, plus the user has to grok the
  row-action → action-id wiring, plus they need `jq` competence to escape
  values from real data.
- **Tier 1 — Multi-pane plugin like atone:** ~150 lines across fetch.sh +
  actions.sh, plus the dispatch-table pattern, plus error handling.

Set the expectation correctly in docs. The current spec implies tier 0a
generality; the BUILD.md `/atone` widget is firmly tier 1.

### CF-4 — `S2` — Error surfaces are spec'd thinly; humans won't know what broke

The spec covers:
- Invalid manifest → console warning, skip (§3.3).
- Fetch timeout → "stale (fetch timed out)" + previous payload (§6).
- Non-zero exit → "error (exit N)" with stderr in disclosure (§6).
- Bad JSON → "error (bad JSON)" + first 500 chars (§6).

These are the *right defaults* but the user-facing surface is missing:

- **Where does "console warning" go?** macOS Console.app? `os_log`? stderr?
  A status-bar app with no terminal has nowhere to log to that's discoverable.
- **The disclosure for stderr** is fine for a developer; a non-developer
  user with a malformed third-party plugin will see "error (exit 2)" and
  have no idea what to do. Needs at minimum a one-click "Reveal in Finder"
  on the plugin dir and a "Copy error report" button.
- **No global plugin-health surface.** When 12 plugins are installed and
  3 are broken, the user finds out by clicking each sidebar entry.
  Obsidian, by contrast, has a Plugin Manager pane that lists all plugins
  with status badges (✓ active, ⚠ error, ⏸ disabled).

### CF-5 — `S2` — Discovery / install / update / uninstall lifecycle is undefined

The spec says "drop a folder under `~/.claude/widgets/`". That's the
install story. There is no:

- **Discovery mechanism** — how does a user find atone, propose, dream
  widgets? GitHub search? A README list?
- **Install command** — `git clone` into the right place + `chmod +x`?
  A one-liner `curl | bash`? Both have known security concerns and known
  failure modes.
- **Update path** — if the user installed via `git clone`, do they
  `git pull` each plugin manually? Is there an "update all" button?
- **Uninstall** — `trash ~/.claude/widgets/atone/`? What about plugin-owned
  state in `~/.claude/atone/` (kernel-locked!)? Plugin uninstall must NOT
  remove plugin-owned data dirs; that needs to be a documented invariant.
- **Version compatibility** — manifest `schema_version: 1` is checked, but
  what about plugin runtime deps? atone needs `jq`, `flock`, `chflags`,
  `launchctl`. If those are missing, the user gets an opaque "exit 127".

Compare:
- Raycast Store → one-click install, auto-update, sandboxed npm.
- Obsidian Community Plugins → in-app browser, auto-update toggle,
  uninstall preserves data folder by default.
- Hammerspoon Spoons → `hs.loadSpoon()` from a known URL, manual update,
  no GUI. *Most similar to current plan.* Known DX complaint: nobody
  discovers Spoons.

The plan should pick one of: (a) explicitly punt — "users install by hand,
no store, this is a power-user tool, document it" — or (b) plan a minimal
store flow. The current ambiguity is the worst of both.

### CF-6 — `S2` — Event bus + resource budgets are speculative features without a concrete consumer

Plan items 4 (event bus) and 5 (resource budgets) are listed without
articulated use cases. Adding them now bakes them into the manifest schema
and the host architecture before we know what they need to support.

**Event bus** specifically: what event types? Who emits, who consumes?
The atone plugin doesn't need events; it's pull-based. The rate-limit
bar doesn't need events; it polls. The migration walkthrough doesn't
exercise an event-bus consumer. Defer until a plugin author asks for it.

**Resource budgets** is correct in principle but hard to implement
honestly. `Process` doesn't expose easy CPU% / RSS caps on macOS without
`setrlimit` (in the child) or external supervision. The honest v1
budget is: 10s timeout (already in spec) + "don't run fetch when widget
is not visible" (already implicit). That's enough.

### CF-7 — `S3` — Daemon execution model conflates two different needs

Plan item 3 ("Execution models: script | daemon | http | swift-bundle")
treats these as parallel. They aren't:

- **script:** v1's model. Fire-and-forget `Process`. Simple.
- **daemon:** plugin owns a long-lived process. Needs supervision,
  liveness, restart, IPC, log routing.
- **http:** plugin owns a listening port. Same as daemon, plus port
  allocation, plus localhost-only enforcement.
- **swift-bundle:** in-process. Different security model, different
  failure mode (a crash takes down the host).

These deserve three separate proposals, not one schema field. Most likely
**only script + swift-bundle are actually needed**: script for everything
that fits the v1 model; swift-bundle for first-party tabs that need
in-process performance. Daemon and http can be implemented *by the
plugin author* (their `fetch.sh` can shell out to `curl localhost:N` or
`pgrep`-and-spawn) without the host knowing.

---

# 3. Limitations & Trade-offs Missed

- **No story for plugin-owned state vs. host-owned state.** atone's
  `events.jsonl` is kernel-locked; if the user uninstalls atone, what
  happens to that data? The plan doesn't say. Convention from Obsidian:
  plugin-owned dirs are never touched by the host; from Raycast:
  state is in `~/Library/Application Support/com.raycast.macos/extensions/`
  and survives uninstall by default.

- **No protocol for plugins to declare external dependencies.**
  atone needs `jq`, `flock`, `chflags`, `launchctl`. The manifest has no
  `requires: ["jq>=1.6", "flock"]` field. A plugin that depends on
  Homebrew tools should be able to declare it; the host should be able
  to render "Missing: jq. Install with `brew install jq`."

- **No story for plugin authors who DON'T write bash.** A Python or Swift
  author has to wrap their tool in a shell script. Fine for atone (bash
  is its native idiom). Not fine for a hypothetical "GitHub PRs" plugin
  that's a 200-line Python script. The spec implies `fetch.sh` must be
  bash; it should explicitly say "any executable, just print JSON to
  stdout" and update the worked example to show a Python `fetch.py`.

- **Sidebar ordering is undefined.** With 12 plugins, what's the order?
  Manifest declaration order? Filesystem alphabetical? User-customizable?
  The current spec implicitly relies on `glob` order = alphabetical,
  which means the user renames dirs to reorder. That's a Hammerspoon-tier
  UX (works, but feels wrong).

- **No story for plugin settings UI.** §12 punts "Widget settings persisted
  per-widget" to "the widget reads `config.json` itself". This means
  *every plugin author rolls their own settings UI*, or there isn't one
  and users edit JSON by hand. Obsidian's success here is non-trivial —
  having a host-rendered settings UI from a schema is a 10× DX upgrade
  over "edit the JSON".

- **Hot-reload is a footgun if file-watch isn't debounced.** The plan
  says "hot-reload" without specifying: on what events? Manifest change?
  Any file in plugin dir? An editor saving a script mid-edit will trigger
  reloads. Needs debounce + manifest-only watching.

- **No story for migration of the existing `defaultTab` UserDefault.**
  When `Live`, `History`, etc. become plugins with synthetic IDs like
  `bundled.live`, the existing `defaultTab` string in UserDefaults breaks.
  Minor, but the kind of thing that bites on day one.

- **Sandbox absence is named but consequences not enumerated.** §10 says
  "no sandbox; user runs whatever". True, but if `claude-instances` ships
  on the Mac App Store ever, this premise is invalid. If it doesn't, fine —
  but say so up front.

---

# 4. Performance Risks

1. **Spawning `Process` per pane per refresh has a fixed cost** — ~10–30ms
   per spawn on macOS just for fork+exec+stdlib init. With 5 panes ×
   30s refresh × 12 plugins = ~12 spawns/min steady state, 24 if two
   plugins are visible simultaneously. Probably fine, but mark it.

2. **JSON parsing latency on AllSessions-as-plugin** — `FullSession`
   has nontrivial fields; thousands of rows × `JSONDecoder` ≈ 50–200ms
   spike on each fetch. Today's in-process `@Published` does this once
   and re-uses. Plugin model does it every refresh.

3. **`refresh_seconds` is per-pane** but the host doesn't know if a
   pane is *cheap* (read one number) or *expensive* (scan ~/.claude tree).
   atone's `events.jsonl` scan is O(events). Without a budget signal,
   a 5s refresh on a 50k-event log is real CPU. The plan's "resource
   budgets" item should at minimum require plugins to declare expected
   fetch cost (cheap/medium/expensive) so the host can throttle
   automatically when battery-saver is on or the app is backgrounded.

4. **Hot-reload on a Mac with FSEvents** is cheap, but **re-parsing
   manifests on every change** is wasteful. Cache parsed manifests by
   `(path, mtime)`.

5. **Bundled plugins via Process** would be a strict regression. AllSessions
   loads thousands of rows in <300ms in-process today. Via `Process`
   stdout JSON, same data round-trips through JSON encode → fork → exec →
   bash → re-emit → host JSON decode. Realistic floor: ~600ms. The
   per-keystroke filter currently runs in <16ms. Plugin-model would
   either (a) re-fetch per keystroke (200ms latency, bad) or (b) cache
   client-side (fine, but requires the pane schema to support it).

---

# 5. Adjacent Systems — What They Got Right or Wrong

### Raycast extensions
**Got right:** zero-config first-run (`npm install` from template generates
working extension in <60s); strong typing via `@raycast/api`; in-app
debugger / preview; one-click publish to Store; per-command granularity.

**Got wrong:** mandates React + TypeScript + Node — high barrier for "5-line
bash" authors. Heavyweight runtime. Sandboxing tied to npm/node version.

**Lesson:** scaffolding (a `create-claude-widget` script) matters more
than the SDK. Raycast's `ray create` produces a working repo in seconds.
This plan should ship one too — a simple bash script that copies a
template under `~/.claude/widgets/<name>/`.

### Hammerspoon Spoons
**Got right:** dead-simple install model (`hs.loadSpoon("name")`); plugins
are just folders; ~zero abstraction overhead; power users adore it.

**Got wrong:** zero discoverability (Spoons exist only by word-of-mouth);
no settings UI (every Spoon documents its own Lua init incantation);
no enable/disable UI (you literally edit your init.lua).

**Lesson:** the proposed plan is closest to Spoons. Recognize this and
copy what works (folder = plugin, no central registry) while explicitly
patching the weaknesses (Spoons have no discovery; this plan should plan
for at least a curated `README.md` index in `~/.claude/widgets/_INDEX.md`).

### Tampermonkey / Greasemonkey user-scripts
**Got right:** single-file plugin (the manifest is the header comment);
metadata-driven UI (the script's `@name`, `@description` populates the
UI without a separate manifest file); per-script enable/disable.

**Got wrong:** every script can do anything (security); no protocol for
scripts to *expose* features beyond "run on a URL match"; no testing
story.

**Lesson:** the manifest-as-header pattern is interesting. For
ultra-simple plugins, a "manifest-in-script" mode (the first comment
block of fetch.sh is the manifest) would shave one file off the
minimum plugin and make "5 lines + manifest" actually feel like 5 lines.
Defer to v2.

### Obsidian community plugins
**Got right:** in-app browser with reviews, install count, README preview;
auto-update toggle per-plugin; per-plugin settings pane rendered from a
schema; clear plugin-health UI (✓/⚠/⏸ state visible at a glance).

**Got wrong:** plugins-can-do-anything security model has caused real
incidents (a popular plugin was found doing telemetry). Sandbox attempts
have been controversial.

**Lesson:** the *plugin manager UI* is the killer DX feature. Even with no
remote store, a local "Plugins" pane showing all installed widgets with
their health status, last-fetch time, recent errors, and an enable/disable
toggle is a 10× upgrade over "broken plugins fail silently in
Console.app". This should be **the first thing** added after v1 ships.

### BetterTouchTool
**Got wrong:** per-action × per-trigger × per-condition toggle matrix.
Power users tolerate it; new users bounce. Validates CF-2's concern.

### xbar plugins
**Got right:** dead-simple stdout-driven menu items (`echo "label | href=..."`);
zero schema; plugins are one file; entire ecosystem flourishes from this.

**Got wrong:** no structured data beyond text → harder to render rich UIs;
no actions beyond URL handlers.

**Lesson:** v1's "fetch.sh prints JSON" is *the right tradeoff* between
xbar (too loose) and Raycast (too tight). Don't move toward Raycast.

### VS Code extensions
**Got right:** activation events (extension only loads when needed; idle
plugins are ~0 CPU). The plan's "installed-but-invisible = ~0 CPU" goal is
exactly VS Code's activationEvents model. Steal it directly: panes don't
fetch when their widget isn't selected (already in v1 §8.3 — good).

**Got wrong:** extension API surface area sprawl. ~5k API symbols. A
warning sign for "add features as needed", not "design all surfaces up front".

---

# 6. Proposed Alternative Plan

## Phase 0 — Ship v1 verbatim. Stop here for 2 weeks.

The v1 spec in `widget-system.md` is shippable as-is. Build it. Drop the
atone plugin. Drop one more (propose or dream). Use it for 2 weeks.
Measure what's actually painful. **Do not add features in advance.**

Specifically, do not:
- Implement the multi-surface manifest (`surfaces:` array).
- Implement execution models beyond `script`.
- Implement the event bus.
- Implement resource budgets beyond the 10s timeout.
- Bundle first-party tabs as plugins.

Why: the v1 spec is internally consistent and small. Each item above
adds dependencies between subsystems. Layering them now without
validated demand is the classic over-engineering trap.

## Phase 1 — Plugin Manager UI (the missing v1.1 surface)

Add **one new tab**: "Plugins" (or fold into Settings). Inside:

```
┌─ Plugins ────────────────────────────────────────────────┐
│  Installed (4)                          [+ Add Plugin]   │
│                                                          │
│  ● Atone           Healthy · fetched 3s ago    [⚙][⏸][🗑]│
│  ● Propose         Healthy · fetched 8s ago    [⚙][⏸][🗑]│
│  ⚠ Dream           1 pane errored · 12s ago    [⚙][⏸][🗑]│
│  ⏸ Hooks           Disabled                    [⚙][▶][🗑]│
│                                                          │
│  Selected: Dream                                         │
│  ├─ Path: ~/.claude/widgets/dream/                       │
│  ├─ Errors: events pane → exit 2: jq: command not found  │
│  ├─ Required tools: jq, flock                            │
│  │  ├─ jq        MISSING — install: brew install jq      │
│  │  └─ flock     OK                                      │
│  └─ Recent fetches: [open log]                           │
└──────────────────────────────────────────────────────────┘
```

This single tab solves CF-4 (error surface), CF-5 (lifecycle UI),
and the per-plugin on/off without a toggle matrix.

The "[+ Add Plugin]" button opens a sheet with two options:
1. **Install from folder** — pick a directory; host symlinks or copies
   into `~/.claude/widgets/`.
2. **Install from Git URL** — clone into `~/.claude/widgets/<slug>/`.
   Show the README first if one exists, gated by a "Trust this plugin?"
   confirmation. This is the security boundary.

No central store, no auto-update — same model as VS Code's "install from
VSIX" path. A curated `README.md` index file in the repo can document
known-good plugins; that's the v1 "discovery" story.

## Phase 2 — Scaffolding script (the missing first-run DX)

```bash
$ claude-widget new my-plugin
✓ Created ~/.claude/widgets/my-plugin/
✓ Wrote manifest.json with one summary pane
✓ Wrote fetch.sh, made executable
✓ Wrote actions.sh, made executable
✓ Wrote README.md

Next steps:
  1. cd ~/.claude/widgets/my-plugin
  2. Edit fetch.sh — print JSON to stdout
  3. Open Claude Instances → Plugins → click "my-plugin"

Docs: https://github.com/.../widget-protocol.md
```

This is the 30-minute-developer's on-ramp. Without scaffolding, the
spec's 5-line claim is theoretical; with it, it's real.

## Phase 3 — Settings schema (the Obsidian lesson)

After 2–3 plugins exist with config needs, add a `settings:` field to the
manifest declaring a JSON Schema for plugin config. Host renders a generic
settings form per-plugin. This is a known pattern; copy the Obsidian
settings primitives (Toggle, Text, Dropdown, Number, Folder). ~300 lines
of SwiftUI plus a Codable schema parser. Punt forms-in-panes until then.

## Phase 4 — Menubar surface (only if demand is real)

Once 2+ plugin authors say "I want this in the menubar", design a
**separate protocol** for menubar contributions — NOT a unification with
panes. The menubar protocol is approximately:

```jsonc
"menubar": {
  "title_source": "menubar-title",    // fetch.sh prints "3 stale"
  "title_refresh": 30,
  "menu_items_source": "menubar-menu",// fetch.sh prints xbar-like JSON
  "menu_refresh": "on-open"           // not periodic
}
```

This is xbar-shaped, not pane-shaped. The host caches the title between
refreshes so misbehaving plugins don't freeze the menubar (CF-1's
"misbehaving plugin = stale, not host-freeze" goal).

The on/off control is a single per-plugin "Show in menubar" checkbox in
Plugin Manager, not a matrix.

## Phase 5 — Badge / floater / notification (each on demand)

Defer until a real plugin author asks. Each gets its own narrow protocol.

## Phase 6 — First-party tab "migration" — DO NOT DO

Keep `Overview / Live / History / Events / All Sessions / Settings /
About` as in-process tabs. The benefit of moving them is purely
architectural cleanliness; the cost is meaningful performance regression,
loss of features (hover actions, instant search), and ~2 weeks of work.

Instead: **document the boundary**. The kit is the shell + the
first-party tabs. Plugins live alongside them in a "Plugins" sidebar
section. The host has two kinds of content: native tabs (compiled in,
fast) and plugin tabs (dropped in, declarative). This is honest. The
"unified registry" goal is satisfied by the *sidebar*, not by the
execution model.

If a particular first-party tab feels overgrown and stale — say, Events —
that tab specifically can be re-implemented as a plugin to drive
dogfooding. But it should be a deliberate per-tab decision, not a
platform-wide migration.

## UX Flow: First-run developer experience (30-minute persona)

```
0:00  Reads README → sees "claude-widget new" command
0:01  Runs `claude-widget new next-meeting`
0:02  Opens manifest.json, sees one pane stub
0:05  Reads the manifest reference (must be linked from generated README)
0:08  Edits fetch.sh to call `icalBuddy` (or similar) and print summary JSON
0:12  Switches to Claude Instances → Plugins tab → sees "next-meeting" loaded
0:13  Sees error: "fetch.sh: line 4: icalBuddy: command not found"
0:14  Brews icalBuddy
0:16  Clicks ↻ on the pane → tile renders with next meeting
0:20  Adds a second pane (table of today's events) — fetch.sh handles
      multiple `source` args
0:25  Tests action: "Open Calendar.app"
0:30  Working plugin; commits to a personal repo.
```

**Failure mode targets:**
- Bad JSON: pane shows "Parse error" + first 200 chars of stdout, plus
  a "Copy raw output" button. *Today's spec hides this in a disclosure*;
  promote it to the primary error state.
- Missing tool: stderr scanner runs `command -v` for tokens that look
  like executables; surfaces "Missing: icalBuddy. Try: `brew install
  ical-buddy`." Heuristic, not perfect, but a huge DX win.
- Manifest invalid: don't just "skip with warning". Show the plugin in
  the Plugin Manager with a red badge and the specific JSON Schema error.

## UX Flow: 12 plugins, on/off ergonomics

Per the rejected CF-2 matrix, the alternative is:

```
Plugins tab → row per plugin → click row to expand →

  Atone                                      [Enabled] [Configure ▾]
  └─ Surfaces (1/1 active)
       ✓ Dashboard tab
       ☐ Menubar (not declared)
       ☐ Badge   (not declared)
```

If a plugin **doesn't declare** a surface, the toggle is grayed and
labeled "(not declared)". If it does, the user toggles once per plugin
per declared surface. With 12 plugins, most declare only `dashboard`;
the matrix shrinks to ~14 toggles, almost all of which the user never
touches because the defaults are right.

---

# 7. Migration Walkthrough — Honest Costs

## 7.1 `RateLimitRow` / rate-limit bar → plugin

**Current code** (lines 3520–3545 and 3696–3733):
- `RateLimits` struct decoded from `ScanResult.limits` (set by the scanner).
- `OverviewSection` wrapping two `RateLimitRow` views, each a label + pct +
  used/cap + progress bar.
- Color tiers based on `entry.pct` (>90 red, >75 orange, else green).
- `rateLimitCountdown(limits.resetsAt)` text below.

**Plugin shape:**
- `manifest.json` with one `summary` pane (4 tiles: 5h pct, 5h used/cap,
  weekly pct, weekly used/cap) and one synthetic `summary` tile for the
  countdown — OR a new pane kind `gauge` (NOT in v1).
- `fetch.sh summary` reads the same data source the scanner currently
  reads — but the scanner is in-Swift. Either:
  - (a) The scanner exposes data via a JSON file the plugin reads. Need
    to define + maintain that contract.
  - (b) The plugin re-implements the rate-limit fetch from scratch
    (which today comes from Claude's `/usage` endpoint or wherever).

**Cost:** The `summary` pane has no progress bar. The visual fidelity
of the current rate-limit row (a colored progress bar inline with the
label) requires either a new pane kind or accepting a degraded UI
(tiles with pct text only). The colored-tier-by-threshold logic moves
into the plugin (fine).

**Realistic effort:**
- 2h: extend `summary` tiles with a `progress_pct` field + a `tone`
  threshold computed in the plugin → host renders a slim bar under tiles
  with `progress_pct`. Pane schema delta is small.
- 4h: write `fetch.sh` that reads from a Swift-emitted JSON state file
  (which must be added to the scanner).
- 2h: wire the threshold UserDefault (`rateLimitWarningThreshold`)
  to the plugin via host-emitted env var.

**Total ~1 day; UX par with today's.** Tractable. The "gauge" pane
kind would be a clean v1.1 addition; without it, this plugin is rough.

**Verdict on rate-limit migration:** *worth doing* as a vehicle for
introducing a `gauge` or `progress` field to the pane schema. Forces a
real pane-design conversation. Modest effort.

## 7.2 `AllSessionsTabView` → plugin

**Current code:** lines 4645–4848 + supporting `FullSession` decode
+ `dataSource.loadAllSessions()` scanner. ~200 lines for the view,
~50 lines for the data plumbing.

**Plugin shape attempt #1 — pure v1:**
- `manifest.json` with one `table` pane.
- `fetch.sh all-sessions` invokes the scanner, prints rows JSON.
- Sort/search: client-side, BUT v1 panes don't have a TextField (§12
  defers inline forms). Punt search to v2 → degraded UX. Sort similarly:
  v1 tables have no column-header click-to-sort; user re-runs with
  different `source` arg. Worse than today.
- Hover-only action buttons: not in v1's `row_action` (single chip).
  Either lose hover behavior or extend pane schema.

**Plugin shape attempt #2 — extended pane:**
- New pane kind `searchable_table` with optional `search_placeholder`,
  optional `sort_columns: [...]`, optional `row_actions: [...]` array
  rather than single chip.
- This is a meaningful pane-schema growth.

**The data-source problem:** the scanner today runs in-process and fills
`dataSource.allSessions` once per tab activation. For the plugin, options
are:

- (a) Move the scanner *out* of Swift into a shell/Python script that
  the plugin invokes. Big rewrite (~1 day + correctness risk).
- (b) Have Swift continue to scan but write results to a JSON file the
  plugin reads. Acceptable; defines a stable IPC file.
- (c) New `swift-bundle` execution model where the plugin is in-process.
  Then it's not really a plugin in any meaningful sense.

**Realistic effort if we go option (b) + extended pane:**
- 1d: design `searchable_table` pane schema, implement host renderer.
- 1d: extract scanner output to `~/.claude/state/all-sessions.json`
  (Swift writer + plugin reader).
- 0.5d: write `fetch.sh` + `actions.sh`.
- 0.5d: deal with performance issues — JSON file is potentially big,
  loading every refresh; need a mtime guard.
- 1d: parity testing, fix the inevitable issues (date formats,
  per-row resume action, transcript opener).

**Total ~4 days for parity, and the result is strictly slower** (file
round-trip vs in-memory) and slightly more brittle (depends on the
all-sessions.json contract being stable).

**Verdict on AllSessions migration:** **don't do it.** It costs ~4 days
to ship a worse product, AND it forces pane schema growth that's only
needed because we tried to migrate AllSessions. Keep AllSessions as a
native tab. If "everything is a plugin" matters as architecture, classify
AllSessions as a `swift-bundle` plugin — manifest exists, registered
through the same sidebar, code path is in-process. Honest and cheap.

---

# 8. Open Questions Worth Asking the User

1. **Audience reality check.** Is this plugin platform aimed at
   you-the-power-user, or at a wider audience? The right answer
   changes 5–6 sections of the plan. (Hammerspoon-tier ergonomics are
   fine for power users; not fine for broader audiences.)

2. **Does "bundled plugins" carry real architectural benefit?** Or is it
   aesthetic? If the answer is aesthetic, the cost (CF-1 + §7.2) is
   probably not worth it.

3. **Is the menubar plugin extensibility actually wanted, or is the
   current menubar UX already at the ceiling?** Note that menubars in
   macOS are hard to make rich; xbar succeeded with a deliberately
   limited model. Knowing the answer here changes whether multi-surface
   is a priority or a deferral.

4. **Should the platform support plugins written in non-bash languages
   from day one?** If yes, the `fetch.sh` naming convention should
   change to `fetch` (any executable). Cheap fix early; awkward later.

5. **Where does plugin state live, and what's the uninstall guarantee?**
   This needs an answer before atone ships, because atone's data dir is
   kernel-locked and must NOT be removed by plugin uninstall.

6. **Is there appetite for a `claude-widget` CLI** (scaffolding,
   doctor, validate-manifest, list) — or is "drop a folder" the entire
   tool? Strong recommendation to ship the CLI; cheap to build, big
   DX win.

7. **What's the user's tolerance for plugins running on app launch?**
   Today the host globs and parses manifests on launch; cheap. If a
   plugin's *first fetch* runs on launch (to populate badges, say), the
   launch cost multiplies. Should plugins be lazy-by-default with an
   opt-in `eager: true` flag?

---

# 9. Confidence Notes

- **High confidence** that v1 as spec'd is shippable and meets stated v1
  goals. The spec is internally consistent and the worked atone example
  is plausible.
- **High confidence** that AllSessions migration is a project, not a
  refactor (§7.2 walks through the line-by-line costs).
- **High confidence** in CF-2 (per-surface toggle matrix is UX hell);
  the comparison table is from direct experience using each of those
  systems.
- **Medium-high confidence** in CF-1 (bundled plugins are partly
  fiction). The escape valve — calling them `swift-bundle` plugins
  honestly — is straightforward; the strong claim is just that the
  unified-process-model abstraction over them delivers little.
- **Medium confidence** on the precise Phase ordering proposed in §6.
  The phasing assumes "ship v1, then plugin manager UI" is the highest
  ROI path; other reasonable orderings exist (e.g., scaffolding script
  first to unblock external authors).
- **Lower confidence** on the specific UX flows in §6 — those are
  proposals reflecting design taste; the user may prefer different
  affordances. The principle ("Plugin Manager > toggle matrix") is the
  load-bearing claim, not the exact wireframe.
- **Did not benchmark** the Process-spawn cost (§4 #1) on this machine;
  the ~10–30ms figure is from general macOS knowledge, not measurement.
  Should be verified before any per-second refresh feature is added.
- **Did not read** the full 5,975-line `claude-instances-bar.swift` —
  spot-checked AllSessions, RateLimit row, DashboardTab enum, and the
  RateLimits Codable struct. Sufficient for the architectural claims;
  insufficient if there are surprises elsewhere (e.g., other tabs that
  are deceptively simple and *could* migrate easily, weakening the
  "don't migrate" recommendation).

---

**End of report.**
