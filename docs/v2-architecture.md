# claude-instances V2 — Architecture

> **Status:** spec, build-in-progress · **Date:** 2026-05-15
> **Companion:** [`v2-implementation-plan.md`](./v2-implementation-plan.md) — the build sequence.
> **Predecessor reference:** [`_v1-reference/`](./_v1-reference/) — original V1 widget-system spec
> and the three-reviewer adversarial review that drove this design.
>
> This doc is the **durable contract** for V2. It defines what plugins are, how
> they declare themselves, what surfaces they can attach to, how the host
> talks to them, and what survives across host upgrades. It does not contain
> the build sequence; that lives in the implementation plan.

---

## 0. Vision

`claude-instances` V2 is a **plugin platform**. The host is a small kernel
that hosts plugins. Plugins are the units of feature. Every dashboard tab,
every menu-bar entry, every status badge, every scheduled-job inspector is
a plugin — including the ones shipped with the binary.

The platform has two audiences:

1. **Immediate (year 1):** the author of this repo. All plugins are
   author-written, committed alongside the host source, compiled into or
   loaded alongside the host binary. The platform is a clean internal
   architecture more than an external contract.
2. **Eventual (year 2+):** external plugin authors. The same manifest /
   contribution-point / event-bus contract supports drop-in script plugins
   from outside the repo without any architectural changes.

V2 is designed to make the first audience productive immediately, while
keeping every external-audience interface stable from day one.

### Non-goals (forever)

- Mac App Store distribution. The host has no sandbox; plugins have full
  filesystem access.
- Cross-platform. macOS only.
- Cross-machine plugin sync. Plugins live in git; the user syncs the repo.
- LLM-based or AI-driven plugin behavior. The host is dumb; plugins are
  dumb; smart behavior lives in the data they read.

### Non-goals (for V1 of V2)

- Sandboxing / capability enforcement (declared but not enforced).
- Plugin discovery store / marketplace.
- Daemon execution model (no concrete consumer demands it yet; native
  plugins cover the state-keeping case).
- Hot-reload at the source level (manifests + scripts hot-reload; native
  plugin code changes require rebuild + restart).

---

## 1. Mental model

```
                ┌──────────────────────────────────────────┐
                │             HOST SHELL (kernel)          │
                │                                          │
                │  ┌─────────────────────────────────┐    │
                │  │  Registry                       │    │
                │  │   - loads plugins/*/manifest.json    │
                │  │   - resolves contribution points     │
                │  │   - manages plugin lifecycle    │    │
                │  └────────────┬────────────────────┘    │
                │               │                          │
                │  ┌────────────▼─────────┐  ┌──────────┐ │
                │  │  Event Bus           │  │ Resource │ │
                │  │  - typed topics      │  │ Sampler  │ │
                │  │  - host.* / claude.* │  │          │ │
                │  └──────────────────────┘  └──────────┘ │
                │                                          │
                │  Surfaces:                               │
                │   dashboard | menubar | statusbar |      │
                │   floater | notification | quick-action  │
                └──────────────┬───────────────────────────┘
                               │ contributions render to surfaces
              ┌────────────────┴────────────────────┐
              │                                     │
   ┌──────────▼──────────┐               ┌─────────▼────────────┐
   │  NATIVE plugins     │               │  SCRIPT plugins      │
   │                     │               │                      │
   │  manifest.json      │               │  manifest.json       │
   │  Plugin.swift       │               │  fetch.sh / actions.sh │
   │  (compiled into     │               │  (executed on demand │
   │   host binary)      │               │   per change signal) │
   └─────────────────────┘               └──────────────────────┘
```

**Key abstractions** (each precisely defined in §3 / §4):

- **Plugin** — the unit of install. A folder under `plugins/` (in-repo) or
  `~/.claude/widgets/` (drop-in). Identified by manifest `id`.
- **Manifest** — `manifest.json`. Declarative description of what the plugin
  contributes, what surfaces it wants, what data it reads, what it depends
  on. The only file the host parses directly.
- **Contribution point** — a named slot in the host that plugins can fill
  (`dashboard.pane`, `menubar.item`, `commands`, etc.). The namespace is
  **closed** — adding a new one is a host change, not a plugin choice.
- **Contribution** — a single instance of a plugin filling a contribution
  point (one row in `contributes.dashboard.pane`).
- **Surface** — a place in the UI where contributions render. One surface
  consumes one contribution point (dashboard surface consumes
  `dashboard.pane`).
- **Command** — a named action a plugin exposes. First-class; can be bound
  to row buttons, menu items, hotkeys, quick-actions.
- **Event** — a typed topic on the bus (`claude.session.start`, dotted-
  prefix scheme). Host emits some; plugins emit their own under their `id`
  prefix.
- **Pane** — a visual primitive a `dashboard.pane` contribution can declare.
  Five kinds in V1 of V2: `summary`, `table`, `schedule`, `assets`, `log`.

---

## 2. Filesystem layout

### 2.1 In-repo (source tree)

```
claude-instances-v2/                  (this worktree)
  docs/
    v2-architecture.md                (this file)
    v2-implementation-plan.md
    _v1-reference/
      widget-system.md                (the superseded V1 spec)
      reviews/                        (the 3-reviewer + consolidated reports)
  host/
    Sources/HostKernel/               (Swift: registry, event bus, surfaces)
    Sources/HostShell/                (Swift: NSStatusItem, dashboard window)
    Tests/
  plugins/                            (author-controlled, compiled in)
    overview/
      manifest.json
      Plugin.swift
    live/
      manifest.json
      Plugin.swift
    rate-limit/
      manifest.json
      Plugin.swift
    atone/
      manifest.json
      fetch.sh
      actions.sh
    scheduled/
      manifest.json
      fetch.sh
    ...
  scaffolding/
    claude-widget                     (the CLI: new / validate / doctor)
    templates/
      script-plugin/                  (template used by `claude-widget new`)
      native-plugin/
  build.sh
  Package.swift                       (Swift Package — host + bundled plugins)
```

### 2.2 Runtime (where plugins live in the user's home dir)

