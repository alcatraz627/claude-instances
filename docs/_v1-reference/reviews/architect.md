# Plugin Platform Review — `claude-instances`

> Lens: Platform Architect. Focus = kernel/surface boundary, extensibility gradient, manifest stability over 5y.
> Inputs reviewed: `docs/widget-system.md` (v1 spec), `docs/dashboard-kit.md`, `native/claude-instances-bar.swift` lines 3009–3345 (DashboardKit + DashboardTab enum + rootview switch), `assets/reports/20260514-1610-atone-system-design/BUILD.md` (atone — the stress-test plugin).

---

# 1. Verdict

**The v1 spec is a good starting point for Tier 1 (one-shot script plugin). It is the wrong shape for everything else the goals demand.** Three problems are structural, not cosmetic:

1. The manifest conflates *what the plugin is* (identity, capability) with *what the dashboard tab looks like* (panes, sidebar order). That collapses Tier 0 (declarative-only) and Tier 2 (daemon) into a shape designed only for Tier 1.
2. There is exactly one surface — "the Widgets tab sidebar entry." The stated goal lists six surfaces (dashboard, menubar, badge, floater, quick-action, notification). The current contract cannot host any other surface without a breaking redesign.
3. The execution model is `Process(fetch.sh) → JSON → done`. That contract literally cannot express: long-running daemon, event subscription, push update, partial update, streaming pane, hot config change, daemon disconnect/recovery. Bolting these on top of v1 will retroactively rewrite v1.

The atone widget *will* work under v1 as-is, but only because it happens to be a pull-shaped, cron-driven, table-of-tiles system — i.e., the most flattering possible workload. A "GitHub PR queue tile in the menubar that pings on new review request" or "rate-limit countdown that ticks every second in the menubar" cannot be expressed.

