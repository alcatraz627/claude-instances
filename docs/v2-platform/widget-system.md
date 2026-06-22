# Widget System — spec

> **Status:** spec, not yet built · **Date:** 2026-05-15
> **Companion:** [`dashboard-kit.md`](./dashboard-kit.md) — the reusable scaffolding this builds on.
>
> This doc tells you **what to build, in what order, with what contracts.**
> A "widget" is a self-describing plugin that surfaces some local-Claude
> infrastructure (atone, hooks, plugins, scheduled jobs, …) inside the
> dashboard without the dashboard knowing anything about that
> infrastructure specifically.

---

## 0. Goals

A widget is **a manifest file + a fetch script + an actions script**, lives
outside the dashboard repo, and renders inside the dashboard via a fixed set
of generic pane kinds. The dashboard is a dumb host. The widget owns its data.

**Why:** today, every new piece of Claude infra (atone, propose, dream,
weekly-todo) would mean a new Swift tab. That doesn't scale and forces every
add to ship through the menu-bar binary. Plugin architecture decouples them:
add a widget by dropping a folder under `~/.claude/widgets/<name>/`.

**Non-goals:**

- Sandboxing or capability gating beyond "host invokes a script you wrote."
- Cross-machine sync. Widgets live in `~/.claude/`, which is git-tracked by
  the user, not by the dashboard.
- Two-way live data binding. Widgets are *pull* + *action-triggered re-pull*.
  No diffing, no patches.
- Replacing the existing tabs (Overview, Live, History, …). Widgets are an
  **additional** tab whose sidebar lists registered widgets.

---

## 1. Architecture

```
┌──────────────── DASHBOARD (Swift host) ─────────────────────┐
│                                                              │
│  Tabs: Overview · Live · … · Settings · About               │
│        + NEW: Widgets   (sidebar lists registered widgets)  │
│                                                              │
│  WidgetRegistry  ─ globs ~/.claude/widgets/*/manifest.json  │
│  WidgetTabView   ─ renders a single widget                  │
│  PaneRenderer    ─ switches on pane.kind, draws SwiftUI     │
│  ActionRunner    ─ Process(cmd) + streams stdout to console │
└──────────┬───────────────────────────────────────────────────┘
           │ Process(fetch.sh <pane-source-args>)
           │ Process(actions.sh <action-id>)
           ▼
┌──────────────── WIDGET (plugin, any executable) ────────────┐
│  ~/.claude/widgets/<id>/                                     │
│    manifest.json     ← declarative contract                  │
│    fetch.sh          ← reads data, prints JSON to stdout     │
│    actions.sh        ← side-effects; prints log to stdout    │
│    (any other files the widget needs)                        │
└──────────────────────────────────────────────────────────────┘
```

**One-line architectural rule:**
*The host renders pane kinds. The widget produces pane payloads. Neither
knows the other's domain.*

---

## 2. Filesystem layout

| Path | Owner | Purpose |
|------|-------|---------|
| `~/.claude/widgets/` | user | Registry root. Globbed by host on launch + on demand. |
| `~/.claude/widgets/<id>/manifest.json` | widget | Required. Declares title, icon, panes, actions. |
| `~/.claude/widgets/<id>/fetch.sh` | widget | Required. Executable. Reads-only contract. |
| `~/.claude/widgets/<id>/actions.sh` | widget | Optional. Executable. Side effects allowed. |
| `~/.claude/widgets/<id>/*` | widget | Anything else the widget wants (templates, helpers). |
| `~/.claude/widgets/.disabled` | user | Optional. Newline-separated list of widget IDs to hide without deleting. |

Discovery is purely filesystem: a widget exists iff its manifest parses. No
central registry file, no install command.

---

## 3. Manifest contract

`manifest.json` is the **only** file the host parses directly. All other
data flows through `fetch.sh` / `actions.sh` stdout.

### 3.1 Schema (v1)