```
~/.claude/widgets/                    (drop-in script plugins, optional)
  <plugin-id>/
    manifest.json
    fetch.sh
    ...

~/Library/Application Support/dev.claude-instances-v2/
  state.json                          (per-plugin enabled/disabled, settings)
  cache/<plugin-id>/                  (host-managed plugin cache, TTL'd)
  logs/<plugin-id>.log                (rotated logs per plugin, 10 MB ring)
```

Native plugins live only in the source tree (compiled into the binary).
Script plugins can live in either the source tree (committed alongside,
distributed with the binary) or in `~/.claude/widgets/` (user drop-in for
out-of-tree work).

The host **never** writes to a plugin's source directory at runtime —
plugin-owned state goes to plugin-managed dirs (e.g. `~/.claude/atone/`),
host-owned state goes to `~/Library/Application Support/`.

### 2.3 Why two tiers (native vs script)?

Native plugins exist because some surfaces are performance-critical:
`Live` and `AllSessions` are search-sort-table views over in-memory
`@Published` data that re-renders on every keystroke. Round-tripping
through `Process` + JSON would degrade the UX measurably.

Script plugins exist because most surfaces are *not* performance-critical:
atone, scheduled jobs, proposals, memory browser are read-only views over
files-on-disk that change rarely. A 60ms fetch on FSEvents tick is invisible
to the user.

The same plugin can mix: a manifest with both `Plugin.swift` (for the
performance-critical pane) and `fetch.sh` (for the rest) is legal.

---

## 3. Manifest schema (durable contract)

`manifest.json` is the only file the host parses directly. All other data
flows through plugin code (Swift class or shell stdout).

### 3.1 Schema (v1 envelope)

```jsonc
{
  // Envelope versioning — bumps only when the host changes how it parses
  // the top-level shape. Within an envelope, new contribution points and
  // new fields are additive and don't bump this number.
  "manifest_version": 1,

  // Plugin identity. Must match directory name. Reverse-DNS allowed:
  // "atone" or "dev.alcatraz.atone".
  "id": "atone",
  "name": "Atone",
  "version": "0.3.0",                              // semver, plugin's own
  "description": "Records mistakes, runs RCAs, consolidates patterns.",

  // Host compatibility range. Plugin says "I work on these host versions."
  // Host refuses to load on mismatch with a clear "needs newer host" or
  // "this plugin is for an older host" message.
  "engines": { "claude-instances": "^2.0.0" },

  // Cosmetic. Host falls back to a generic puzzle-piece icon.
  "icon": "exclamationmark.bubble",                // SF Symbol
  "accent": "orange",                              // PaletteToken name

  // Capabilities the plugin needs. Informational in V1; eventually
  // surfaced in UI ("this plugin reads ~/.claude") and possibly enforced.
  "capabilities": [
    "fs.read",          // reads files outside its own dir
    "process.spawn",    // shells out
    "events.subscribe", // subscribes to host event bus
    "events.publish"    // emits events under its own prefix
  ],

  // Activation rules. Plugin is dormant until at least one fires.
  // Always-on plugins use ["onStartup"]; lazy ones use surface activations.
  "activation": [
    "onSurface:dashboard.pane:atone-main",
    "onCommand:atone.consolidate"
  ],

  // External dependencies the plugin needs. Host's `claude-widget doctor`
  // checks these; Plugin Manager UI surfaces missing tools.
  "requires": ["jq>=1.6", "flock"],

  // The plugin's contributions. CLOSED NAMESPACE — unknown keys = warning.
  "contributes": {
    "commands": [ /* §4.3 */ ],
    "dashboard.pane": [ /* §4.4 */ ],
    "menubar.item": [ /* §4.5 */ ],
    "statusbar.badge": [ /* §4.6 */ ],
    "event.subscriptions": [ /* §4.7 */ ],
    "settings.section": [ /* §4.8 */ ],
    "hotkey": [ /* §4.12 */ ],
    "quick-action": [ /* §4.9 */ ],
    "notification.handler": [ /* §4.10 */ ]
  },

  // How the plugin executes. One of:
  //   "native" — host uses a registered Plugin.swift class
  //   "script" — host invokes scripts under the plugin dir
  //   "mixed"  — manifest specifies which contributions use which
  "exec": {
    "kind": "script",
    "fetch": "./fetch.sh",          // executable; argv from contribution
    "action": "./actions.sh"        // executable; argv from command
  },

  // Data-source defaults (overridable per-contribution).
  "refresh": {
    "on_fs_change": [
      "~/.claude/atone/derived/_meta.json",
      "~/.claude/atone/events.jsonl"
    ],
    "on_event": ["atone.consolidate.done"],
    "poll_seconds": 600                            // safety-net only
  },

  // Resource budgets. Host enforces what it can.
  "limits": {
    "fetch_timeout_ms": 1500,                      // soft; SIGTERM at this
    "fetch_hard_kill_ms": 5000,                    // hard; SIGKILL at this
    "fetch_max_per_min": 6,                        // sliding-window cap
    "max_payload_bytes": 262144,                   // 256 KB; truncate above
    "max_subprocesses": 4
  }
}
```

### 3.2 Required fields

`manifest_version`, `id`, `name`, `version`, `engines.claude-instances`,
at least one entry in `contributes.*`, and `exec`. Everything else is
optional with sensible defaults.

### 3.3 Host validation

On load:
1. JSON parses → if not, plugin disabled with `manifest.invalid` error.
2. `manifest_version` is known → if not, plugin disabled with
   `manifest.unsupported_envelope` (and surfaced in Plugin Manager as
   "needs newer host").
3. `engines.claude-instances` matches host version → if not, disabled
   with `engines.mismatch`.
4. Required fields present + types correct → if not, `manifest.invalid`.
5. `contributes.*` keys all in the known set → unknown keys logged as
   warnings, ignored (forward-compat).
6. Per-contribution validation (commands have unique IDs, panes have
   known kinds, etc.) → invalid contributions are skipped; rest of
   plugin still loads.

Invalid manifests **never break the host.** Worst case: plugin doesn't
load, error visible in Plugin Manager.

