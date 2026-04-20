<div align="center">
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" width="128" height="128">
  <!-- Menu bar background -->
  <rect x="0" y="0" width="64" height="8" fill="#1a1a2e"/>
  <rect x="0" y="8" width="64" height="56" fill="#16213e"/>
  <!-- Claude logo pixel art (coral) -->
  <rect x="4" y="2" width="4" height="4" fill="#D97757"/>
  <!-- Instance count badge -->
  <rect x="10" y="2" width="4" height="4" fill="#E8A84C"/>
  <!-- Dropdown menu -->
  <rect x="4" y="12" width="56" height="4" fill="#0f3460"/>
  <rect x="4" y="18" width="56" height="4" fill="#0f3460"/>
  <rect x="4" y="24" width="56" height="4" fill="#0f3460"/>
  <!-- Model badges -->
  <rect x="6" y="13" width="2" height="2" fill="#F2A633"/>
  <rect x="6" y="19" width="2" height="2" fill="#6194FF"/>
  <rect x="6" y="25" width="2" height="2" fill="#4DD1B8"/>
  <!-- Rate limit bar -->
  <rect x="4" y="32" width="56" height="4" fill="#1a1a2e"/>
  <rect x="4" y="32" width="32" height="4" fill="#4CAF50"/>
  <!-- Dashboard panel -->
  <rect x="4" y="40" width="12" height="20" fill="#0f3460"/>
  <rect x="18" y="40" width="42" height="20" fill="#1a1a2e"/>
  <!-- Sidebar dots -->
  <rect x="6" y="42" width="2" height="2" fill="#6194FF"/>
  <rect x="6" y="46" width="2" height="2" fill="#4DD1B8"/>
  <rect x="6" y="50" width="2" height="2" fill="#F2A633"/>
  <rect x="6" y="54" width="2" height="2" fill="#E86053"/>
  <!-- Dashboard content lines -->
  <rect x="20" y="42" width="24" height="2" fill="#333"/>
  <rect x="20" y="46" width="36" height="2" fill="#333"/>
  <rect x="20" y="50" width="20" height="2" fill="#333"/>
  <rect x="20" y="54" width="30" height="2" fill="#333"/>
</svg>
</div>

<h1 align="center">Claude Instances</h1>

<p align="center">
  Native macOS menu bar app for monitoring and managing concurrent Claude Code sessions.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS_13+-black" alt="Platform">
  <img src="https://img.shields.io/badge/language-Swift_5.9-F05138" alt="Swift">
  <img src="https://img.shields.io/badge/build-swiftc_(no_Xcode)-blue" alt="Build">
  <img src="https://img.shields.io/badge/lines-~2340-informational" alt="Lines">
</p>

---

## About

A native macOS menu bar widget that gives you instant visibility into all your running
Claude Code sessions. See live instance count, token usage, rate limits, and session
history at a glance. Click any instance to focus its Ghostty terminal tab instantly.
Resume past sessions with a single click.

Built as a single Swift file compiled with `swiftc` — no Xcode project, no external
dependencies, no package managers. Just `bash native/build.sh --install` and it runs
forever via LaunchAgent.

## Quick Start

```bash
# Build, sign, and register as a LaunchAgent (auto-starts on login)
bash native/build.sh --install

# Or just build and run once (no auto-start)
bash native/build.sh
```

The Claude logo appears in your menu bar. Click it to see your running sessions.

## Features

### Menu Bar Icon
- Static coral Claude logo PNG — dims to 50% when no instances are running
- Instance count badge in monospaced font (or `–` when idle)
- Count text turns orange at 75% rate limit, red at 90%
- Shows `⚠ N` when permission requests are pending

### Dropdown Menu (min-width 340pt)
- **Live instances** — model badge (◆ Opus / ● Sonnet / ○ Haiku), project path,
  elapsed time, turns, output tokens. Click to focus the Ghostty tab.
  Secondary row: CPU%, token speed (tok/s), cost velocity ($/min).
  Focus file shown with 📄 when available.
  Right-arrow submenu: View Transcript, Copy PID, Terminate.
- **Rate limits** — 16-char `▓░` progress bars with 4-tier color thresholds
  (green <50% → yellow 50-75% → orange 75-90% → red >90%)
- **Recent events** — per-type Unicode symbols: ▶ Started, ■ Stopped,
  ⚠ Permission, ⟳ Compacted — each with semantic color
- **Session history** — last 6 sessions, clickable to resume via `claude --resume`
  in a new Ghostty tab
- **Actions** — New Session (⌘N), Dashboard (⌘D), Refresh (⌘R), Terminate All, Quit

### Native Dashboard (SwiftUI)
A floating `NSPanel` with `NavigationSplitView` sidebar and `.ultraThinMaterial`:

| Tab | Description |
|-----|-------------|
| **Overview** | Stat cards (live count, total turns, memory, cache), rate limit bars |
| **Live** | Instance cards with full metrics, hover-reveal action buttons, transcript viewer |
| **History** | Sortable table (project, model, turns, size, last active) |
| **Events** | Timeline view with `EventBadge` colored dots and event metadata |
| **All Sessions** | Deep scan of ALL past sessions with search, sort, resume, and transcript actions |

## Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│  DATA SOURCES                                                     │
│  scan.sh (JSON)    /tmp/claude-statusline-*    ~/.claude/projects │
└────────┬──────────────────────┬────────────────────────┬─────────┘
         │ 5s timer             │ metrics                │ on-demand
         ▼                      ▼                        ▼
┌──────────────────────────────────────────────────────────────────┐
│  CORE                                                             │
│  BarDelegate ──▶ ScanResult Cache ──▶ DashboardData (@Published) │
└────────┬──────────────────────────────────────────┬──────────────┘
         │ menuNeedsUpdate                          │ SwiftUI binding
         ▼                                          ▼