The rename "widget → extension, widget = surface type" (delta #1) is the right instinct and it is the single highest-leverage change. **Do that first.** Then most of what follows falls into place. But do not ship v1 as-is and then try to add the surface concept — it will be a v2-breaking change.

Recommendation: **do not ship v1 of `widget-system.md` as the durable contract.** Ship its mechanism (fetch-script + JSON panes) as the *implementation* of one specific surface (`dashboard.pane`) inside a broader extension manifest. Treat panes as the cheapest thing the platform can host; treat everything else as additive.

---

# 2. Critical Flaws (numbered, severity S1/S2/S3)

### F1 [S1] — One plugin = one tab. The "extension" abstraction is missing.

`widget-system.md` §1, §7 hardcodes a 1:1 mapping: one manifest folder = one sidebar entry = one widget tab. There is no concept of an extension *contributing to multiple places*. The atone manifest can render five panes in one tab — but cannot also drop a badge in the menubar, a "S3 events: 2" pill on the status icon, or a notification when a new S3 event is recorded. To do any of those under v1 you write a *second* manifest folder that fetches the same data — duplication of intent, duplication of fetch cost, duplication of failure modes. VSCode and IntelliJ both learned this lesson early and never went back. Your delta #2 acknowledges the problem; the v1 spec doesn't reflect the fix.

### F2 [S1] — Pull-only fetch model cannot express the goals.

§6 defines fetch as `Process(fetch.sh)` returning a single JSON document with a 10s timeout. Implications:

- **No push.** A rate-limit countdown that needs to update every second has to be polled every second, spawning a process every second per user-visible surface. Even at 1s tick × 6 surfaces × N plugins this is catastrophic for menubar idle CPU.
- **No streaming.** §4.5 says `log` pane is "no fetch" — but that means action stdout is treated specially as a one-shot, not as a real stream. Tailing `_consolidate.log` requires re-fetching it on a timer.
- **No event hooks.** The atone BUILD.md §1 architecture diagram shows `hinters` firing on prompt-submit events — there is no mechanism for an extension to subscribe to events from the host. Your delta #4 acknowledges this; the v1 spec does not have the surface area to host it.
- **Single-shot ⇒ no daemon.** Tier 2 of the stated gradient (long-running daemon) literally has no place to attach.

### F3 [S1] — No capability model means no forward-compat story.

§3.1 has `schema_version: 1` (a global integer). §9 says "host's max known schema_version is hardcoded in `WidgetRegistry`. Newer manifests are skipped." That's a v0 versioning model, not v1. The result over 5 years:

- Every new pane kind, every new field, every new affordance bumps the global version. A plugin written for `schema_version: 1` will be silently skipped by a host that ships `schema_version: 2` if you ever decide "newer manifests skipped" is wrong (you will).
- You can never deprecate a pane kind without breaking every plugin that uses it.
- There's no way for a plugin to say "I need `events` capability" or "I work on host ≥1.3, ≤2.0." So either the host adds a capability registry later (breaking the manifest), or plugin authors learn to write conditional manifests with comments. Both are bad.

The correct model is what VSCode/IntelliJ/Obsidian all converged on: **per-feature capability declarations** + **engines range** + **per-contribution point version**. Delta #10 hand-waves this; needs to be in v1 or you'll regret it.

### F4 [S1] — A misbehaving plugin can freeze the host. The "panic disable" goal is not achievable with this design.

§6: 10s fetch timeout, killed with SIGTERM then SIGKILL after 5s. Good. But:

- §6 says "panes fetched **in parallel** but rendered in manifest order." If pane 1 returns in 50ms and pane 2 hangs for 10s, the user waits 10s to see *any* update. Render-in-order is the wrong default; render-as-arrives is.
- §7: refresh timer runs while widget is visible. There's no per-plugin or per-pane budget for *aggregate* CPU. A pane with `refresh_seconds: 1` is allowed, will spawn a process every second forever while visible. No `max_per_min` clamp.
- No `Process` quota. If a plugin shell-forks 50 children inside `fetch.sh`, the host can't see it. If the fetch script forks a daemon that survives SIGKILL of the parent, you've leaked.
- §10 "this is a single-user local tool, there is no sandbox" — fine, but you still need *liveness* protection from a buggy first-party plugin, not malice protection. Delta #5 says "resource budgets per plugin, enforced" — that's a v1 requirement per the goals, not a future delta.

### F5 [S2] — Actions are coupled to widgets; quick-actions surface is impossible.

§5 defines actions as belonging to a widget, run with `cwd = widget dir`, output streaming to *that widget's* transient log pane. The stated goal includes "quick-action" as a surface — i.e., menubar-level "Run consolidate now" without first navigating to the atone tab. The current contract can't express that: an action has no surface, only a host (the widget tab). To put `consolidate` in the menubar you'd duplicate it.

This is fixable by reifying actions as first-class plugin contributions (like VSCode commands), not as children of panes.

### F6 [S2] — Pane kinds are fixed in code, not the contract.

§4 names five kinds and §9 says new kinds bump schema_version. That means every plugin author has to wait for a host release to render a new visual primitive. Compare to VSCode webviews: you ship HTML/CSS/JS and the host doesn't care. The right v1 answer is: **freeze the five pane kinds as the well-known set**, but allow `kind: "custom"` with a renderer the plugin specifies (e.g., a path to a SwiftUI view in a swift-bundle, or — for script plugins — a fallback declarative description that degrades to a `table` or `log`). Without that escape hatch, the platform either ossifies or fragments into per-kind PRs.

### F7 [S2] — No plugin settings story.

§12 explicitly says "if a widget needs config, it reads `~/.claude/widgets/<id>/config.json` itself." This works for engineer-authored plugins. It does not work for "I want a UI toggle on the Settings tab to choose between `Today only` and `Last 7 days`." Three years from now every plugin will have ad-hoc config and the user has no central place to edit them. VSCode learned this in the first 6 months — `package.json` `contributes.configuration` was added precisely because of it.

### F8 [S2] — Hot-reload (delta #9) needs a contract for "is this plugin currently running anything?"

Daemon plugins, long-fetch plugins, in-flight actions — hot-reload of the manifest cannot just blow them away. v1's "every fetch is a fresh `Process`" simplification (§8 "the widget process tree never persists between selections") is true today and false the moment you ship Tier 2. The hot-reload contract has to be defined *with* the execution model, not bolted on after.

### F9 [S3] — `cmd: ["bash", "-c", "open ~/.claude/atone/rca/\"$1\".md"]` in §11.

The worked example reintroduces shell interpolation through the back door. `$1` from `row_action.args` will be substituted by bash before `open` sees it. If a row's id contains a backtick or `$()`, you have a shell injection in a first-party plugin. This is a single-user tool so it's not a security S1, but it is a footgun the spec promotes as a worked example. Either: (a) ban `bash -c` in `cmd` and route through `actions.sh <id> <args>` (which the spec already supports!), or (b) document that `cmd` arrays containing `-c` are user-trusted to escape correctly. The spec currently does neither.

### F10 [S3] — `~/.claude/widgets/.disabled` is a newline file, not a structured store.

§2: `.disabled` is "newline-separated list of widget IDs to hide without deleting." Fine for v1, but as soon as you add per-surface toggles (delta #6), per-plugin settings (F7), and per-plugin resource overrides, you need a real store. Pick its shape now (`~/.claude/widgets/_state.json` or per-plugin `~/.claude/widgets/<id>/.state.json`) — adding it later means migrating user state.

---

# 3. Limitations & Trade-offs Missed

- **No inter-plugin protocol.** §12 deliberately excludes "cross-widget communication." Reasonable in v1, but you'll want it: a "git PR queue" plugin and a "github notification" plugin sharing an auth token is a real example. Pick the eventual shape now (a host-mediated event bus on a published topic, NOT direct peer reads).
- **No lifecycle hooks.** Plugins can't run an `onInstall`, `onUpgrade`, `onDisable` step. The atone widget needs cron jobs installed; today the user does this by hand. A `cmd: install` / `cmd: uninstall` contract closes that.
- **No multi-payload panes.** A `table` of 10,000 rows is a single JSON document. There is no pagination, no incremental fetch, no virtualization handshake. v1 should at least leave room (`"truncated_at": 100, "has_more": true`).
- **No "data-source" abstraction.** Multiple plugins might want to read the same scan data the host already computes (`d.history`, `d.live`). Today they'd each shell out and re-scan. A host-provided data feed (read-only, host computes once, plugins subscribe) is missing — important because today's first-party tabs *rely on* `DashboardData`.
- **Locale, timezone, formatting.** Each plugin will format dates and bytes differently. Worth shipping a small helper bundle or formatting contract early.
- **No icon/asset resolution.** `icon: "exclamationmark.bubble"` is hardcoded SF Symbol; what about custom asset images? PNGs? animated badges? Decide now or you'll fork the contract.
- **Internationalization.** Not a problem for solo use, but if ever shared, plugin `title`/`subtitle` will be hardcoded English. Trivial to leave room (`title_l10n: {"en": "...", "ja": "..."}`).
- **Action confirmation UX.** §5 `confirm` is just a string. No way to say "destructive AND require typing the action name" (the GitHub-style guard). Sometimes you want it.

---

# 4. Performance Risks

1. **Process-spawn storm.** Polling N panes across M plugins every R seconds, even when idle, is a per-spawn macOS overhead (~5–15ms each). 5 plugins × 3 panes × 30s = 30/min idle; harmless. 20 plugins × 5 panes × 10s = 600/min = 10/s sustained — visible in Activity Monitor. v1 has zero shared throttle.

2. **Render-in-order blocking.** F4 above. 60fps requires the host to never block on plugin output; today the contract assumes pane-by-pane sequential render. Fix: render each pane as its fetch resolves; placeholder shimmer until then.

3. **Memory leak via long stdout.** Action streams to a transient log pane (§5). No cap on size. A plugin that prints a 500MB log on action run will OOM the dashboard. Need a ring buffer cap (e.g., 1MB or 10k lines), with "view full log" opening the file.

4. **No `whenVisible` / `whenFocused` execution gating.** Goal says "installed-but-not-visible plugin = ~0 CPU." v1 partly delivers (timers only run when widget selected) but the manifest itself is parsed on launch even for disabled plugins, and there is no surface concept of "this plugin's badge polls always; its pane polls only when visible." VSCode `activationEvents` is the prior art.

5. **Daemon plugin (Tier 2) will leak.** Without a defined daemon protocol, plugin authors who want one will fork-daemonize from `fetch.sh`. There's no host knowledge of those processes, no kill on dashboard quit, no restart on crash, no health probe. This is the single biggest performance footgun once Tier 2 lands.

6. **JSON parse cost on large payloads.** `table` payload with 50k rows is parsed every refresh. Recommend `Decodable` with `String → ArraySlice` lazy decode for tables, or enforce a server-side row cap.

7. **PaletteStore on the hot path.** Every pane re-render today reads palette tokens. With plugin-driven re-renders happening per pane fetch, contention on `UserDefaults` reads could matter. Cache palette resolution in `DashboardData` and publish changes via notification (already largely done per dashboard-kit.md, just confirm).

---

# 5. Adjacent Systems — What They Got Right or Wrong

### VSCode extensions — the strongest model to copy

The right things to steal:

- **`package.json` `contributes.*`** — extensions declare contribution points (`commands`, `views`, `viewsContainers`, `menus`, `configuration`, `statusBarItems`). Every surface is a contribution point. Adding a new surface = new contribution point name; old extensions don't break. **This is the answer to F1.**
- **`activationEvents`** — extension is dormant until an event fires (`onCommand:foo.bar`, `onView:myView`, `onLanguage:python`, `*`). Zero CPU until needed. **This is the answer to "installed-but-not-visible = ~0 CPU."**
- **`engines.vscode: "^1.74.0"`** — semver range against host. **Answer to F3.**
- **API proposals are stamped** — `enabledApiProposals` lets new APIs ship behind opt-in. Plugins can't accidentally depend on unstable surfaces. Worth copying.
- **Webviews as the universal escape hatch** — when contribution points aren't expressive enough, ship a webview. The host doesn't render your custom thing; you do, inside a sandboxed iframe.

What they got wrong (avoid):
- Extension manifest is unbounded JSON. Discoverability suffers. **Solution: keep the `contributes.*` namespace closed, well-known, documented in one place.**
- Settings UI is auto-generated from JSON Schema → ugly. **Better solution: let plugins ship a SwiftUI settings view OR fall back to schema-generated.**
- Two activation models (`activationEvents` + new `*activationEvents` in package.json metadata) — historical baggage. Pick one.

### Obsidian plugins — the "single-user, trust-the-author" model

The right things to steal:
- **Plain JS, no sandbox.** Mirrors your "single-user local tool, no sandbox" §10. The freedom is what makes Obsidian's ecosystem prolific.
- **`onload` / `onunload` lifecycle hooks** on a `Plugin` class. Symmetric, clean.
- **Hot reload is first-class.** Devs iterate without restart.
- **Per-plugin settings persisted by core API** (`loadData()` / `saveData()`) — solves F7. Plugin doesn't roll its own.

What they got wrong:
- Plugin can do anything in the renderer process, including hang it. Same risk as yours. They mitigate with community vetting only.
- The plugin API surface ballooned because there were no contribution points — every plugin author calls deep into Obsidian internals. **Lesson: define contribution points BEFORE you ship; don't expose your internals.**

### IntelliJ Platform — the "extension points" model

The right things to steal:
- **`<extensionPoint>` and `<extension>`** in plugin XML. Same idea as VSCode `contributes.*`. The host declares EPs; plugins bind to them by name. New EPs = new capabilities; old plugins unaffected.
- **`@ApiStatus.Experimental` / `@ApiStatus.Internal`** — explicit API stability annotations. **Answer to "5-year version stability": you can't promise stability without marking what's stable.**
- **Plugin dependencies** — a plugin can declare `<depends>` on another plugin. Enables composition.

What they got wrong:
- XML manifest is verbose. Use JSON.
- Plugin code runs in-process and CAN crash the host. Same risk; mitigate via process isolation for risky tiers (Tier 2 daemons run out-of-process; Tier 3 in-process bundles are explicit power-user opt-in with a "you may crash the host" warning).

### Honorable mentions

- **xbar/BitBar** — closest to your model architecturally (script prints structured output, host renders). The contract is *line-prefixed metadata* (`---` separator, `| color=...` annotations). Brittle but ridiculously simple. Lesson: their popularity proves Tier 1 (script + manifest) is sufficient for 80% of users. Don't over-engineer the floor.
- **Sketchybar** — pure declarative config of menubar items with event-driven updates (`update_freq=0` + named event triggers). Lesson: **event-driven > timer-driven** for menubar surfaces. Adopt this for your "badge" / "menubar" surfaces.
- **Übersicht** — widgets as HTML/CSS/JS + a refresh interval. Single surface (desktop). Lesson: keeping the host dumb and the plugin self-rendering scales, but you sacrifice consistent design language. You're choosing the opposite (host renders pane kinds) — accept that the trade-off is "host must keep adding pane kinds."
- **Hammerspoon Spoons** — Lua scripts as plugins; each Spoon is a Lua table with `init` / `start` / `stop`. Lesson: a tiny, opinionated lifecycle contract gets you 90% of the way. You don't need 12 hooks; you need 4.
- **Raycast extensions** — TypeScript modules with React components, command-centric. Each command is `view` / `no-view` / `menu-bar`. Lesson: **command-centric > view-centric** is the right primitive. Surfaces are how commands manifest.

---

# 6. Proposed Alternative Plan

## 6.1 Naming + mental model

- **Extension** = the unit of installation (a folder, a manifest, optional scripts/daemons).
- **Contribution point** = a named slot in the host (`dashboard.pane`, `menubar.item`, `statusbar.badge`, `command`, `notification.handler`, `settings.section`, `event.subscription`). Closed, well-known, documented.
- **Surface** = a place in the UI where contributions render (Dashboard tab, menubar dropdown, status icon badge, floating panel, notification center).
- **Command** = a named invokable action; can be bound to row buttons, menubar items, hotkeys, quick-actions. **Not** owned by a pane.

Mental model: extensions **contribute** named things into well-known contribution points. The host **resolves** contribution points to surfaces.

## 6.2 Manifest schema (v1, durable)

```jsonc
{
  "manifest_version": 1,             // bumps only for breaking changes to the envelope
  "id": "atone",
  "name": "Atone — mistake tracking",
  "version": "0.3.0",                // semver, plugin's own version
  "engines": { "claude-instances": "^1.0.0" },  // semver range vs host
  "description": "Records mistakes; runs RCAs; consolidates patterns.",
  "icon": "exclamationmark.bubble",
  "accent": "orange",

  "activation": [                    // when to wake this extension (VSCode-style)
    "onSurface:dashboard.pane:atone-main",
    "onCommand:atone.consolidate",
    "onEvent:claude.session.start"
  ],

  "capabilities": ["fs.read", "process.spawn", "events.subscribe"],
  // forward-compat. v1 is informational; v2+ may enforce.

  "contributes": {
    "commands": [
      { "id": "atone.consolidate", "title": "Run consolidate",
        "exec": { "kind": "script", "argv": ["./actions.sh", "consolidate"] },
        "confirm": { "message": "Rebuild derived views?", "destructive": false } },
      { "id": "atone.snapshot", ... },
      { "id": "atone.open-rca", "title": "Open RCA",
        "exec": { "kind": "script", "argv": ["./actions.sh", "open-rca"] },
        "args": [{ "name": "rca_id", "type": "string", "required": true }] }
    ],

    "dashboard.pane": [
      { "id": "atone-main", "title": "Atone", "subtitle": "Mistake tracking & RCAs",
        "section": "Tools", "icon": "exclamationmark.bubble",
        "view": {
          "kind": "stack",
          "panes": [
            { "kind": "summary",  "data": { "source": "fetch", "argv": ["summary"], "refresh_s": 60 } },
            { "kind": "table",    "data": { "source": "fetch", "argv": ["events", "--recent", "20"], "refresh_s": 60 } },
            { "kind": "schedule", "data": { "source": "fetch", "argv": ["schedule"], "refresh_s": 300 } },
            { "kind": "assets",   "data": { "source": "fetch", "argv": ["assets"], "refresh_s": 600 } },
            { "kind": "log",      "data": { "source": "fetch", "argv": ["tail-log", "consolidate", "80"], "refresh_s": 300 } }
          ]
        }
      }
    ],

    "menubar.item": [
      { "id": "atone-menu", "title": "Atone",
        "submenu": [
          { "kind": "command", "command": "atone.consolidate" },
          { "kind": "command", "command": "atone.snapshot" },
          { "kind": "separator" },
          { "kind": "dynamic", "data": { "source": "fetch", "argv": ["menubar"], "refresh_s": 30 } }
        ]
      }
    ],

    "statusbar.badge": [
      { "id": "atone-s3-count",
        "data": { "source": "event", "event": "atone.s3-count", "fallback": { "source": "fetch", "argv": ["badge"], "refresh_s": 120 } },
        "render": { "kind": "pill", "tone_by_value": { "0": "dim", "1+": "warn", "3+": "error" } } }
    ],

    "event.subscriptions": [
      { "event": "claude.tool.use", "handler": "./hooks/on-tool-use.sh" }
    ],

    "settings.section": [
      { "id": "atone-settings", "title": "Atone",
        "schema": "./settings.schema.json",
        "view": "auto"   // "auto" = host generates from schema; or path to custom view
      }
    ]
  },

  "exec": {                          // optional Tier 2 daemon
    "daemon": {
      "argv": ["./daemon.sh"],
      "ready_signal": "json:{\"ready\":true}",  // stdout line that means "I am up"
      "stop_signal": "SIGTERM",
      "restart": "on_crash",
      "max_rss_mb": 64,
      "events_publish": ["atone.s3-count", "atone.consolidate-done"]
    }
  },

  "limits": {
    "fetch_timeout_ms": 10000,
    "fetch_max_per_min": 60,
    "max_rss_mb": 128,
    "max_subprocesses": 4
  }
}
```

Notes:

- `manifest_version` is the *envelope* version. It bumps only when the host changes how it parses the top-level shape. Within an envelope, new contribution points and new fields are additive.
- `engines.claude-instances` is *plugin-controlled*. The plugin says "I work on host versions matching this range." Host refuses to load if mismatch. Plugins age gracefully; users see "atone is for an older host."
- `contributes.*` is the **closed namespace**. Every entry under it is a known contribution point. Unknown keys = warning + ignore. Adding a new contribution point is a host-additive change; old plugins keep working.
- `activation` controls cold-start CPU. A plugin with no active surface stays at literal zero (not parsed beyond manifest).
- `data.source` is `fetch` | `event` | `static` | `daemon-rpc`. Fetch = current model (script invocation). Event = subscribe to a host event topic. Static = inline data, no fetch. Daemon-rpc = ask the running daemon via stdin/stdout JSON-RPC.
- `view: auto` for settings means the host auto-generates a SwiftUI form from a JSON Schema. Plugins that need custom UI can ship a path to a swift-bundle view (Tier 3).

## 6.3 The four execution models (one contract each)

| Tier | Execution | Contract |
|------|-----------|----------|
| 0 | declarative | Manifest only. `data.source: "static"`. No script invoked. Useful for "show these three links" surfaces. |
| 1 | script | Manifest + `fetch.sh` + `actions.sh`. Current v1 model. Host runs as needed. |
| 2 | daemon | Manifest + `exec.daemon`. Host spawns one long-running process per plugin. JSON-RPC over stdin/stdout. Heartbeat every 30s. On crash → restart per `exec.daemon.restart`. **Stops on dashboard quit.** Memory capped. |
| 3 | swift-bundle | Manifest + a `.bundle` with a `PluginEntry` class implementing a defined protocol. In-process. Explicit "may crash host" warning at install. Reserved for first-party + power users. |

**Critical: Tier 0/1 plugins pay nothing for Tier 2/3 mechanism.** The daemon code path only exists for plugins that declare `exec.daemon`. The bundle loader only exists for plugins that declare a bundle. No tax on the simple case.

## 6.4 The daemon protocol (Tier 2)

JSON-RPC over stdin/stdout. Newline-delimited JSON, one message per line.

Host → daemon:
```json
{"id": "1", "method": "fetch", "params": {"pane": "summary"}}
{"id": "2", "method": "action.run", "params": {"command": "atone.consolidate", "args": []}}
{"id": "3", "method": "subscribe", "params": {"events": ["claude.tool.use"]}}
{"id": "4", "method": "ping"}
{"id": "5", "method": "shutdown"}
```

Daemon → host:
```json
{"id": "1", "result": {"kind": "summary", "tiles": [...]}}
{"event": "atone.s3-count", "value": 2}     // unsolicited; published event
{"id": "2", "stream": {"chunk": "consolidate: starting...\n"}}
{"id": "2", "result": {"exit": 0}}
{"id": "4", "result": "pong"}
```

Liveness: host pings every 30s; missed ping → mark stale; second missed → restart per `restart: on_crash`. Plugin can also push `heartbeat` unsolicited.

## 6.5 The event bus

A small host-owned topic broker. Topics are dotted strings, host-prefixed for host events:

- `claude.session.start`, `claude.session.end`, `claude.tool.use`, `claude.idle.30s`
- `host.tick.minute`, `host.tick.hour`
- `host.appear.dashboard`, `host.disappear.dashboard`
- Plugin-published topics: `<plugin-id>.<event>` (e.g., `atone.s3-count`)

Contract: any plugin can subscribe to any topic; only the publishing plugin can publish under its prefix. Host owns `claude.*` and `host.*`. Events carry a JSON payload + monotonic seq. Subscriber callbacks: for daemons, deliver as JSON-RPC message; for scripts, the host runs a configured handler script with the event payload on stdin.

Crucially, **events do not replace pull.** A surface should be able to declare `data.source: "event"` *with* a `fallback: { source: "fetch", refresh_s: ... }` — events for latency, pull for correctness after restart / missed events / cold start.

## 6.6 Error model (one shape, all boundaries)

Every host↔plugin interaction yields an `OperationResult`:

```jsonc
{ "ok": true,  "value": ..., "elapsed_ms": 42, "warnings": [] }
// or
{ "ok": false, "error": {
    "code": "fetch.timeout",        // closed enum, prefixed by stage
    "message": "fetch.sh did not respond in 10s",
    "stderr_tail": "...",            // for script errors
    "actionable": "Increase limits.fetch_timeout_ms or check fetch.sh"
}, "elapsed_ms": 10001 }
```

Closed error codes: `manifest.invalid`, `manifest.unsupported_engine`, `fetch.timeout`, `fetch.exit_nonzero`, `fetch.bad_json`, `fetch.schema_violation`, `action.timeout`, `action.exit_nonzero`, `daemon.disconnected`, `daemon.crashed`, `daemon.memory_exceeded`, `event.unknown_topic`, `event.handler_failed`.

The host's renderer keys off `error.code`, never the message. (Per global rule `rules/error-classification.md`.) Every pane has a defined error-state visual; users never see a blank pane silently.

## 6.7 Resource budgets (enforced)

- `limits.fetch_timeout_ms` (default 10000) — per fetch.
- `limits.fetch_max_per_min` (default 60) — per plugin sliding window. Host throttles; excess fetches return cached + warning.
- `limits.max_rss_mb` (default 128) — daemon only; host RSS-checks every 30s, SIGTERM on breach.
- `limits.max_subprocesses` (default 4) — host counts processes under the plugin's process group; refuses to spawn beyond.
- Global host setting: `disable_all_plugins` (panic switch). When set, registry skips load entirely, no plugin contribution renders.

## 6.8 Migration story for the existing tabs

**This is the test of whether the model is right.** First-party tabs become bundled extensions, shipped inside the host binary, registered at startup:

```
~/.claude/widgets/_bundled/overview/manifest.json   (read-only, host-shipped)
~/.claude/widgets/_bundled/live/manifest.json
~/.claude/widgets/_bundled/history/manifest.json
~/.claude/widgets/_bundled/events/manifest.json
~/.claude/widgets/_bundled/allsessions/manifest.json
~/.claude/widgets/_bundled/rate-limit/manifest.json
~/.claude/widgets/_bundled/scheduled/manifest.json
```

These are Tier 3 (swift-bundle) plugins. The host loader treats `_bundled/*` as in-process; their `view` field points to existing SwiftUI views (`OverviewTabView` etc.). The `DashboardTab` enum *disappears*; `DashboardRootView` becomes:

```swift
ForEach(registry.contributions(point: "dashboard.pane")) { contribution in
    PaneRenderer(contribution)
}
```

The sidebar groups by `contribution.section` (today's "Dashboard"/"Details"/"Help"). A bundled extension can declare itself unremovable in its manifest (`"system": true`).

This means: even today's hardcoded tabs go through the same registry, the same renderer, the same activation lifecycle. The platform is dogfooded from day one. A user who writes a custom widget is using the same machinery as `OverviewTabView`. **If a first-party tab can't be expressed as an extension, the platform is wrong.** (See §7 for the walkthrough.)

## 6.9 Build sequence

1. **Define the manifest schema** (`docs/extension-manifest.md`) — frozen v1 envelope, closed contribution-point list. JSON schema file.
2. **`Extension` + `ContributionPoint` Codable types in DashboardKit.** Loader + validator.
3. **Refactor `DashboardRootView`** to render from a `Registry` of `dashboard.pane` contributions instead of switching on `DashboardTab`. Inline a stub registry that loads the existing tabs as bundled extensions. **At this point the app behaves identically; the wiring is just different.** Ship this. No new feature visible to user.
4. **Add the `script` execution model** (current v1 fetch.sh + actions.sh). Drop the atone widget. Verify 5 panes render.
5. **Add `menubar.item` contribution point** + render path. Add an atone menubar entry as the first non-trivial multi-surface example.
6. **Add `statusbar.badge`** + `event.subscription`. Rate-limit countdown moves to event-driven.
7. **Add `daemon` execution model** + JSON-RPC. First daemon plugin: something that justifies it (e.g., a GitHub PR watcher that long-polls).
8. **Add `swift-bundle` execution model.** Mostly to formalize the bundled extensions.
9. **Hot-reload** on manifest drop, gated on per-plugin "is anything in flight?" check.

Steps 1–3 are independently valuable: they decouple the dashboard from its tab list without exposing anything externally.

---

# 7. Migration Walkthrough

Two existing first-party features, walked through under the proposed model.

## 7.1 Rate-limit countdown (the harder one)

Today: a bar somewhere in the menu / status icon showing time until rate-limit reset. Updates frequently. Sourced from a Claude API response header or a local cache file.

Under the proposed model:

```jsonc
{
  "manifest_version": 1,
  "id": "rate-limit",
  "name": "Rate Limit",
  "version": "1.0.0",
  "engines": { "claude-instances": "^1.0.0" },
  "system": true,

  "activation": ["onStartup"],     // always on; it's a status indicator

  "contributes": {
    "statusbar.badge": [
      { "id": "rate-limit-countdown",
        "data": {
          "source": "event",
          "event": "rate-limit.tick",
          "fallback": { "source": "fetch", "argv": ["snapshot"], "refresh_s": 30 }
        },
        "render": {
          "kind": "countdown",
          "tone_by_value": { "0..300": "error", "300..1800": "warn", "1800+": "dim" },
          "format": "mm:ss"
        }
      }
    ],
    "menubar.item": [
      { "id": "rate-limit-menu",
        "title_template": "Rate limit: {countdown}",
        "data": { "source": "event", "event": "rate-limit.tick" },
        "submenu": [
          { "kind": "command", "command": "rate-limit.show-detail" },
          { "kind": "command", "command": "rate-limit.refresh-now" }
        ]
      }
    ],
    "dashboard.pane": [
      { "id": "rate-limit-pane", "section": "Status", "title": "Rate Limit",
        "view": { "kind": "stack",
                  "panes": [{ "kind": "summary", "data": { "source": "event", "event": "rate-limit.tick" } }] } }
    ],
    "commands": [
      { "id": "rate-limit.show-detail", "title": "Show rate-limit details",
        "exec": { "kind": "internal", "open_pane": "rate-limit-pane" } },
      { "id": "rate-limit.refresh-now", "title": "Refresh now",
        "exec": { "kind": "script", "argv": ["./refresh.sh"] } }
    ]
  },

  "exec": {
    "daemon": {
      "argv": ["./daemon.sh"],           // polls API / watches header cache, emits rate-limit.tick every 1s
      "ready_signal": "json:{\"ready\":true}",
      "restart": "on_crash",
      "max_rss_mb": 32,
      "events_publish": ["rate-limit.tick"]
    }
  },

  "limits": { "max_rss_mb": 32 }
}
```

Key properties:
- **One** daemon, one source of truth. Publishes `rate-limit.tick` once per second.
- **Three** surfaces (statusbar badge, menubar item, dashboard pane) all subscribe to the same event. No duplicated fetch cost. No drift between surfaces.
- **Render** is declarative (`countdown` + `tone_by_value`); the host handles the visual primitives. Plugin author doesn't write SwiftUI.
- **Fallback** to a pull every 30s for cold start / daemon crash recovery.
- **Bundled** (`system: true`) means it's shipped with the host, unremovable, but uses the same machinery as user extensions. If the platform can't render this with the public contract, it's broken.

Compare to v1 spec: this is **impossible**. There's no per-second tick without spawning a process per second; no menubar surface; no event publishing; no shared state across the three places it needs to render.

## 7.2 Live sessions tab (today's `LiveTabView`)

Today: scans Claude session directories every 5s, renders a list of running processes with PID/turns/RSS/cost. Action buttons: focus terminal, terminate, copy PID, open transcript.

Under the proposed model:

```jsonc
{
  "manifest_version": 1,
  "id": "live",
  "name": "Live",
  "version": "1.0.0",
  "engines": { "claude-instances": "^1.0.0" },
  "system": true,

  "activation": ["onSurface:dashboard.pane:live-main"],

  "contributes": {
    "dashboard.pane": [
      { "id": "live-main", "title": "Live", "section": "Dashboard",
        "icon": "sparkles", "accent": "green",
        "view": {
          "kind": "stack",
          "panes": [
            { "kind": "summary", "data": { "source": "host-feed", "feed": "scan.summary", "refresh_s": 5 } },
            { "kind": "table",
              "data": { "source": "host-feed", "feed": "scan.live", "refresh_s": 5 },
              "row_actions": [
                { "label": "Focus",       "command": "live.focus",       "args_from_row": ["cwd"] },
                { "label": "Terminate",   "command": "live.terminate",   "args_from_row": ["pid"], "destructive": true },
                { "label": "Copy PID",    "command": "live.copy-pid",    "args_from_row": ["pid"] },
                { "label": "Transcript",  "command": "live.transcript",  "args_from_row": ["pid", "session_id"] }
              ] }
          ]
        }
      }
    ],
    "statusbar.badge": [
      { "id": "live-count",
        "data": { "source": "host-feed", "feed": "scan.summary.liveCount", "refresh_s": 5 },
        "render": { "kind": "pill", "format": "{value} live", "tone_by_value": { "0": "dim", "1+": "ok" } } }
    ],
    "commands": [
      { "id": "live.focus",      "exec": { "kind": "internal", "handler": "focusGhosttyTab" } },
      { "id": "live.terminate",  "exec": { "kind": "internal", "handler": "killPid" } },
      { "id": "live.copy-pid",   "exec": { "kind": "internal", "handler": "copyToClipboard" } },
      { "id": "live.transcript", "exec": { "kind": "internal", "handler": "openTranscript" } }
    ]
  }
}
```

Key properties:
- **`source: "host-feed"`** is the answer to the missed limitation in §3: a host-published shared data source. The host runs the scan once; multiple plugins subscribe. The "feed" is identified by a dotted name (`scan.summary`, `scan.live`); host publishes feeds as part of its API.
- **`row_actions` → `command`** — actions are first-class commands, not children of panes. The same `live.focus` command can be invoked from a hotkey, a menubar item, a row button.
- **Internal handlers** — first-party commands resolve to in-host Swift functions; same machinery as Tier 3. Third-party plugins use `kind: "script"` or `kind: "daemon-rpc"`.
- **Activation** is `onSurface:dashboard.pane:live-main` — the scan only runs when the live pane is visible OR when something else subscribes to its feed (the statusbar badge counts as a subscriber, so as soon as the user enables the live-count badge, the scan runs always).
- This is **identical behavior to today**, expressed through the public contract. A user who writes a new dashboard pane uses the same `host-feed` API. The host doesn't need a special case for first-party tabs.

Both examples pass. The contract handles them.

---

# 8. Open Questions Worth Asking the User

1. **Is the bundled-extension-from-day-one ambition acceptable?** It's the right architecture, but step 3 of the build sequence (refactor `DashboardRootView` to load from a registry) is a non-trivial change with zero user-visible benefit on its own. Confirm willingness to spend that day before any new feature lands.
2. **How important is true sandboxing eventually?** Today: "single-user local, no sandbox." Goal-list says "host hits 60fps regardless of plugin count" + "misbehaving plugin degrades to stale, never freezes." Process isolation for Tiers 0/1/2 is enough for liveness; Tier 3 is in-process and *can* crash the host. Is Tier 3 worth that risk for first-party only, or do you want to ban in-process bundles entirely?
3. **Settings UI generation strategy:** schema-driven auto-form (cheap, ugly, consistent) vs let-plugin-ship-a-view (pretty, fragmented, more work). VSCode picked the former; Raycast picked the latter. Pick now.
4. **Plugin distribution:** is `~/.claude/widgets/<id>/` enough forever, or do you eventually want a registry / install command / signed packages? The answer affects whether `id` needs to be globally unique (reverse-DNS, e.g., `dev.alcatraz.atone`) or can stay short.
5. **Event-bus delivery guarantees:** at-most-once (simpler) vs at-least-once with ack (complex but safer for "missed a tick"). The rate-limit example assumes at-most-once + fallback poll. Confirm that's the contract.
6. **Hot-reload scope:** manifest-only changes hot-reload cleanly; `fetch.sh` changes are picked up on next invocation; daemon code changes require restart. Document that contract explicitly.
7. **Bundled extension version skew:** if first-party tabs become extensions and the host ships them in-binary, do they version-bump with the host? Are they ever overridable by a user-installed extension of the same `id`? Forbid? Allow with warning?
8. **Multiple instances of the same extension:** can a user have two "GitHub PR queue" extensions configured against different repos? If yes, `id` is not enough; need `instance_id`. Affects manifest.
9. **Does the dashboard ever need to *render plugin-owned SwiftUI* in user-installed plugins (not just bundled)?** If yes, you need a code-signing story or accept arbitrary Swift loaded into the app. If no, third-party plugins are forever capped at the declarative pane kinds (which may be enough).
10. **The atone BUILD.md flow includes hinters firing on `UserPromptSubmit`.** Should plugins be able to contribute hinters? That's effectively allowing a plugin to inject context into your conversations. Powerful, scary, and a meaningful policy question.

---

# 9. Confidence Notes

- **High confidence:** §2 critical flaws F1–F4 are correct and material. The contribution-point + activation-event model is the right answer; this is well-trodden ground.
- **High confidence:** the migration walkthrough in §7 works. The rate-limit example is the load-bearing one — if you can't express that, the model is wrong; the proposed model expresses it.
- **Medium confidence:** the daemon JSON-RPC shape in §6.4. I picked a simple newline-delimited variant; a real implementation might prefer length-prefixed framing or even Unix-domain sockets if performance matters. The *shape* (id/method/result/event) is correct; the wire format is a detail.
- **Medium confidence:** the host-feed abstraction in §7.2. It's the right idea but the concrete API (`feed: "scan.live"`) is hand-waved. Probably wants its own design doc.
- **Lower confidence:** the swift-bundle Tier 3 path. Loading external bundles into a macOS app has code-signing implications I haven't worked through. Safe fallback: keep Tier 3 in-host-binary-only for first-party bundled extensions, drop the "power user external bundle" idea.
- **Low confidence about prioritization:** I'm recommending a register/contribution-point refactor (build step 3) as a precondition to *any* new platform work. That's correct architecturally but it's a delayed-gratification call. The user might reasonably prefer to ship v1 widget-system.md as-is, learn from real plugin use, and then refactor. I'd push back on that — once you ship a manifest schema, you own it forever — but it's a judgment call.
- **Unverified claims:** I read DashboardKit boundary + the `DashboardTab` enum, but did not read the full `LiveTabView` body. The "internal handler" approach in §7.2 assumes the existing action callbacks (`onFocus`, `onTerminate`, etc.) can be cleanly mapped to named commands. Probable but worth confirming.
- **Source attribution:** plugin-platform claims about VSCode, Obsidian, IntelliJ, Raycast, xbar, Sketchybar, Übersicht, Hammerspoon are from working knowledge of their public extension APIs; not freshly re-verified from their current docs. Treat specific API names (`contributes`, `activationEvents`, `engines`, `<extensionPoint>`) as architectural correct, but check current spelling/syntax before implementing.