---

## 4. Contribution points (closed namespace)

The host defines this list. Adding to it is a host change. Plugins
cannot invent new contribution points.

### 4.1 Open enum vs closed enum

The contribution-point namespace is **closed**. The pane-kind namespace
is **closed**. The event-topic namespace is **half-open**: host-prefixed
topics (`host.*`, `claude.*`) are closed; plugin-prefixed topics
(`<plugin-id>.*`) are open.

### 4.2 The complete list (V1 of V2)

| Contribution point      | Surface          | V1 status     | Notes |
|--------------------------|------------------|---------------|-------|
| `commands`               | (multiplex)      | **shipped**   | First-class invokable actions. Referenced from panes, menus, hotkeys, quick-actions. |
| `dashboard.pane`         | Dashboard tab    | **shipped**   | Primary surface. Multi-pane stack inside a tab. |
| `settings.section`       | Settings tab     | **shipped**   | Host auto-renders form from JSON Schema. |
| `event.subscriptions`    | (no UI)          | **shipped**   | Plugin reacts to bus events. |
| `hotkey`                 | Global / scoped  | **shipped**   | Keyboard shortcut → command binding. Scope: global / dashboard / menu-open. |
| `menubar.item`           | Menu dropdown    | **stubbed**   | Schema known; host warns "not implemented yet". |
| `statusbar.badge`        | Status icon area | **stubbed**   | Schema known; not rendered. |
| `quick-action`           | Cmd-palette      | **stubbed**   | Schema known; palette UI not built. |
| `floater`                | Always-on-top window | **stubbed** | Schema known; floater system not built. |
| `notification.handler`   | macOS notifications | **stubbed** | Schema known; only host-emitted notifications fire in V1. |