```jsonc
{
  "schema_version": 1,            // integer; host refuses unknown versions
  "id": "atone",                  // matches dir name, used as stable key
  "title": "Atone — mistakes",    // shown in sidebar + tab header
  "subtitle": "Mistake tracking & RCAs",  // optional, dim text under title
  "icon": "exclamationmark.bubble",       // SF Symbol name; fallback "puzzlepiece"
  "accent": "orange",             // optional Tailwind-ish name → PaletteToken
  "refresh_seconds": 30,          // default for panes that don't override
  "panes": [ /* see §4 */ ],
  "actions": [ /* see §5 */ ]
}
```

### 3.2 Required vs optional

Required: `schema_version`, `id`, `title`, `panes` (≥1).
Everything else is optional with sensible defaults.

### 3.3 Host validation

On load, host validates: schema_version known, id matches dirname, each pane
has a known `kind` + a `source`, each action has unique `id`. **Invalid
manifests are skipped with a console warning, not raised.** A broken widget
must never break the host.

---

## 4. Pane kinds (the data contract)

There are **five** pane kinds. Each defines a payload schema. `fetch.sh` is
invoked with the pane's `source` string as args; stdout MUST be valid JSON
matching that kind's schema. Anything else → error pane.

### 4.1 `summary` — key-value tiles

```jsonc
{
  "kind": "summary",
  "tiles": [
    { "label": "Events recorded", "value": "147", "trend": "+3 this week" },
    { "label": "Top pattern",     "value": "git-add-shape", "badge": "S3" },
    { "label": "Last consolidate","value": "2026-05-14 09:00", "tone": "ok" }
  ]
}
```

UI: grid of `StatCard`-shaped tiles (reuse existing kit component). Tones:
`ok` / `warn` / `error` / `dim` / `none`. Trend is free text, dim and small.

### 4.2 `table` — rows + columns

```jsonc
{
  "kind": "table",
  "columns": [
    { "id": "ts",   "label": "When",     "width": 140 },
    { "id": "slug", "label": "Pattern",  "width": "flex" },
    { "id": "sev",  "label": "Sev",      "width": 60, "align": "right" }
  ],
  "rows": [
    { "ts": "2026-05-14 16:10", "slug": "staging-mistake", "sev": "S3",
      "row_action": { "label": "Open RCA", "cmd_action_id": "open-rca", "args": ["mist-20260514-…"] } }
  ],
  "empty": "No events yet."
}
```

UI: header row + scrollable body. `row_action`, if present, becomes a chip
button on the right edge. `cmd_action_id` MUST match one of the manifest's
top-level actions. Args are appended to that action's command.

### 4.3 `schedule` — cron + launchd unified

```jsonc
{
  "kind": "schedule",
  "items": [
    { "id": "atone-consolidate",
      "source": "launchd",                // "cron" or "launchd"
      "when": "Mon/Wed/Fri/Sun 09:00",   // human-readable
      "next_run": "2026-05-17T09:00:00Z", // ISO; optional, computed if absent
      "command": "bash ~/.claude/scripts/atone-consolidate.sh",
      "enabled": true,
      "log_path": "~/.claude/atone/derived/_consolidate.log"  // optional
    }
  ]
}
```

UI: list of rows with a green/grey dot, the human-readable `when`, the
command in mono dim, and (if `log_path` set) a "View log" chip that opens
the file. **Enable/disable toggle is deferred until v2** — read-only first.

### 4.4 `assets` — files on disk

```jsonc
{
  "kind": "assets",
  "items": [
    { "path": "~/.claude/assets/reports/20260514-1610-atone-system-design/BUILD.md",
      "label": "atone system BUILD doc",
      "size_bytes": 38421,
      "mtime": "2026-05-14T16:10:00Z",
      "open_with": "default"  // "default" | "browser" | "vscode"
    }
  ]
}
```

UI: list of rows: label, dim path under it, size + relative mtime on the
right, a single "Open" button. `open_with: default` shells out to `open <path>`.

### 4.5 `log` — append-only stream (action output)

This pane has **no fetch**. It is reserved for the host: when the user runs
an action, its stdout is streamed into a `log` pane attached to the widget.
A widget MAY include a static `log` pane to surface a tail of an existing
log file:

```jsonc
{
  "kind": "log",
  "label": "Recent consolidate runs",
  "source": "fetch.sh tail-log consolidate 80"  // 80-line tail, monospaced
}
```

Output of `source` is treated as plain text, not JSON.

---

## 5. Actions