┌─────────────────────────┐    ┌────────────────────────────────────┐
│  NSMenu Dropdown        │    │  SwiftUI Dashboard (NSPanel)       │
│  • Live instances       │    │  • Overview / Live / History       │
│  • Rate limit bars      │    │  • Events / All Sessions           │
│  • Events + History     │    │  • NavigationSplitView sidebar     │
│  • Actions (⌘N/D/R)    │    │  • Hover-reveal action buttons     │
└─────────┬───────────────┘    └──────────────┬─────────────────────┘
          │ click/action                       │ button action
          ▼                                    ▼
┌──────────────────────────────────────────────────────────────────┐
│  ACTIONS (AppleScript + Process)                                  │
│  focusGhosttyTab()  resumeSession()  terminate()  openTranscript()│
└──────────────────────────────────────────────────────────────────┘
          │                              │
          ▼                              ▼
    Ghostty Terminal              Finder / Chrome
```

### File Structure

```
~/.claude/widgets/claude-instances/
├── native/
│   ├── claude-instances-bar.swift    # Single-file app (~2340 lines)
│   ├── build.sh                      # Compile + install + manage
│   └── .build-info                   # Auto-generated build metadata
├── lib/
│   ├── scan.sh                       # Python scanner → JSON output
│   └── detail.sh                     # Session transcript HTML generator
├── plugin.sh                         # Legacy SwiftBar plugin (kept)
├── render.sh                         # Legacy HTML dashboard renderer
├── dashboard.html                    # Legacy HTML dashboard
├── PLAN.md                           # Design document + implementation record
└── README.md                         # This file
```

### Key Components

| Component | Role |
|-----------|------|
| `BarDelegate` | `NSApplicationDelegate` + `NSMenuDelegate`. Manages status item, menu, timers, action handlers. |
| `ScanResult` | Codable struct decoded from `scan.sh` JSON. Contains live instances, history, events, rate limits. |
| `DashboardController` | Manages the floating `NSPanel`. Creates SwiftUI views via `NSHostingView`. |
| `DashboardData` | `ObservableObject` bridging cached scan data into SwiftUI. Handles on-demand All Sessions scan. |
| `AllSessionsTabView` | Deep filesystem scan of `~/.claude/projects/` — search, sort, resume, view transcripts. |
| `focusGhosttyTab()` | AppleScript bridge — finds and focuses the Ghostty tab matching a working directory. |
| `resumeSession()` | AppleScript — opens a new Ghostty tab, cd's to the project, runs `claude --resume`. |

### Data Models

| Struct | Source | Key Fields |
|--------|--------|------------|
| `LiveInstance` | scan.sh | pid, model, modelFull, cwd, elapsed, turns, inputTokens, outputTokens, sessionId, resumeId, statusline |
| `StatuslineMetrics` | `/tmp/claude-statusline-<pid>` | cpu, mem, rssMb, focusFile, tokSpeed, costVel, walSinceCp, mcpHealthy, mcpDown |
| `SessionHistory` | scan.sh | sessionId, project, model, turns, sizeKb, modified, tokensIn, tokensOut |
| `FullSession` | All Sessions scan | sessionId, project, projectDirName, model, turns, sizeKb, modified, tokensIn, tokensOut, jsonlPath |
| `Event` | scan.sh | event, ts, project, sessionId |
| `RateLimits` | scan.sh | fiveH (pct/used/cap), week (pct/used/cap) |

### Model Colors

| Model | Badge | Color | RGB |
|-------|-------|-------|-----|
| Opus | ◆ | Warm amber/gold | `(0.95, 0.65, 0.20)` |
| Sonnet | ● | Vibrant blue | `(0.38, 0.58, 1.0)` |
| Haiku | ○ | Teal/mint | `(0.30, 0.82, 0.72)` |

## Build Management

```bash
bash native/build.sh              # Compile + launch (replaces running instance)
bash native/build.sh --install    # Compile + register LaunchAgent (auto-start)
bash native/build.sh --uninstall  # Remove LaunchAgent + kill widget
bash native/build.sh --logs       # Tail the debug log
bash native/build.sh --status     # Show running instances + build info
```

### LaunchAgent

When installed via `--install`, the widget registers as a LaunchAgent
(`dev.claude-instances.menubar`) that:
- Starts automatically on login (`RunAtLoad`)
- Restarts on crash (`KeepAlive.SuccessfulExit = false`)
- Logs to `/tmp/claude-instances-bar.log`

### Dedupe

The app kills any existing `claude-instances-bar` processes on startup via `pgrep`/`kill`,
ensuring only one instance runs at a time even if launched manually while the LaunchAgent
is active.

## Dependencies

- **macOS 13+** (Ventura) — for `NavigationSplitView`, `.ultraThinMaterial`
- **Swift 5.9+** — ships with Xcode 15+
- **Ghostty** — for tab focus via AppleScript (falls back to generic activation)
- **Python 3** — used by `scan.sh` and `detail.sh` for JSON generation
- No external packages. No Xcode project. Single-file `swiftc` compilation.

## Troubleshooting

| Problem | Fix |
|---------|-----|
| Two icons in menu bar | Hover over the stale one (macOS clears ghost icons on hover). Or: `bash build.sh --uninstall && bash build.sh --install` |
| Icon not appearing | Check `bash build.sh --status`. If not running, check `/tmp/claude-instances-bar.log` |
| Menu shows "Scanning..." | `scan.sh` may be failing. Test with `bash lib/scan.sh` directly |
| Dashboard won't open | Requires macOS 13+. Check logs for SwiftUI errors |
| "Focus" doesn't switch tabs | Ghostty must have Accessibility permission in System Settings |

## License

MIT
