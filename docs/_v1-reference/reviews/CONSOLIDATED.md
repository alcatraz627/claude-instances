# Plugin Platform Design Review — Consolidated Report

> **Date:** 2026-05-15
> **Sources:**
> - [`architect.md`](./architect.md) — Platform Architect lens (571 lines)
> - [`performance.md`](./performance.md) — Performance Engineer lens (415 lines)
> - [`dx-migration.md`](./dx-migration.md) — DX & Migration lens (759 lines)
> **Author of consolidation:** main agent
>
> Goal of this doc: surface what the three reviewers agree on (high-signal),
> where they disagree (the decisions you actually have to make), and the
> synthesis I recommend. Individual attributions preserved; my own notes
> appear under "Main agent's take" headers.

---

## 0. Executive Summary

The three reviewers converge on a sharper picture than I had going in:

- **The v1 spec at `docs/widget-system.md` is structurally adequate for one
  surface (dashboard pane) only.** All three flag this.
- **Polling-by-default is the wrong default.** Performance quantifies the
  death curve (xbar replicates above 20 plugins); Architect agrees implicitly.
- **The ambition (multi-surface platform, bundled first-party tabs) is real,
  but the cost is bigger than I'd budgeted.** DX makes this explicit.

They diverge on **build sequencing** (refactor-first vs ship-first), on
**first-party tab migration** (must do day one vs never), on **per-surface
toggles** (obvious primitive vs UX hell), and on **how speculative deltas
like the event bus and daemon protocol are** (foundational vs defer).

My synthesized recommendation in §5: a **middle path** — ship a small but
carefully-designed kernel (manifest envelope + contribution points stubbed
but only `dashboard.pane` implemented + FSEvents-first lifecycle + Plugin
Manager UI). Don't migrate first-party tabs at all in v1; classify them
honestly as in-process Swift contributors. Defer daemon/HTTP/event-bus.

---

## 1. Where All Three Reviewers Agree (high-signal)

### 1.1 The v1 spec needs the manifest envelope changes regardless

All three independently propose roughly the same manifest shape upgrades:

| Change | Architect | Performance | DX |
|---|---|---|---|
| Plugin declares which surfaces it provides | ✓ | ✓ | ✓ |
| Manifest envelope version separate from feature version | ✓ | ✓ (delta #9 fix) | ✓ |
| Plugin declares its host-version compatibility | ✓ (`engines.claude-instances`) | ✓ (`min_host_version`) | ✓ |
| Activation-driven, not always-loaded | ✓ (VSCode `activationEvents`) | ✓ (visibility-gated) | ✓ |
| Manifest is closed-namespace (unknown keys = warning, not error) | ✓ | ✓ | ✓ |
| Per-plugin process (NOT shared extension-host) | ✓ | ✓ | (implicit) |

**Main agent's take:** these are cheap to add in v1. Skipping them means
breaking the contract later. Do them.

### 1.2 The `bash -c "$1"` example in spec §11 is a footgun

Both Architect (F9) and Performance (S1 #10) flag the worked example
shell-injecting via `bash -c "open ~/.claude/atone/rca/\"$1\".md"`. The spec
explicitly promises no shell interpolation (§10) and then promotes it as a
worked example. **Fix immediately.** Route through `actions.sh open-rca "$id"`
which the spec already supports.

### 1.3 The "installed-but-invisible = ~0 CPU" goal cannot be met by
"only fetch when visible"

The goal as written assumes a dashboard-only world. But the *expanded* plan
declares `badge`, `menubar`, `notification` surfaces — all by definition
always-visible. You cannot have a "PRs waiting: 3" badge that costs zero
CPU when invisible because it is never invisible.

The three agents propose the same fix in different words:

- **Performance:** strict surface taxonomy — `dashboard`/`floater` are
  lazy; `badge`/`menubar`/`notification` are background-active and must
  declare a `change_signal` (FSEvents, event bus, schedule). Count them
  against a global cap (default 10).
- **Architect:** `activation` events list at the manifest level; surfaces
  that need background presence opt in via `onStartup`; everything else
  activates on demand.
- **DX:** each high-cost surface is a separate opt-in checkbox per plugin
  in Plugin Manager.

**Main agent's take:** combine all three. The lazy-vs-background split is
load-bearing. Default everything to lazy; require explicit opt-in for
background-active surfaces; count them globally.

### 1.4 First-party tabs migration is harder than I thought

Architect treats it as the load-bearing test of the model ("if a first-party
tab can't be expressed as an extension, the platform is wrong").

DX treats it as a 4-day rewrite for a worse product (AllSessions
specifically).

Performance is in the middle: JSON-protocol cost is negligible at current
data sizes for *most* tabs, but Live/AllSessions might warrant in-process.

**The honest answer all three converge on:** there's a third option neither
the v1 spec nor my plan named clearly — **in-process Swift contributors that
register through the same manifest registry but skip the JSON serialization
layer**. Call them Tier 3 / `swift-bundle` plugins. Architect names this;
Performance prices it; DX accepts it as "honest" rather than "polite fiction
of unified architecture."

**Main agent's take:** if a tab is non-trivial (Live, AllSessions, Events)
it's a Tier 3 in-process contributor with a manifest entry. The
"unified-registry" wins are: (a) one sidebar source of truth, (b) one
on/off contract, (c) one error/health UI. We don't gain "the JSON
protocol expresses everything" — that was never a useful goal.

### 1.5 Plugin Manager UI is the killer feature

- **Architect** mentions it obliquely (IntelliJ Background Tasks panel).
- **Performance** demands it ("Plugin Activity inspector" — the trust
  contract).
- **DX** dedicates Phase 1 of their alternative plan to it, with a
  full mockup.

**Main agent's take:** this should be the very first non-trivial UI
landed after the kernel works. Without it, broken plugins fail silently;
with it, the platform feels professional.

### 1.6 Settings / config UI should be host-rendered from a schema

All three reference Obsidian's per-plugin settings pane as the right
model. Architect names it `settings.section` contribution point with
JSON Schema → auto-form. DX names it as the post-v1 phase 3 unlock.
Performance doesn't weigh in directly but doesn't object.

**Main agent's take:** ship this with v1. The cost is moderate (~300
lines of SwiftUI + Codable schema parser per DX). The DX win is huge.
Skipping it means every plugin author rolls their own settings UX —
exactly the "ad-hoc config" failure Architect's F7 flags.

### 1.7 FSEvents-first, polling-as-fallback

- **Performance:** explicit (S3 #1, §6.2 fetch lifecycle).
- **Architect:** implicit (`data.source: "event"` with `fallback: "fetch"`).
- **DX:** doesn't push back; v1 spec's `refresh_seconds` per pane is left
  intact in their proposal but they don't argue for it.

**Main agent's take:** this is non-negotiable. Performance is right that
script-per-tick at 50 plugins is 27% CPU; Architect's contract handles
it with the `data.source` field; DX doesn't oppose. Make `on_fs_change`
the recommended pattern in docs and the default in the scaffolding CLI.

---

## 2. Where They Disagree (decisions you need to make)

### 2.1 Build sequencing — refactor before shipping, or ship before refactoring?

| Reviewer | Position |
|---|---|
| **Architect** | "Do not ship v1 of `widget-system.md` as the durable contract." Refactor `DashboardRootView` to load from a registry BEFORE any new feature lands. Zero immediate user-visible benefit but non-negotiable foundation. |
| **DX** | "Ship v1 verbatim. Stop here for 2 weeks. Don't add features in advance." The expansion is the over-engineering trap. |
| **Performance** | Silent on sequencing; assumes you can change defaults (`refresh_seconds` → FSEvents) without a full refactor. |

This is the most consequential disagreement. **They are arguing about
different things:**

- Architect is arguing: don't freeze a bad contract.
- DX is arguing: don't build speculative features.

These aren't actually opposed. You can:

1. Define a *better* manifest envelope (Architect's win).
2. Implement *only* `dashboard.pane` contribution point + script execution
   model in v1 (DX's win — no daemon, no event bus, no badge yet).
3. The other contribution points are *stubbed in the schema* (closed
   namespace, host warns on unknown) so adding them later isn't a breaking
   change.

**Main agent's recommendation:** do (1) + (2) + (3). This is the "design
the kernel right, implement the minimum" path. Cost: ~2 days for kernel
design vs Architect's "1 day refactor"; ~no cost vs DX's "ship v1 verbatim"
because we'd have to redesign the manifest anyway when surface-2 lands.

### 2.2 First-party tabs — do they become plugins?

| Reviewer | Position |
|---|---|
| **Architect** | Yes, all of them, via Tier 3 (in-process `swift-bundle`). It's the test of the model. Section 7.2 walks Live tab through a `host-feed` data source. |
| **DX** | No, never (Phase 6: "DO NOT DO"). They're native tabs. The "unified registry" is satisfied by the sidebar grouping, not the execution model. AllSessions = 4 days for worse product. |
| **Performance** | Depends. Settings/About: JSON-protocol fine. Live/AllSessions: measure first; probably Tier 3 in-process. |

**Main agent's take:** DX is right that AllSessions migration is
demolition. Architect is right that the kernel should be capable of
hosting in-process contributors. Middle path:

- Native tabs **register through the kernel** (a manifest entry that
  points to an in-process Swift handler). The kernel knows about
  them; the sidebar lists them uniformly; the on/off contract
  works (a user can in principle disable AllSessions if they want).
- The actual *view* code stays as today's `AllSessionsTabView`. No
  JSON-protocol round-trip. No pane-schema growth to accommodate
  search-as-you-type.
- This is what Architect calls a "Tier 3 bundled extension." It's not
  a plugin in the migration-and-discovery sense; it's a contributor
  in the registry sense.

Skipping the JSON layer for these tabs means the unified-registry
abstraction is real *at the registry layer* and honest *at the
implementation layer*. Both reviewers should be satisfied.

### 2.3 Per-surface toggles — necessary or UX hell?

| Reviewer | Position |
|---|---|
| **Architect** | Implicit yes — each contribution point is independently toggleable, that's how `contributes.*` works. |
| **Performance** | Doesn't directly weigh in; recommends "per-plugin panic disable" + "all-background-surfaces-off panic kill" but not per-surface. |
| **DX** | Strongly no. CF-2 calls it UX hell with a comparison table showing **nobody successful does this**. Alternative: single per-plugin on/off + one opt-in per high-cost surface that the plugin declares. |

**Main agent's recommendation:** DX is right. The matrix is a trap. Use:

- One master toggle per plugin (enables everything the plugin declares).
- One opt-in checkbox per *background-active* surface the plugin declares
  (because those have a global cap and require explicit user consent).
- Dashboard surfaces (lazy) are auto-enabled when the plugin is enabled —
  there's no cost to them when invisible.

12 plugins × 1 toggle + maybe-2 high-cost-surface opt-ins = ~24
discoverable controls, half of which the user never touches.

### 2.4 Tier 2 (daemon) and event bus — foundational or speculative?

| Reviewer | Position |
|---|---|
| **Architect** | Foundational. §6.4 defines JSON-RPC over stdio. §6.5 defines event bus topics. The rate-limit walkthrough is the load-bearing test. |
| **Performance** | Foundational, with implementation details. Stdio JSON-RPC dominates HTTP-localhost. Pre-warm daemons in stagger. Bus events go through spawn-rate budget. |
| **DX** | Speculative. CF-6: "The migration walkthrough doesn't exercise an event-bus consumer. Defer until a plugin author asks for it." The rate-limit example doesn't need events; it polls. |

**This is real disagreement.** Architect and DX read the rate-limit case
differently. Architect sees per-second tick → can't poll → need event bus.
DX sees per-second tick → 1Hz polling on a single file is fine.

**Main agent's take:** DX wins on first-blush. The rate-limit data
already comes from the existing in-process scanner — there's nothing to
poll externally. As a Tier 3 in-process contributor, it gets the
scanner's `@Published` updates for free. No event bus required.

But Architect's deeper point holds: **once a third-party plugin wants
push semantics**, retrofitting an event bus is invasive. Better to:

- Define the event bus *contract* in the manifest schema now (closed
  namespace `event.subscriptions` field, well-known event names).
- *Don't implement* the event-publish path in v1; let it be a no-op
  until plugin #N actually asks.

This is the same "define schema, defer implementation" play as 2.1.

For Tier 2 daemons: defer entirely until a concrete plugin needs one.
Plugin authors who want a long-lived process can spawn one from
`fetch.sh` (`pgrep || start &`) and let the host treat the foreground
as their fetch. Hacky but cheap.

### 2.5 Sandbox / capability model

| Reviewer | Position |
|---|---|
| **Architect** | F3 [S1]: needs `capabilities` declarations now even if not enforced. Forward-compat hook. |
| **Performance** | Doesn't address security; focused on liveness. |
| **DX** | Sandbox absence noted but consequences not enumerated. Says "if `claude-instances` ships on Mac App Store ever, premise is invalid." |

**Main agent's take:** add `capabilities: [...]` to manifest now as
metadata. Host doesn't enforce. Capabilities are: `fs.read`, `fs.write`,
`process.spawn`, `network.local`, `network.public`, `notifications.post`,
`events.publish`, `events.subscribe`. Costs nothing today. Lets you
enforce later, or display "this plugin has network access" badges,
without breaking existing manifests.

---

## 3. Combined Critical-Flaws Table

Pulled from each reviewer's §2 with my severity calibration:

| # | Source | Title | My calibration |
|---|---|---|---|
| 1 | Arch F1 / DX CF-1 | One-plugin-equals-one-tab; bundled tabs partly fictional | **S1** |
| 2 | Arch F2 | Pull-only fetch cannot express daemon/event/streaming goals | **S1** but acceptable in v1 if those tiers are deferred |
| 3 | Arch F3 | `schema_version` is v0 versioning | **S1** — cheap to fix now |
| 4 | Arch F4 / Perf S3 #1, #2, #3 | Misbehaving plugin freezes host; render-in-order; no quota; main-thread decode | **S1** — Performance's three fatal-at-scale flaws roll up here |
| 5 | Arch F5 | Actions coupled to widgets; quick-actions impossible | **S2** — deferred with the quick-action surface |
| 6 | Arch F6 | Pane kinds in code, not contract | **S2** — solve with `kind: "custom"` escape hatch + Tier 3 |
| 7 | Arch F7 / DX CF-4 | No plugin settings story; error surface is thin | **S2** — fix with `settings.section` + Plugin Manager UI |
| 8 | DX CF-2 | Per-surface toggle matrix is UX hell | **S1** — design choice, not a bug, but it's a wrong choice |
| 9 | DX CF-3 | "5-line plugin" only holds for simplest case | **S2** — fix in docs + scaffolding CLI |
| 10 | DX CF-5 | Discovery/install/update/uninstall undefined | **S2** — explicit punt is fine if documented |
| 11 | DX CF-7 | Daemon/HTTP/swift-bundle conflated | **S2** — concrete; pick which to actually ship (recommend: only script + swift-bundle initially) |
| 12 | Perf S3 #1 | xbar's death curve replicated (script-per-tick) | **S1** — fix with FSEvents-first |
| 13 | Perf S2 #4 | 10s fetch timeout too generous | **S2** — drop to 1.5s soft / 5s hard |
| 14 | Perf S2 #7 | Resource budgets without per-plugin processes is theatre | **S2** — advertise only what you can deliver (spawn rate + wall-clock + payload-size) |
| 15 | Arch F9 / Perf S1 #10 | `bash -c "$1"` shell injection in worked example | **S2** — fix the example today |
| 16 | Arch F10 | `.disabled` file should be structured store | **S3** — defer |

---

## 4. Adjacent Systems — Synthesis

The three reviewers' system references mostly agree but emphasize
different angles. Synthesized:

| System | Architect lesson | Performance lesson | DX lesson |
|---|---|---|---|
| **VSCode** | `contributes.*` + `activationEvents` + `engines` = the 5-yr-stable model | Per-extension isolation is logical not physical; works for Node because boot is expensive | Activation events are the right primitive for "installed-but-invisible = 0 CPU" |
| **Obsidian** | `onload/onunload` lifecycle; host-rendered settings | (not addressed) | Plugin Manager UI is the killer DX feature |
| **IntelliJ** | `<extensionPoint>` + `@ApiStatus` stability annotations | Background tasks panel = trust contract | (not addressed) |
| **xbar** | Tier 1 is sufficient for 80% of users | The cautionary tale; script-per-tick dies at 20+ plugins | Spawn-stdout-JSON is the right tradeoff between xbar (too loose) and Raycast (too tight) |
| **Sketchybar** | Event-driven > timer-driven for menubar | The model to copy — events + FSEvents + slow-poll fallback | (not addressed) |
| **Hammerspoon** | A tiny 4-hook lifecycle is enough | In-process trades isolation for sub-ms speed; right tradeoff only for frame-critical | Closest analogue; copy folder=plugin, fix discoverability + settings UX |
| **Raycast** | Command-centric > view-centric (commands are the primitive) | Pre-warmed extension host enables <50ms perceived launch | Scaffolding CLI is what enables 60-second first-run |
| **Übersicht** | (not addressed) | Don't put plugin rendering in a WebView | (not addressed) |
| **Tampermonkey** | (not addressed) | (not addressed) | Manifest-as-header pattern is interesting for v2 |
| **BetterTouchTool** | (not addressed) | (not addressed) | Validates that toggle matrices are UX hell |

The **VSCode `contributes.*` + `activationEvents` + `engines.<host>` triad** is
the architectural prior art. The **xbar / Sketchybar pair** is the performance
lesson (don't do xbar, do Sketchybar). The **Obsidian Plugin Manager** is the
DX lesson.

---

## 5. Main Agent's Synthesized Recommendation

Concrete, opinionated, and ready to act on.

### 5.1 What to build (v1)

A **carefully-designed kernel with a small implementation surface**:

#### Manifest schema — full envelope, closed contribution-point namespace

```jsonc
{
  "manifest_version": 1,
  "id": "atone",
  "name": "Atone",
  "version": "0.3.0",
  "engines": { "claude-instances": "^1.0.0" },
  "icon": "exclamationmark.bubble",
  "accent": "orange",

  "activation": ["onSurface:dashboard.pane:atone-main"],
  "capabilities": ["fs.read", "process.spawn"],

  "contributes": {
    "dashboard.pane": [ /* implemented */ ],
    "commands":       [ /* implemented */ ],
    "settings.section": [ /* implemented */ ],
    "menubar.item":   [],  // schema known, host warns "not implemented yet"
    "statusbar.badge":[],  // ditto
    "event.subscriptions": []  // ditto
  },

  "exec": { /* only "script" supported in v1; "daemon"/"http"/"bundle" stubbed */ },

  "limits": {
    "fetch_timeout_ms": 1500,   // soft
    "fetch_max_per_min": 6,
    "max_payload_bytes": 262144 // 256 KB
  },

  "refresh": {
    "on_fs_change": ["~/.claude/atone/derived/_meta.json"],
    "poll_seconds": 300  // safety net only
  }
}
```

#### Implementation surface (v1)

1. **Manifest parsing + closed-namespace validation.** Unknown contribution-
   point keys = warning, not error. Unknown values in known keys = error.
2. **`dashboard.pane` contribution point** — the only one implemented.
3. **Script execution model only.** No daemon. No HTTP. No swift-bundle
   *for third-party* plugins. (First-party tabs register as in-process
   contributors via a different code path — see 5.3.)
4. **FSEvents-driven fetch.** `on_fs_change` is primary; `poll_seconds`
   is fallback. Concurrency cap (4 fetches in flight). Soft+hard
   timeouts. Spawn rate cap (6/min soft, 12/min hard).
5. **Main-thread protection.** All `Process` calls + JSON decode on
   `userInitiated` queue. `@Published` writes deduplicated on payload
   hash.
6. **Plugin Manager tab** with health/error UI (DX's Phase 1).
7. **Settings auto-rendering** from a per-plugin JSON Schema in
   `contributes.settings.section`.
8. **Scaffolding CLI** (`claude-widget new`) — DX's Phase 2.

#### Explicitly NOT in v1

- Daemon / HTTP execution models (defer until plugin #N requests).
- Event bus implementation (schema known, no-op in host).
- Badge / menubar / floater / notification / quick-action surfaces
  (schema known, host warns "not implemented yet" if plugin declares
  one).
- First-party tab migration to JSON-protocol plugins.
- Hot-reload (manual restart for v1 is fine).
- Sandbox / capability enforcement (declared, not enforced).
- Plugin discovery / install / update store. Documented punt: "drop a
  folder."

### 5.2 Why this synthesis

It's the smallest version of the platform that **doesn't lock in a bad
contract**. Three reviewers' constraints satisfied:

- **Architect:** the manifest envelope is durable; contribution points
  are reified; adding more later is additive, not breaking.
- **Performance:** FSEvents-by-default, real budgets, main-thread
  protection — the 200-plugin ceiling is reachable when the rest is
  implemented later.
- **DX:** ship v1 small and validate. No premature feature buildout.
  Plugin Manager UI and scaffolding CLI are the DX wins ON DAY ONE,
  not deferred.

### 5.3 First-party tabs — the honest classification

Today's `OverviewTabView`, `LiveTabView`, `HistoryTabView`, etc. are
**not migrated**. They are **registered through the same registry** as
in-process contributors:

```swift
// At app launch, before scanning ~/.claude/widgets/:
registry.registerBundled([
    InProcessContributor(id: "live",        view: LiveTabView.self,        section: "Dashboard"),
    InProcessContributor(id: "history",     view: HistoryTabView.self,     section: "Dashboard"),
    InProcessContributor(id: "allsessions", view: AllSessionsTabView.self, section: "Dashboard"),
    InProcessContributor(id: "settings",    view: SettingsTabView.self,    section: "System"),
    ...
])
```

The kernel's contract: "I render anything that contributes to
`dashboard.pane`." First-party tabs contribute via a Swift handler;
third-party plugins contribute via `fetch.sh` + JSON. Both end up in
the same sidebar; the user sees no difference.

This is what Architect calls a Tier 3 swift-bundle but limited to
in-host-binary (no external bundle loading, no code-signing question).
DX accepts this as honest. Performance saves the JSON round-trip cost.

### 5.4 Build sequence

1. **Day 1 (kernel design):** finalize the manifest schema (writing it
   in `docs/extension-manifest.md`). Pin the closed contribution-point
   list. Pin the closed error-code enum.
2. **Day 2-3 (registry skeleton):** `WidgetRegistry`, `Extension`,
   `ContributionPoint` Codable types. Loader + validator. Glob
   `~/.claude/widgets/*/manifest.json`. Plugin Manager tab stub.
3. **Day 4-5 (first-party migration):** wrap existing tab views as
   in-process contributors. `DashboardRootView` switches from
   `DashboardTab` enum to `registry.contributions(point: "dashboard.pane")`.
   App must behave identically — this is the silent refactor Architect
   demands.
4. **Day 6-7 (script execution):** implement `fetch.sh` invocation with
   FSEvents + budgets. Main-thread protection. Three pane kinds
   (summary, table, log) to start.
5. **Day 8 (atone plugin):** drop the atone widget. Verify it works
   end-to-end.
6. **Day 9-10 (Plugin Manager UI + scaffolding CLI):** ship the
   DX-critical surfaces.
7. **Day 11-12 (settings auto-form):** ship per-plugin settings from
   JSON Schema.
8. **Stop. Validate.** Add 1-2 more plugins (propose, weekly-todo).
   Note what's painful. Then decide which surface to add next.

Total: ~2 weeks for a real kernel + plugin manager + one working
plugin. Compare to:

- DX's "ship v1, then plugin manager UI": ~similar time, lesser kernel.
- Architect's "refactor everything before any plugin": ~3 weeks, no
  user-visible win until end.

### 5.5 Anti-priorities (what I deliberately recommend against)

- **Don't migrate AllSessions to a plugin** (DX is correct; 4 days for a
  worse product).
- **Don't ship the daemon execution model in v1** (no concrete consumer
  asking for it; rate-limit doesn't need it once it's an in-process
  contributor).
- **Don't ship per-surface toggle matrix** (DX is correct; UX hell).
- **Don't claim CPU/RSS budget enforcement** (Performance is correct;
  it's theatre on macOS without taskpolicy/setrlimit). Advertise
  spawn-rate + wall-clock + payload-size only.
- **Don't add the event bus implementation in v1** (schema yes, plumbing
  no).

---

## 6. Decisions Needed From You

These map to the §8 "open questions" from each reviewer. Numbered in
order of decision-blocking severity:

1. **Build sequence:** my §5.4 splits the difference (Architect's
   refactor + DX's small implementation). Confirm or adjust.
2. **First-party tabs:** confirm §5.3 (in-process contributors via the
   same registry, no JSON-protocol migration).
3. **Per-surface toggles:** confirm "no matrix" — single per-plugin
   toggle + per-high-cost-surface opt-in.
4. **Tier 3 / in-process bundles for third-party plugins:** **forbid**
   in v1 (only first-party bundled tabs use in-process). Confirm.
5. **Event bus:** confirm "schema yes, plumbing no" for v1.
6. **Daemon execution:** confirm deferred entirely.
7. **Scaffolding CLI scope:** ship `claude-widget new <name>` with one
   template; defer `validate`, `doctor`, `list` to v1.1.
8. **Plugin distribution / discovery:** confirm explicit punt ("drop a
   folder, document recommended plugins in a README") for v1.

---

## 7. Pointers to the Individual Reports

For deeper detail on any section above, refer to the original:

- **Architect (`architect.md`):**
  - §6.2 — full manifest schema with `contributes.*` namespace (lines 178–274)
  - §6.4 — daemon JSON-RPC protocol (lines 296–318)
  - §7.1 — rate-limit countdown walkthrough (lines 406–482)
  - §7.2 — Live tab walkthrough with `host-feed` data source (lines 484–544)
  - §8 — 10 open questions
- **Performance (`performance.md`):**
  - §4.1 — process spawn cost table + four scenarios (lines 109–131)
  - §6.3 — concrete budget numbers table (lines 249–260)
  - §6.4 — 60fps invariant concrete rules (lines 263–268)
  - §7.1, 7.2 — rate-limit + scheduled-crons walkthrough with measured costs
- **DX (`dx-migration.md`):**
  - §2 CF-1 — AllSessions migration is demolition (lines 63–101)
  - §2 CF-2 — toggle-matrix UX hell with comparison table (lines 102–129)
  - §6 — phased plan with the "DO NOT DO" tab migration (lines 407–536)
  - §7.2 — AllSessions walkthrough with cost breakdown (lines 631–684)

---

*End of consolidated report. Recommend: review §6 decisions, then I'll
update `docs/widget-system.md` to reflect the synthesized plan and
draft the manifest schema doc.*