```jsonc
"actions": [
  { "id": "consolidate",
    "label": "Run consolidate now",
    "cmd": ["bash", "~/.claude/scripts/atone-consolidate.sh"],
    "confirm": "Re-build derived views from raw events?",
    "destructive": false }
]
```

- `cmd` is an argv array, not a shell string. Host runs it with `Process`,
  no shell interpolation. Row-action `args` are appended.
- `confirm`, if present, gates the run with an alert.
- `destructive: true` paints the button red.
- All action stdout/stderr is appended to a transient `log` pane shown
  below the panes when an action is in flight or recently completed.
- Actions run with PWD = the widget's directory and inherit the user's env.

**No background actions in v1.** A running action blocks the widget's
action bar until it exits or 60s elapses (host kills with SIGTERM, then
SIGKILL after 5s).

---

## 6. Fetch protocol

For every non-`log` pane on widget activation (and every `refresh_seconds`
when the widget is visible), the host runs:

```
cd ~/.claude/widgets/<id>
./fetch.sh <pane.source-as-shell-words>
```

- Timeout: 10s. Past that, pane shows "stale (fetch timed out)" and keeps
  the previous payload.
- Exit non-zero: pane shows "error (exit N)" with stderr in a disclosure.
- Stdout not valid JSON: pane shows "error (bad JSON)" with first 500
  chars in a disclosure.
- A widget's panes are fetched **in parallel** but rendered in manifest order.

**Caching:** the host does not cache between launches. A widget that wants
to be cheap should cache internally (e.g., write to `~/.claude/widgets/<id>/.cache/`).

---

## 7. UI contract (host side)

```
┌─────────────────────────────────────────────────────────────┐
│ Sidebar      │  Widget header: title · subtitle · action bar │
│  ▸ atone     │ ─────────────────────────────────────────────│
│    propose   │                                               │
│    dream     │  Pane 1 (summary)                            │
│    schedule  │  ┌──────────────┐ ┌──────────────┐           │
│    hooks     │  │ tile         │ │ tile         │           │
│              │  └──────────────┘ └──────────────┘           │
│              │                                               │
│              │  Pane 2 (table)                              │
│              │  ┌─ When ──── Pattern ───────── Sev ─┐       │
│              │  │ 16:10     staging-mistake   S3   │       │
│              │  └──────────────────────────────────┘        │
│              │                                               │
│              │  (transient action log pane appears here)    │
└─────────────────────────────────────────────────────────────┘
```

- Sidebar is a list of widget titles + icons, accent-tinted.
- Header has the title, optional subtitle, and a row of action buttons.
- Panes render top-to-bottom in manifest order, no tabs *within* a widget.
- Every pane has a tiny ↻ refresh icon in its top-right and a relative
  "fetched 12s ago" timestamp. Refresh = re-run that pane's `fetch.sh`.
- Empty pane payloads render the `empty` string (table) or a dim "no items".
- All colors come from `PaletteStore` tokens — widgets never specify hex.

---

## 8. Lifecycle

1. **Boot:** dashboard glob `~/.claude/widgets/*/manifest.json`, parse,
   build the sidebar. Skip `.disabled` entries.
2. **Select:** user clicks a widget. Host triggers parallel fetch for all
   panes. Panes render as their fetches return.
3. **Tick:** while a widget is selected, host re-fetches each pane on its
   `refresh_seconds` (default from manifest, override per-pane).
4. **Action:** user clicks an action. Host shows confirm (if set), runs
   `cmd`, streams stdout into a transient `log` pane. On exit, host
   triggers a re-fetch of all panes to pick up side effects.
5. **Switch:** user picks another widget. Previous widget's timers stop.

The widget process tree never persists between selections. Every fetch is
a fresh `Process`.

---

## 9. Versioning

- `schema_version` is a single integer on the manifest.
- v1 supports the five pane kinds above.
- Future kinds (chart, tree, form, etc.) bump to v2. Host falls back to
  "unsupported pane kind" for unknown kinds within a known schema_version.
- The host's max known schema_version is hardcoded in `WidgetRegistry`.
  Newer manifests are skipped with a clear "upgrade dashboard" message.

---

## 10. Security & safety