**Stubbed** means: a plugin can declare these in its manifest without
error (host warns once: "atone declares menubar.item; menubar surface not
implemented in V1; the contribution is preserved for future activation").
When V1.1+ implements a surface, no plugin manifests need editing.

### 4.3 `commands`

```jsonc
"commands": [
  {
    "id": "atone.consolidate",
    "title": "Run consolidate",
    "description": "Rebuild derived views from raw events",
    "confirm": {
      "message": "This rebuilds derived views from events.jsonl. Proceed?",
      "destructive": false
    },
    // Argv-style; host never shell-interprets. Args for parameterized
    // commands append after these. Token "$pluginDir" expands.
    "exec": {
      "kind": "script",
      "argv": ["$pluginDir/actions.sh", "consolidate"]
    },
    // For native plugins, exec.kind = "native" + exec.handler = method name
    "args_schema": []   // JSON Schema array; commands can take typed args
  },
  {
    "id": "atone.open-rca",
    "title": "Open RCA",
    "exec": { "kind": "script", "argv": ["$pluginDir/actions.sh", "open-rca"] },
    "args_schema": [
      { "name": "rca_id", "type": "string", "required": true }
    ]
  }
]
```

Commands have stable `id`s globally (prefixed with plugin id). They can
be referenced by:
- `dashboard.pane.row_actions[].command`
- `menubar.item.submenu[].command`
- `quick-action.command`
- Hotkey bindings (when hotkey contribution lands)

When invoked, command output streams to a host-managed log pane. Argv
items pass through `Process` argv directly — no shell. Commands `$pluginDir`
expands to the plugin's absolute filesystem path.

### 4.4 `dashboard.pane`

```jsonc
"dashboard.pane": [
  {
    "id": "atone-main",
    "title": "Atone",
    "subtitle": "Mistake tracking & RCAs",
    "section": "Tools",                              // sidebar grouping
    "icon": "exclamationmark.bubble",
    "accent": "orange",

    // The pane stack rendered in the tab body.
    "panes": [
      { "kind": "summary",  "source": "fetch:summary",        "refresh": "default" },
      { "kind": "table",    "source": "fetch:events --recent 20" },
      { "kind": "schedule", "source": "fetch:schedule" },
      { "kind": "assets",   "source": "fetch:assets" },
      { "kind": "log",      "source": "fetch:tail-log consolidate 80",
                            "refresh": { "poll_seconds": 300 } }
    ]
  }
]
```

`source` is a tagged string:
- `fetch:<args>` — invoke the plugin's `exec.fetch` with those argv tokens
- `event:<topic>` — subscribe to a bus topic; payload becomes pane data
- `native:<method>` — call the native plugin's named method (native only)
- `static:<inline-data>` — embed data directly in manifest (rare)

Pane kinds in §6.

### 4.5 `menubar.item` (stubbed surface, schema shipped)

```jsonc
"menubar.item": [
  {
    "id": "atone-menu",
    "title": "Atone",
    "title_source": "fetch:menubar-title",            // optional dynamic title
    "submenu": [
      { "kind": "command", "command": "atone.consolidate" },
      { "kind": "command", "command": "atone.snapshot" },
      { "kind": "separator" },
      { "kind": "dynamic", "source": "fetch:menubar-items" }
    ]
  }
]
```

`menubar.item.submenu[].kind` is one of: `command` (renders title from
the referenced command), `separator`, `link` (URL), `static` (label only),
`dynamic` (host invokes source on menu-open, expects an array of items).

### 4.6 `statusbar.badge`

```jsonc
"statusbar.badge": [
  {
    "id": "atone-s3-count",
    "source": "event:atone.s3-count",
    "fallback": { "source": "fetch:badge", "poll_seconds": 120 },
    "render": {
      "kind": "pill",                                  // pill | dot | text
      "tone_by_value": { "0": "dim", "1+": "warn", "3+": "error" }
    },
    "background_active": true                          // ALWAYS-VISIBLE; counts against global cap
  }
]
```

Badge contributions are **background-active**: they consume resources even
when no dashboard is open. The host counts them against a global cap
(default 10, configurable). User opts in per-badge in Plugin Manager.

### 4.7 `event.subscriptions`

```jsonc
"event.subscriptions": [
  {
    "event": "claude.tool.use",
    "handler": "./hooks/on-tool-use.sh",     // script plugins
    // OR for native: "handler_method": "onToolUse"
    "debounce_ms": 200
  }
]
```

The handler script gets the event payload on stdin as JSON. Native
plugins receive a typed Swift struct via the named method. Topic
namespace rules in §5.

### 4.8 `settings.section`

```jsonc
"settings.section": [
  {
    "id": "atone-settings",
    "title": "Atone",
    "schema": "./settings.schema.json",       // JSON Schema (draft 2020-12)
    "view": "auto"                            // "auto" = host renders form
    // Native plugins can specify "view_method": "settingsView" instead
  }
]
```

Settings values persist to `~/Library/Application Support/dev.claude-
instances-v2/state.json` under the plugin's id. Plugins read their own
settings via:
- Script: env var `CLAUDE_PLUGIN_SETTINGS=/path/to/settings.json` is set
  on every `fetch.sh` / `actions.sh` invocation
- Native: `host.settings(forPlugin: id)` returns a typed dictionary

### 4.9 `quick-action`, 4.10 `notification.handler`, 4.11 `floater` (all stubbed)

Schemas defined so V1 manifests can declare them; surfaces not implemented.
See `_v1-reference/reviews/architect.md` §6.2 for full design.

### 4.12 `hotkey`

Keyboard shortcuts bound to commands. Defaults declared in manifest; user
rebinds in Settings (and the binding persists in `state.json` under the
plugin's id).

```jsonc
"hotkey": [
  {
    "id": "live.focus-1",
    "command": "live.focus",
    "args": { "index": 1 },                  // bound args; merged with site args
    "default_binding": "cmd+1",              // human-readable; nil = unbound
    "scope": "menu-open",                    // global | dashboard | menu-open
    "title": "Focus session 1"               // shown in Settings rebinder UI
  },
  {
    "id": "atone.consolidate-hotkey",
    "command": "atone.consolidate",
    "default_binding": "ctrl+opt+a",
    "scope": "global"
  }
]
```

**Scopes:**
- `global` — registered as a system-wide `NSEvent` global monitor. Fires
  regardless of focused app. Host UI surfaces these in Plugin Manager so
  the user can audit global bindings.
- `dashboard` — only fires when the dashboard window has focus
  (first-responder routing).
- `menu-open` — only fires while the menu-bar dropdown is open. Useful
  for "press `1` to focus the first session" and similar inside-menu
  shortcuts (the V1 submenu-keystrokes feature).

**Conflicts:** if two plugins bind the same chord at the same scope, the
host disables the later-registered one and surfaces a conflict in
Plugin Manager. User can rebind to resolve.

**Hotkeys reference commands** rather than dispatching directly. Same
command can have multiple bindings (one global, one menu-open) and a
row-action button — they all do the same thing.

### 4.13 Worked example — live-sessions plugin

The V1 "menu-bar instance row card" + per-row hotkeys are a natural test
of the contribution model. In V2 they become a single native plugin
declaring four contribution kinds:

```jsonc
{
  "manifest_version": 1,
  "id": "live-sessions",
  "name": "Live Sessions",
  "exec": { "kind": "native" },
  "contributes": {
    "commands": [
      { "id": "live.focus", "title": "Focus session",
        "args_schema": [{ "name": "pid", "type": "integer", "required": true }],
        "exec": { "kind": "native", "handler": "focusSession" } },
      { "id": "live.terminate", "title": "Terminate",
        "args_schema": [{ "name": "pid", "type": "integer", "required": true }],
        "confirm": { "destructive": true, "message": "Send SIGTERM to {pid}?" },
        "exec": { "kind": "native", "handler": "terminateSession" } },
      { "id": "live.transcript", "title": "Open transcript",
        "exec": { "kind": "native", "handler": "openTranscript" } }
    ],
    "menubar.item": [
      { "id": "live-rows", "title_source": "native:menubarTitle",
        "submenu": [
          { "kind": "dynamic", "source": "native:rowsForMenu" }
        ] }
    ],
    "dashboard.pane": [
      { "id": "live-main", "section": "Dashboard", "title": "Live",
        "panes": [ { "kind": "custom", "source": "native:liveTabView" } ] }
    ],
    "hotkey": [
      { "id": "live.focus-1", "command": "live.focus", "args": { "index": 1 },
        "default_binding": "1", "scope": "menu-open", "title": "Focus #1" },
      { "id": "live.focus-2", "command": "live.focus", "args": { "index": 2 },
        "default_binding": "2", "scope": "menu-open" }
      // … indexed for visible rows
    ]
  }
}
```

Single plugin, four surfaces, one set of commands referenced everywhere.
No duplication. The hotkeys, the menu rows, the dashboard table, and the
right-click actions all dispatch the same `live.focus` / `live.terminate`
commands.

This is the load-bearing demonstration that the contribution model
isn't over-engineered: a real feature with 4 surfaces collapses cleanly
into one manifest.

---

## 5. Event bus

A typed topic broker, owned by the host kernel. Backed by `NotificationCenter`
internally; exposed as a typed API to native plugins and as a JSON-over-stdin
contract to script plugins.

### 5.1 Topic namespace

- `host.*` — host-emitted lifecycle: `host.startup`, `host.shutdown`,
  `host.tick.minute`, `host.tick.hour`, `host.appear.dashboard`,
  `host.disappear.dashboard`, `host.surface.<surface>.activate`,
  `host.surface.<surface>.deactivate`.
- `claude.*` — Claude-session events: `claude.session.start`,
  `claude.session.end`, `claude.tool.use`, `claude.idle.30s`,
  `claude.compact`, `claude.rate-limit.update`.
- `<plugin-id>.*` — plugin-published, namespaced by plugin id. Only the
  publishing plugin can emit under its prefix; host enforces.

### 5.2 Event shape

Every event has:
- `topic: String` — dotted name
- `payload: JSONValue` — arbitrary; topic owners document expected shape
- `seq: UInt64` — monotonic per topic
- `ts: ISO8601` — emission timestamp

### 5.3 Delivery semantics

- **At-most-once.** Subscribers that miss an event due to debounce,
  start-after-emit, or temporary disconnect get nothing.
- **In-process, synchronous fan-out** for native subscribers.
- **Spawn-budgeted** for script subscribers: handler script invocation
  counts against the plugin's `fetch_max_per_min`. Bursty events get
  debounced per subscription's `debounce_ms`.
- **No replay, no durable queue.** Events are ephemeral. Plugins that
  need durable state read from files; events are signals to *recheck*,
  not the data itself.

### 5.4 Why this design

Critical for performance (the FSEvents-replacement for non-FS signals)
and composition (rate-limit emits one tick, three surfaces consume it
without each polling). Cheap to implement on top of `NotificationCenter`.
Stays out of the way for plugins that don't need it.

---

## 6. Pane kinds (closed enum, V1 of V2)

Five kinds, each with a fixed payload schema. `fetch:<args>` output must
match the kind's schema; failures show error state on the pane.

### 6.1 `summary`

```jsonc
{
  "kind": "summary",
  "tiles": [
    { "label": "Events recorded", "value": "147", "trend": "+3 this week" },
    { "label": "Top pattern", "value": "git-add-shape", "badge": "S3",
      "tone": "warn" },
    { "label": "Last consolidate", "value": "2026-05-14 09:00", "tone": "ok",
      "progress_pct": 73 }
  ]
}
```

Tones: `ok` | `warn` | `error` | `dim` | `none`. `progress_pct`
optional 0–100; renders as slim bar under tile.

### 6.2 `table`

```jsonc
{
  "kind": "table",
  "columns": [
    { "id": "ts", "label": "When", "width": 140 },
    { "id": "slug", "label": "Pattern", "width": "flex" },
    { "id": "sev", "label": "Sev", "width": 60, "align": "right" }
  ],
  "rows": [
    { "ts": "2026-05-14 16:10", "slug": "staging-mistake", "sev": "S3",
      "row_actions": [
        { "label": "Open RCA", "command": "atone.open-rca",
          "args": { "rca_id": "mist-20260514-1610" } }
      ] }
  ],
  "empty": "No events yet.",
  "truncated_at": 100,
  "has_more": false
}
```

`row_actions` is an array (multi-action rows supported — fixes V1 spec's
single-chip limit). Commands referenced must exist in the plugin's
`contributes.commands` (or be host-built-in commands like `host.openFile`).

### 6.3 `schedule`

```jsonc
{
  "kind": "schedule",
  "items": [
    { "id": "atone-consolidate", "source": "launchd",
      "when": "Mon/Wed/Fri/Sun 09:00",
      "next_run": "2026-05-17T09:00:00Z",
      "command": "bash ~/.claude/scripts/atone-consolidate.sh",
      "enabled": true,
      "log_path": "~/.claude/atone/derived/_consolidate.log" }
  ]
}
```

Enable/disable toggle deferred (V1.1+). Read-only for now.

### 6.4 `assets`

```jsonc
{
  "kind": "assets",
  "items": [
    { "path": "~/.claude/assets/reports/.../BUILD.md",
      "label": "atone system BUILD doc",
      "size_bytes": 38421,
      "mtime": "2026-05-14T16:10:00Z",
      "open_with": "default" }
  ]
}
```

`open_with`: `default` (shells out to `open`) | `browser` | `vscode` | `terminal`.

### 6.5 `log`

```jsonc
{
  "kind": "log",
  "label": "Last consolidate run",
  "source": "fetch:tail-log consolidate 80"
}
```

Source output is plain text, not JSON. Rendered monospace. Ring-buffered
on the host side at 10k lines / 1 MB.

### 6.6 Action output (transient log pane)

When a command runs, its stdout/stderr streams into a transient `log` pane
that appears below the panes. Same 10k-lines/1 MB cap. Disappears when the
user dismisses or after 5 minutes.

### 6.7 Pane kind extension policy (the trade-off)

Five kinds (summary, table, schedule, assets, log) cover the common case.
For things outside the common case there are **two escape hatches**, each
with a clear trade-off:

**Option A — request a new pane kind to be added to the host.** The host
gains a primitive every plugin can use. Cost: host change required, takes
a release cycle, schema-versioned. When to choose: the pattern repeats
across plugins (e.g., `gauge` for progress bars surfaces in rate-limit AND
disk-usage AND token-budget). Filing a request implies "this should be
shared."

**Option B — use a custom view.** A pane declares `kind: "custom"` with a
`source: "native:<method>"`. The plugin returns a SwiftUI `View` and the
host wraps it in a standard pane chrome (title, refresh, error overlay).
Cost: only native plugins can do this (script plugins are constrained to
declarative kinds). The plugin loses host-provided affordances — palette
auto-tinting, theme-aware borders, accessibility hooks — that come for
free with standard kinds. When to choose: search-as-you-type tables,
hover-affordance lists, anything genuinely visually unique.

**Default position:** most plugins use standard kinds. Custom views are
for the ~10% of cases where standard kinds genuinely don't fit. If you
find yourself reaching for custom view for the second time, consider
filing Option A instead — it's probably a new primitive.

The standard library grows over time. New kinds are additive (don't bump
manifest version). Old plugins keep working.

---

## 7. Native plugin Swift protocol

Native plugins implement this protocol; the host calls into them directly,
no JSON round-trip.

```swift
public protocol Plugin {
    /// The manifest's `id` field. Must match.
    static var id: String { get }

    /// Called once at host startup if any of the plugin's surfaces are
    /// active, or when activated lazily.
    func activate(host: HostContext) async throws

    /// Called when plugin is disabled or host is shutting down.
    func deactivate() async throws

    /// Returns rendered content for a contribution. Called per refresh,
    /// per surface activation, per event-driven re-render. Must be
    /// idempotent and fast (<16 ms target for cached data).
    func render(_ contribution: ContributionRef) async throws -> PaneContent

    /// Command dispatch. Args come from the command site (row action,
    /// menubar click, etc.). Output streams to the action log pane.
    func runCommand(_ id: String, args: [String: Any]) async throws -> CommandResult

    /// Event handler dispatch (only called for events the plugin subscribed
    /// to in manifest).
    func handleEvent(_ event: BusEvent) async throws
}

public struct HostContext {
    public let bus: EventBus            // publish / subscribe
    public let settings: SettingsAPI    // read this plugin's settings
    public let dataFeeds: HostFeeds     // read host-published shared data
    public let palette: PaletteStore    // tokenized colors
    public let logger: HostLogger
}
```

Native plugins register themselves at compile time via a `@PluginRegister`
macro (or simpler: a static `register()` call in `main.swift` of the host).

The renderer for a `native:<method>` source calls
`plugin.render(ContributionRef("dashboard.pane.atone-main"))` and gets a
`PaneContent` enum back (which matches the same five pane-kind cases
script plugins emit as JSON). Same downstream renderer.

---

## 8. Script plugin contract

Script plugins implement two executables (both optional but at least one
required):

### 8.1 `fetch.sh <source-tokens...>`

Invoked by the host with the `source: "fetch:<args>"` tokens as argv.
Examples:
- `./fetch.sh summary` — produces `summary` pane JSON for the source
  `"fetch:summary"`
- `./fetch.sh events --recent 20` — produces table JSON for
  `"fetch:events --recent 20"`

Contract:
- Run with `cwd = plugin directory`.
- Inherits user environment + `CLAUDE_PLUGIN_*` env vars set by host:
  - `CLAUDE_PLUGIN_ID` — the plugin's id
  - `CLAUDE_PLUGIN_SETTINGS` — path to its settings JSON file
  - `CLAUDE_PLUGIN_CACHE_DIR` — `~/Library/Application Support/.../cache/<id>/`
  - `CLAUDE_HOST_VERSION` — for engines-range conditional logic
- Stdout MUST be valid JSON conforming to the relevant pane schema.
- Exit non-zero → pane renders error state with stderr tail.
- Stderr is captured but not displayed by default (visible in Plugin Health).

### 8.2 `actions.sh <command-id> [args...]`

Invoked when a `commands` entry with `exec.kind: "script"` fires. Same
environment. Stdout streams to the action log pane in real time. Exit
status determines success badge.

### 8.3 Event handlers

Script plugins specify `handler: "./path/to/script"` in `event.subscriptions`.
Event payload arrives on stdin as JSON, one event per invocation. Same env
vars set. Handlers are invoked in their own process; host enforces
debounce + spawn-rate caps.

---

## 9. Resource budgets

Two-tier breach strategy:

| Resource | Soft (warn + degrade) | Hard (kill + auto-disable) |
|---|---|---|
| Fetch wall-clock | 1.5 s (SIGTERM) | 5 s (SIGKILL after SIGTERM) |
| Fetch rate | 6 / min sliding window | 12 / min → auto-disable plugin |
| Payload bytes | 256 KB | 2 MB |
| Concurrent fetches (per host) | 4 | 8 → queue, never spawn beyond |
| Background-active surfaces (per host) | 10 | 25 → new ones default-off |
| Plugin native CPU | 5 % sustained 30 s | 20 % sustained 30 s → log + warn |
| Native RSS delta | 50 MB | 200 MB → log + warn |

**What's actually enforced vs measured:**
- Wall-clock + rate + payload + concurrent fetches + background-surface cap:
  **enforced** (host refuses to spawn / kills / degrades).
- CPU + RSS: **measured and surfaced** in Plugin Manager. Not enforced
  (macOS doesn't expose easy per-process CPU limiting without
  `taskpolicy(8)`, which is best-effort). Documented as
  "advisory ceiling, exceeding triggers warning, not auto-disable".

Budgets are overridable per-plugin in manifest `limits` (within global
caps). A plugin that legitimately needs longer fetches sets
`fetch_timeout_ms: 5000` and gets a "slow plugin" badge in Plugin Manager.

---

## 10. Lifecycle

```
        ┌────────────┐  manifest parses
        │ DISCOVERED │  ───────────────►
        └─────┬──────┘
              │ activation rule fires (onStartup, onSurface, onCommand, onEvent)
              ▼
        ┌────────────┐  activate() returns
        │  ACTIVE    │  ◄──────────────►  fetch / render / event-handle
        └─────┬──────┘
              │ user disables OR host shutdown OR auto-disable on breach
              ▼
        ┌────────────┐
        │ DEACTIVATED│  (manifest still loaded, no work happens)
        └─────┬──────┘
              │ user re-enables OR plugin removed
              ▼
        ┌────────────┐
        │  REMOVED   │  (manifest unloaded, state preserved)
        └────────────┘
```

**Hot-reload** (V1 of V2):
- Manifest change → host re-parses + re-validates. If only `contributes`
  changed, contributions update in place. If `exec` or `engines` changed,
  plugin is fully reloaded (deactivate → re-activate).
- `fetch.sh` / `actions.sh` change → no host action; next invocation uses
  the new file.
- Native `Plugin.swift` change → requires host rebuild + restart. **Not
  hot-reloadable.** (Native plugins are compiled into the host binary.)

**Atomic-rename writes** required for manifest edits. Host watches
`manifest.json` files specifically, debounced 1 second to avoid editor-
save flicker.

---

## 11. Plugin Manager UI (the introspection surface)

Lives in the host shell, not as a plugin. (It's the kernel's reflection
of its own state.) A dedicated tab + entry in the menubar dropdown.

### 11.1 Layout

```
┌─ Plugins ──────────────────────────────────────────────────────────┐
│                                                                    │
│  ● Atone           Healthy · fetched 3s ago        [⚙][⏸][🗑]      │
│  ● Live            Native · cached                  [⚙][⏸][🗑]      │
│  ● Rate Limit      Native · publishing rate-limit.tick [⚙][⏸][🗑] │
│  ⚠ Scheduled       1 pane errored · 12s ago        [⚙][⏸][🗑]      │
│  ⏸ Proposals       Disabled                        [⚙][▶][🗑]      │
│                                                                    │
│  ─ Selected: Scheduled ─────────────────────────────────────────── │
│  ├─ Path:    ~/.claude/widgets/scheduled/                          │
│  ├─ Version: 0.1.0    Engines: ^2.0.0    Active since: 2m ago      │
│  ├─ Surfaces (declared):                                           │
│  │   ✓ Dashboard pane (always-on for declared)                    │
│  │   ☐ Menubar item   (declared, surface stubbed in V1)           │
│  ├─ Required tools:                                                │
│  │   ✓ jq      ✓ flock    ✗ launchctl-helper (missing)            │
│  ├─ Recent fetches:                                                │
│  │   schedule  ←  238 ms  ✓   16:14:02                            │
│  │   schedule  ←  ERROR  exit 1 — see log                          │
│  │   schedule  ←  241 ms  ✓   16:13:32                            │
│  ├─ Resource:                                                      │
│  │   spawns/min: 2.0   p95 latency: 245 ms   payload max: 12 KB    │
│  │   approx CPU: 0.4 %  RSS delta: 1.2 MB                          │
│  └─ [Open log]  [Reveal in Finder]  [Force refresh]  [Copy error]  │
│                                                                    │
│  ─ Core ────────────────────────────────────────────────────────── │
│  Host:       CPU 1.1 %   RSS 84 MB   60 fps                        │
│  Event bus:  142 events/min · 7 topics · 11 subscriptions          │
│  Registry:   12 plugins (8 active, 1 errored, 3 disabled)          │
│                                                                    │
│  [+ Install from folder]  [+ Install from Git]  [Panic disable all]│
└────────────────────────────────────────────────────────────────────┘
```

### 11.2 What Plugin Manager covers

- Master enable/disable per plugin (instant, runtime).
- Per-surface opt-in for background-active surfaces (badge, menubar,
  notification, floater).
- Health status with last error.
- Resource stats (per-plugin and core).
- Tool-dependency check.
- Direct file actions (open log, reveal in Finder, force-refresh).
- Install / remove / reveal source.
- Panic disable for emergency.

### 11.3 Resource sampler (the stats page)

Background-queue sampler runs every 5 s:
- For each native plugin: read `task_info` for the host's own process
  attribution by activity (best-effort).
- For each script plugin: aggregate `Process` wall-clock + payload size
  over a sliding 60-s window.
- Event bus: count events / min, subscriptions per topic.
- Host: standard `proc_pidinfo` for self.

Displayed live in Plugin Manager; historical data ring-buffered
(last 60 minutes, 5-s granularity) for spotting drift.

---

## 12. Error model

All host↔plugin operations return an `OperationResult`:

```jsonc
{ "ok": true, "value": ..., "elapsed_ms": 42, "warnings": [] }
// or
{
  "ok": false,
  "error": {
    "code": "fetch.timeout",          // closed enum, prefixed by stage
    "message": "fetch.sh did not respond in 1500ms",
    "stderr_tail": "...",
    "actionable": "Increase limits.fetch_timeout_ms or check fetch.sh perf"
  },
  "elapsed_ms": 1501
}
```

**Closed error code enum** (host renders by code, never by message):

`manifest.invalid` · `manifest.unsupported_envelope` ·
`engines.mismatch` · `requires.missing_tool` · `fetch.timeout` ·
`fetch.hard_killed` · `fetch.exit_nonzero` · `fetch.bad_json` ·
`fetch.schema_violation` · `fetch.payload_too_large` ·
`action.timeout` · `action.exit_nonzero` ·
`event.unknown_topic` · `event.handler_failed` ·
`native.activation_failed` · `native.method_threw` ·
`budget.spawn_rate_exceeded` · `budget.payload_exceeded` ·
`budget.concurrent_exceeded`

Per the project's `rules/error-classification.md`: branching on `code`,
never on `message`. Messages are for humans; codes are for control flow.

Every error has an empty-pane-or-toast visual; users never see a blank
pane without explanation.

---

## 13. Versioning

| Layer | Versioning scheme | Bump triggers |
|---|---|---|
| Manifest envelope | Single integer `manifest_version` | Breaking change to top-level shape |
| Plugin | Semver `version` | Plugin author's choice |
| Host | Semver | New surfaces, new contribution points, new event topics |
| Pane kind schemas | Hosted within manifest envelope | Adding fields is additive (no bump) |
| Event topic payloads | Documented in `docs/event-topics.md` | New required fields = new topic name |

A plugin says "I work on host versions `^2.0.0`" via `engines`. Host
refuses to load on mismatch. This is the **5-year stability mechanism**:
the host can ship 2.0 → 2.7 with new surfaces, new event topics, new
pane fields. Old plugins keep working. When a breaking change is
needed, the host ships 3.0 and plugins update their `engines` range.

---

## 14. Build & registry compilation

V2 uses a Swift Package Manager project. At build time:

1. `build.sh` scans `plugins/*/manifest.json`.
2. For each plugin with `Plugin.swift`: it's added as a Swift source to
   the host build target. (Native plugins compile into the host binary.)
3. For each plugin: its manifest is embedded as a resource (read at
   runtime via `Bundle.module.url(forResource:)`).
4. A generated `BundledPluginRegistry.swift` lists all known plugin ids
   and their Swift types (for native).
5. Host links against `HostKernel` + `HostShell` + all
   `Plugin{<id>}` modules.

At runtime, the host:
1. Reads `BundledPluginRegistry` first (in-binary plugins).
2. Globs `~/.claude/widgets/*/manifest.json` for drop-in script plugins.
3. Merges; conflicts (same `id`) → bundled wins, drop-in logged as
   shadowed.

---

## 15. Migration safety from V1

V1 lives unchanged on `legacy/v1` branch and on `main` branch (both
point to the same commit `4d4ebeb` at V2 fork-time). V2 lives on `v2`
branch in a separate worktree at `~/.claude/widgets/claude-instances-v2`.

**Dual-binary operation:**
- V1 binary keeps its bundle id `dev.claude-instances.menubar` and plist
  `dev.claude-instances.menubar.plist`.
- V2 binary uses bundle id `dev.claude-instances-v2.menubar` and plist
  `dev.claude-instances-v2.menubar.plist`.
- Both can run simultaneously; they show as two separate menu-bar icons
  with distinct icons (V2 uses a subtly different glyph).

**Switch-over criteria** (when to retire V1):
1. Every V1 first-party tab has a V2 native plugin equivalent with
   parity (defined per-feature in `v2-implementation-plan.md` §6).
2. Two weeks of V2 daily-driver use without falling back to V1.
3. Plugin Manager shows zero error states on plugins the user actively
   uses.

Until all three: V1 is the daily driver, V2 is for testing.

**Worst-case recovery:** `launchctl unload ~/Library/LaunchAgents/dev.
claude-instances-v2.menubar.plist`. V1 keeps working untouched.

---

## 16. Logging

A unified, tagged, long-lived logging system. Every plugin gets the same
structured logger. Host writes its own logs through the same machinery.
The result is one place to look when the platform misbehaves — including
"are these resource limits reasonable" questions.

### 16.1 Storage

```
~/Library/Application Support/dev.claude-instances-v2/logs/
  host.log                       (host-emitted; 10 MB ring buffer)
  plugins/<plugin-id>.log        (per-plugin; 5 MB ring buffer each)
  events.jsonl                   (structured event log; 50 MB ring)
```

Ring-buffered means: when a file hits its cap, the oldest 10% is dropped
and the file truncates. No log rotation cron. No multi-file segments.

### 16.2 Log entry shape

Every log entry is one line, JSON:

```jsonc
{
  "ts": "2026-05-15T16:14:02.183Z",
  "src": "atone",                  // "host" or plugin-id
  "level": "info",                 // debug | info | warn | error
  "tag": "fetch",                  // free-form category (see §16.3)
  "msg": "fetch summary done in 87 ms (cached, no-op publish)",
  "ctx": {                         // optional structured context
    "elapsed_ms": 87,
    "payload_bytes": 4231,
    "cache_hit": true
  }
}
```

Plain `.log` files (`host.log`, `plugins/<id>.log`) contain a
human-readable rendering of these entries; the canonical structured
record is in `events.jsonl`.

### 16.3 Tags (closed-ish enum)

Tags are documented but not strictly enforced. Standard tags:

- `lifecycle` — plugin activate/deactivate, host startup/shutdown
- `fetch` — script plugin fetches (start, end, error)
- `render` — pane render dispatch
- `event` — event bus emit / handler dispatch
- `command` — command execution
- `budget` — budget warnings / breaches (auto-disables, throttles)
- `manifest` — manifest validation results
- `surface` — surface activation / deactivation
- `error` — anything that produced a user-facing error
- `debug` — opt-in verbose tracing (off by default)

Plugin authors can add their own tags by writing them. Linting in
`claude-widget validate` warns on unknown tags.

### 16.4 What gets logged by default

**Always (info+):**
- Plugin lifecycle transitions
- Manifest validation failures
- Budget breaches (soft + hard)
- Command invocations + their outcomes
- Fetches with latency > soft timeout
- Errors from any boundary
- Host startup / shutdown
- Surface activations

**Opt-in (debug):** all fetches, all renders, all event deliveries, all
hot-reload triggers. Enabled per plugin via Settings ("Verbose logging
for this plugin") or globally via the `CLAUDE_INSTANCES_DEBUG=1` env var
at host launch.

### 16.5 Logger API

**Native plugins** get `host.logger` in `HostContext`:

```swift
public protocol HostLogger {
    func debug(_ tag: String, _ msg: String, _ ctx: [String: Any]?)
    func info (_ tag: String, _ msg: String, _ ctx: [String: Any]?)
    func warn (_ tag: String, _ msg: String, _ ctx: [String: Any]?)
    func error(_ tag: String, _ msg: String, _ ctx: [String: Any]?)
}
```

The logger automatically stamps `src` with the plugin's id. No
cross-plugin log pollution.

**Script plugins** get two channels:
- Anything written to stderr is captured + tagged `src: <plugin-id>`,
  `level: warn` (heuristic; lines starting with `info:` `warn:` `error:`
  `debug:` get parsed for level).
- A dedicated file descriptor `CLAUDE_PLUGIN_LOG_FD=3` accepts JSONL
  entries directly (no parsing, structured logging).

Example in script:
```sh
echo "fetched 12 events in $elapsed ms" >&2                  # tagged warn
echo "{\"level\":\"info\",\"tag\":\"fetch\",\"msg\":\"ok\"}" >&3   # structured
```

### 16.6 Log viewer

Plugin Manager → plugin detail → "Open log" opens the per-plugin log in
the host's built-in log viewer (mono, syntax-highlighted by level,
filterable by tag, follow-tail mode).

A separate "Core" view shows `host.log`. The structured `events.jsonl`
is accessible via "Export log" → downloads the JSONL for external
analysis (jq, ripgrep, etc.).

### 16.7 Why this lives in the host, not in plugins

The user's stated goal — "general long lived logging for basic things to
diagnose long term issues" — implies one consistent format, one location,
one retention policy. If each plugin rolled its own, "look at the logs"
becomes "look at 12 logs in 12 formats in 12 locations." The unified
logger eliminates that.

It also lets the host attribute resource breaches to the right plugin
automatically — every budget warning is a log entry tagged with the
breaching plugin's id, so the answer to "why did my menu-bar app eat
2 GB last night" is one grep.

---

## 17. Glossary

- **Bundled plugin** — Native or script plugin shipped inside the host
  source tree, distributed with the binary.
- **Drop-in plugin** — Script plugin in `~/.claude/widgets/<id>/`, not
  in the source tree. Detected at runtime.
- **Surface** — A place in the UI a contribution renders. Plural because
  one plugin can fill several.
- **Source token** — The `"fetch:summary"` / `"event:atone.tick"` /
  `"native:render"` string identifying where a pane's data comes from.
- **Activation** — The moment a plugin's `activate()` is called (lazy
  by default; eager via `["onStartup"]`).
- **Background-active surface** — A surface that consumes resources
  while the dashboard is closed (badge, menubar, notification).
- **Lazy surface** — A surface that only consumes resources when the
  user can see it (dashboard pane, floater).

---

*Open questions and decisions are tracked in `v2-implementation-plan.md` §10.*
