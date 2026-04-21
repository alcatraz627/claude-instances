<div align="center">
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 320 180" width="480" height="270">
  <defs>
    <linearGradient id="bg" x1="0%" y1="0%" x2="0%" y2="100%">
      <stop offset="0%" style="stop-color:#0f0f1a"/>
      <stop offset="100%" style="stop-color:#1a1a2e"/>
    </linearGradient>
    <linearGradient id="bar" x1="0%" y1="0%" x2="100%" y2="0%">
      <stop offset="0%" style="stop-color:#4CAF50"/>
      <stop offset="60%" style="stop-color:#E8A84C"/>
      <stop offset="100%" style="stop-color:#E86053"/>
    </linearGradient>
  </defs>
  <!-- Background -->
  <rect width="320" height="180" rx="12" fill="url(#bg)"/>
  <!-- macOS menu bar -->
  <rect x="0" y="0" width="320" height="24" rx="12" fill="#1c1c2e"/>
  <rect x="0" y="12" width="320" height="12" fill="#1c1c2e"/>
  <!-- Claude icon in menu bar -->
  <circle cx="248" cy="12" r="6" fill="#D97757" opacity="0.9"/>
  <text x="248" y="15" text-anchor="middle" fill="#fff" font-size="7" font-weight="bold" font-family="SF Mono,monospace">C</text>
  <!-- Instance count -->
  <rect x="257" y="7" width="14" height="10" rx="3" fill="#E8A84C"/>
  <text x="264" y="14.5" text-anchor="middle" fill="#1a1a2e" font-size="7" font-weight="bold" font-family="SF Mono,monospace">3</text>
  <!-- Dropdown shadow -->
  <rect x="186" y="26" width="122" height="130" rx="8" fill="#000" opacity="0.3" transform="translate(2,2)"/>
  <!-- Dropdown menu -->
  <rect x="186" y="26" width="122" height="130" rx="8" fill="#1e1e32" stroke="#333" stroke-width="0.5"/>
  <!-- Header -->
  <text x="196" y="40" fill="#888" font-size="7" font-family="SF Pro,sans-serif" font-weight="600">RUNNING SESSIONS</text>
  <!-- Instance 1: Opus -->
  <rect x="192" y="44" width="110" height="18" rx="4" fill="#252540"/>
  <text x="197" y="52" fill="#F2A633" font-size="6" font-family="SF Mono,monospace">&#9670;</text>
  <text x="204" y="52" fill="#F2A633" font-size="6" font-family="SF Mono,monospace">opus</text>
  <text x="228" y="52" fill="#ccc" font-size="6" font-family="SF Mono,monospace">~/project-a</text>
  <text x="289" y="52" fill="#666" font-size="5.5" font-family="SF Mono,monospace">12m</text>
  <text x="197" y="59" fill="#666" font-size="5" font-family="SF Mono,monospace">14 turns  482 tok/s  $0.32</text>
  <!-- Instance 2: Sonnet -->
  <rect x="192" y="64" width="110" height="18" rx="4" fill="#252540"/>
  <text x="197" y="72" fill="#6194FF" font-size="6" font-family="SF Mono,monospace">&#9679;</text>
  <text x="204" y="72" fill="#6194FF" font-size="6" font-family="SF Mono,monospace">sonnet</text>
  <text x="234" y="72" fill="#ccc" font-size="6" font-family="SF Mono,monospace">~/api-svc</text>
  <text x="289" y="72" fill="#666" font-size="5.5" font-family="SF Mono,monospace">3m</text>
  <text x="197" y="79" fill="#666" font-size="5" font-family="SF Mono,monospace">6 turns  520 tok/s  $0.08</text>
  <!-- Instance 3: Haiku -->
  <rect x="192" y="84" width="110" height="18" rx="4" fill="#252540"/>
  <text x="197" y="92" fill="#4DD1B8" font-size="6" font-family="SF Mono,monospace">&#9675;</text>
  <text x="204" y="92" fill="#4DD1B8" font-size="6" font-family="SF Mono,monospace">haiku</text>
  <text x="232" y="92" fill="#ccc" font-size="6" font-family="SF Mono,monospace">~/scripts</text>
  <text x="289" y="92" fill="#666" font-size="5.5" font-family="SF Mono,monospace">1m</text>
  <text x="197" y="99" fill="#666" font-size="5" font-family="SF Mono,monospace">2 turns  680 tok/s  $0.01</text>
  <!-- Rate limits section -->
  <text x="196" y="112" fill="#888" font-size="7" font-family="SF Pro,sans-serif" font-weight="600">RATE LIMITS</text>
  <!-- 5h bar -->
  <text x="196" y="121" fill="#999" font-size="5.5" font-family="SF Mono,monospace">5h</text>
  <rect x="210" y="116" width="82" height="6" rx="2" fill="#1a1a2e"/>
  <rect x="210" y="116" width="52" height="6" rx="2" fill="url(#bar)" opacity="0.85"/>
  <text x="296" y="121" fill="#E8A84C" font-size="5.5" font-family="SF Mono,monospace">63%</text>
  <!-- Weekly bar -->
  <text x="196" y="131" fill="#999" font-size="5.5" font-family="SF Mono,monospace">wk</text>
  <rect x="210" y="126" width="82" height="6" rx="2" fill="#1a1a2e"/>
  <rect x="210" y="126" width="28" height="6" rx="2" fill="#4CAF50" opacity="0.85"/>
  <text x="296" y="131" fill="#4CAF50" font-size="5.5" font-family="SF Mono,monospace">34%</text>
  <!-- Actions row -->
  <text x="196" y="148" fill="#6194FF" font-size="6" font-family="SF Pro,sans-serif">+ New</text>
  <text x="224" y="148" fill="#6194FF" font-size="6" font-family="SF Pro,sans-serif">Dashboard</text>
  <text x="264" y="148" fill="#6194FF" font-size="6" font-family="SF Pro,sans-serif">Refresh</text>
  <!-- Dashboard panel (background) -->
  <rect x="8" y="28" width="170" height="142" rx="10" fill="#161625" stroke="#282840" stroke-width="0.5"/>
  <!-- Sidebar -->
  <rect x="8" y="28" width="36" height="142" rx="10" fill="#1a1a30"/>
  <rect x="44" y="28" width="1" height="142" fill="#282840"/>
  <!-- Sidebar tabs -->
  <rect x="11" y="36" width="30" height="16" rx="4" fill="#252550"/>
  <text x="26" y="46" text-anchor="middle" fill="#6194FF" font-size="6" font-family="SF Pro,sans-serif">&#9670;</text>
  <rect x="11" y="55" width="30" height="16" rx="4" fill="transparent"/>
  <text x="26" y="65" text-anchor="middle" fill="#666" font-size="6" font-family="SF Pro,sans-serif">&#9679;</text>
  <rect x="11" y="74" width="30" height="16" rx="4" fill="transparent"/>
  <text x="26" y="84" text-anchor="middle" fill="#666" font-size="6" font-family="SF Pro,sans-serif">&#9677;</text>
  <rect x="11" y="93" width="30" height="16" rx="4" fill="transparent"/>
  <text x="26" y="103" text-anchor="middle" fill="#666" font-size="6" font-family="SF Pro,sans-serif">&#8943;</text>
  <rect x="11" y="112" width="30" height="16" rx="4" fill="transparent"/>
  <text x="26" y="122" text-anchor="middle" fill="#666" font-size="6" font-family="SF Pro,sans-serif">&#9432;</text>
  <!-- Dashboard content: Overview stat cards -->
  <text x="52" y="40" fill="#aaa" font-size="7" font-family="SF Pro,sans-serif" font-weight="600">Overview</text>
  <!-- Row 1 of cards -->
  <rect x="50" y="44" width="38" height="28" rx="4" fill="#1e1e32"/>
  <text x="55" y="54" fill="#888" font-size="5" font-family="SF Mono,monospace">Live</text>
  <text x="55" y="66" fill="#4CAF50" font-size="11" font-weight="bold" font-family="SF Mono,monospace">3</text>
  <rect x="92" y="44" width="38" height="28" rx="4" fill="#1e1e32"/>
  <text x="97" y="54" fill="#888" font-size="5" font-family="SF Mono,monospace">Sessions</text>
  <text x="97" y="66" fill="#6194FF" font-size="11" font-weight="bold" font-family="SF Mono,monospace">47</text>
  <rect x="134" y="44" width="38" height="28" rx="4" fill="#1e1e32"/>
  <text x="139" y="54" fill="#888" font-size="5" font-family="SF Mono,monospace">Turns</text>
  <text x="139" y="66" fill="#E8A84C" font-size="11" font-weight="bold" font-family="SF Mono,monospace">1.2k</text>
  <!-- Row 2 of cards -->
  <rect x="50" y="76" width="38" height="28" rx="4" fill="#1e1e32"/>
  <text x="55" y="86" fill="#888" font-size="5" font-family="SF Mono,monospace">Tok In</text>
  <text x="55" y="98" fill="#D97757" font-size="10" font-weight="bold" font-family="SF Mono,monospace">8.4M</text>
  <rect x="92" y="76" width="38" height="28" rx="4" fill="#1e1e32"/>
  <text x="97" y="86" fill="#888" font-size="5" font-family="SF Mono,monospace">Tok Out</text>
  <text x="97" y="98" fill="#D97757" font-size="10" font-weight="bold" font-family="SF Mono,monospace">1.1M</text>
  <rect x="134" y="76" width="38" height="28" rx="4" fill="#1e1e32"/>
  <text x="139" y="86" fill="#888" font-size="5" font-family="SF Mono,monospace">Cost</text>
  <text x="139" y="98" fill="#E86053" font-size="10" font-weight="bold" font-family="SF Mono,monospace">$42</text>
  <!-- Rate limits in dashboard -->
  <rect x="50" y="108" width="122" height="28" rx="4" fill="#1e1e32"/>
  <text x="55" y="119" fill="#888" font-size="5.5" font-family="SF Pro,sans-serif">Rate Limits</text>
  <rect x="95" y="114" width="68" height="5" rx="2" fill="#1a1a2e"/>
  <rect x="95" y="114" width="43" height="5" rx="2" fill="#E8A84C" opacity="0.8"/>
  <rect x="95" y="122" width="68" height="5" rx="2" fill="#1a1a2e"/>
  <rect x="95" y="122" width="23" height="5" rx="2" fill="#4CAF50" opacity="0.8"/>
  <!-- Models section -->
  <rect x="50" y="140" width="122" height="24" rx="4" fill="#1e1e32"/>
  <text x="55" y="151" fill="#888" font-size="5.5" font-family="SF Pro,sans-serif">Models</text>
  <text x="95" y="151" fill="#F2A633" font-size="5.5" font-family="SF Mono,monospace">&#9670; 12</text>
  <text x="120" y="151" fill="#6194FF" font-size="5.5" font-family="SF Mono,monospace">&#9679; 28</text>
  <text x="147" y="151" fill="#4DD1B8" font-size="5.5" font-family="SF Mono,monospace">&#9675; 7</text>
  <text x="55" y="160" fill="#666" font-size="5" font-family="SF Mono,monospace">across 47 sessions</text>
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
  <img src="https://img.shields.io/badge/lines-~2800-informational" alt="Lines">
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
| **Overview** | 8 stat cards (live, sessions, turns, size, tokens in/out, cost, models), rate limit bars, live aggregate metrics |
| **Live** | Instance cards with full metrics, hover-reveal action buttons, transcript viewer |
| **History** | Searchable, sortable table with tokens, cost estimates, hover-reveal resume/transcript actions, summary stats footer |
| **Events** | Timeline view with `EventBadge` colored dots and event metadata |
| **All Sessions** | Deep filesystem scan of ALL past sessions with search, sort, resume, and transcript actions |
| **About** | App info, build metadata, keyboard shortcuts, data sources, tab guide, troubleshooting |

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
│   ├── claude-instances-bar.swift    # Single-file app (~2800 lines)
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
| `AboutTabView` | Help/about page with build info, keyboard shortcuts, data sources, and troubleshooting. |
| `OverviewSection` | Reusable section container with icon header — used by Overview and About tabs. |
| `focusGhosttyTab()` | AppleScript bridge — finds and focuses the Ghostty tab matching a working directory. |
| `resumeSession()` | AppleScript — opens a new Ghostty tab, cd's to the project, runs `claude --resume`. |

### Data Models

| Struct | Source | Key Fields |
|--------|--------|------------|
| `LiveInstance` | scan.sh | pid, model, modelFull, cwd, elapsed, turns, inputTokens, outputTokens, sessionId, resumeId, statusline |
| `StatuslineMetrics` | `/tmp/claude-statusline-<pid>` | cpu, mem, rssMb, focusFile, tokSpeed, costVel, walSinceCp, mcpHealthy, mcpDown |
| `SessionHistory` | scan.sh | sessionId, project, model, turns, sizeKb, modified, tokensIn, tokensOut, costUsd |
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