This is a single-user local tool. There is no sandbox. The host runs
whatever the user puts under `~/.claude/widgets/`. The rules:

- The host never `eval`s or shell-interprets a pane source — args are
  passed argv-style. (Same for actions.)
- `destructive: true` + `confirm` are the only two affordances; the
  widget author is responsible for marking dangerous actions.
- Atone-style kernel-locked raw data must be touched only via sanctioned
  scripts — the widget's `fetch.sh` should `cat events.jsonl` (read-only)
  but never `chflags` or attempt mutation. Host enforces nothing here;
  this is convention.

---

## 11. Worked example — atone widget

**Files:**

```
~/.claude/widgets/atone/
  manifest.json
  fetch.sh
  actions.sh
```

**`manifest.json`:**

```json
{
  "schema_version": 1,
  "id": "atone",
  "title": "Atone",
  "subtitle": "Mistake tracking & RCAs",
  "icon": "exclamationmark.bubble",
  "accent": "orange",
  "refresh_seconds": 60,
  "panes": [
    { "kind": "summary",  "source": "summary" },
    { "kind": "table",    "source": "events --recent 20" },
    { "kind": "schedule", "source": "schedule" },
    { "kind": "assets",   "source": "assets" },
    { "kind": "log",      "label": "Last consolidate run",
                          "source": "tail-log consolidate 80",
                          "refresh_seconds": 300 }
  ],
  "actions": [
    { "id": "consolidate", "label": "Run consolidate now",
      "cmd": ["bash", "~/.claude/scripts/atone-consolidate.sh"],
      "confirm": "Re-build derived views from raw events?" },
    { "id": "snapshot", "label": "Take snapshot",
      "cmd": ["bash", "~/.claude/scripts/atone-snapshot.sh"] },
    { "id": "open-rca", "label": "Open RCA",
      "cmd": ["bash", "-c", "open ~/.claude/atone/rca/\"$1\".md"] }
  ]
}
```

**`fetch.sh summary`** prints `{kind:"summary", tiles:[…]}` derived from
`events.jsonl` row count + `derived/_meta.json` last-consolidate timestamp.

**`fetch.sh schedule`** filters the unified schedule (provided by a separate
`lib/schedule.sh` helper in step 1 of the build sequence) for atone-related
launchd jobs.

**`fetch.sh assets`** lists files under `~/.claude/assets/reports/` whose
name contains "atone".

**`actions.sh`** is the dispatch table — `consolidate`, `snapshot`,
`open-rca <id>`. Each forwards to the canonical script under
`~/.claude/scripts/`.

---

## 12. What's deliberately NOT in v1

- **Enable/disable** for scheduled items inside `schedule` panes. Read-only
  first; toggle in v2 once we know how to invoke `launchctl unload` /
  crontab edits safely.
- **Widget settings** persisted per-widget. If a widget needs config, it
  reads `~/.claude/widgets/<id>/config.json` itself.
- **Cross-widget communication.** Widgets can't read each other's state
  through the host.
- **Streaming fetch.** Every fetch is a single JSON document. Long-running
  data (e.g., a tailing log) uses an action that prints to the transient
  log pane.
- **Inline forms.** No text inputs inside panes in v1. If a widget needs
  input, it ships an action that opens an external editor or runs a TUI.

---

## 13. Build sequence (recap, this doc's contract drives it)

1. `lib/schedule.sh` → unified cron+launchd JSON. Pure shell; testable
   without Swift.
2. `WidgetManifest` + `WidgetPane` + `WidgetAction` Codable types in
   DashboardKit. Decoder + validator. Tests for each pane kind's payload.
3. `WidgetRegistry` glob + load. Sidebar entries appear.
4. `WidgetTabView` + `PaneRenderer` for the five kinds. Render against
   hand-rolled JSON fixtures before any widget exists.
5. `ActionRunner` + transient log pane.
6. Drop the `atone/` widget folder. End-to-end smoke: open dashboard,
   pick Atone in sidebar, see five panes, click an action, watch log.
7. (Stretch) `propose`, `dream`, `hooks` widgets follow the same pattern.

Steps 1+2 are independently shippable: a unified `schedule` JSON is
useful on its own, even before the host can render it.
