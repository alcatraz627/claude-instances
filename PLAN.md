# Claude Instances — Native macOS Menu Bar App

## Complete Planning Document

**Date:** 2026-04-18 (original) · Updated 2026-04-20
**Session:** `fix-menu-7a` (plan), multiple impl sessions
**Status:** Implemented — all phases complete, app is production-ready

---

# Part 1: Goals & Usage

## Why This Exists

A developer running multiple Claude Code sessions simultaneously needs at-a-glance
visibility into what's running, what's busy, and the ability to jump to any session
instantly. The current SwiftBar-based solution has fundamental limitations:

- **No tab focus**: Can only activate the terminal app, not the specific tab
- **Slow dropdown**: Re-executes the entire script on every click (~150ms perceived)
- **Poor contrast**: SwiftBar's text rendering fights macOS vibrancy
- **No async loading**: All data must be ready before the menu renders

A native Swift app eliminates all four by using AppKit's native menu system, background
timers for data collection, and Ghostty's AppleScript API for precise tab targeting.

## Target User

A power user running 2-10 concurrent Claude Code sessions across multiple projects in
Ghostty terminal tabs. They glance at the menu bar to see "how many are running" and
click to get details or jump to a specific session.

## Core Use Cases

1. **Glance** — See live instance count in the menu bar without clicking
2. **Inspect** — Click to see which instances are running, their model, project, and activity
3. **Jump** — Click an instance to focus the exact Ghostty tab running it
4. **Monitor** — See token usage, rate limit status, and session duration at a glance
5. **Manage** — Terminate individual instances, copy PIDs, open detail views
6. **History** — Browse recent session history (turns, size, last active)

## Non-Goals (v1)

- ~~Starting new Claude sessions (user does this in the terminal)~~ → **Now supported** via ⌘N and resume actions
- Editing session configuration
- ~~Viewing conversation content (the HTML detail page handles this)~~ → **Now supported** via transcript viewer in Dashboard
- Supporting terminals other than Ghostty (can be added later)
- App Store distribution (runs as a standalone binary)

## Usage Model

```
┌────────────────────────────────────────────────────────┐
│  Menu Bar Icon                                          │
│  ┌───────┐                                             │
│  │ 🟠 5  │  ← static Claude logo PNG + instance count  │
│  └───────┘                                             │
│       │ click                                           │
│       ▼                                                 │
│  ┌──────────────────────────────────────┐               │
│  │ LIVE INSTANCES (3 · 245t · 1.2GB)  │               │
│  │ ────────────────────────────────────│               │
│  │ ◆ Opus    ~/myproject    12m       │ ← click=focus │
│  │   CPU 45% · 12.4 tok/s · $0.08/m  │               │
│  │   📄 src/App.tsx                   │               │
│  │ ● Sonnet  ~/other       1h        │               │
│  │   CPU 2%  · idle        · $0/m    │               │
│  │ ────────────────────────────────────│               │
│  │ RATE LIMITS                        │               │
│  │   5hr ▓▓▓▓▓▓▓▓░░░░░░░░ 52%       │               │
│  │   Week ▓▓░░░░░░░░░░░░░░ 12%      │               │
│  │ ────────────────────────────────────│               │
│  │ RECENT EVENTS                      │               │
│  │   ▶ 19:14  Started   ~/project    │               │
│  │   ⚠ 19:12  Permission ~/other     │               │
│  │ ────────────────────────────────────│               │
│  │ SESSION HISTORY (6)                │               │
│  │   ◆ ~/myproject  120t  1.2MB  2h  │ ← clickable   │
│  │ ────────────────────────────────────│               │
│  │ ⌘N New Session                     │               │
│  │ ⌘D Dashboard                       │               │
│  │ ⌘R Refresh                         │               │
│  │    Terminate All (3)               │               │
│  │    Quit                            │               │
│  └──────────────────────────────────────┘               │
│                                                         │
│       ⌘D opens →                                       │
│  ┌──────────────────────────────────────┐               │
│  │ Dashboard (NSPanel)                  │               │
│  │  ┌──────────┬───────────────────┐   │               │
│  │  │ Overview │ Stat cards, rates │   │               │
│  │  │ Live     │ Instance cards    │   │               │
│  │  │ History  │ Sortable table    │   │               │
│  │  │ Events   │ Timeline view     │   │               │
│  │  │ All Sess │ Deep scan + search│   │               │
│  │  └──────────┴───────────────────┘   │               │
│  └──────────────────────────────────────┘               │
└────────────────────────────────────────────────────────┘
```

---

# Part 2: Product Manager Spec

## 2.1 Information Architecture

### Menu Bar Icon (Always Visible)

| Element | Behavior |
|---------|----------|
| Icon | Static Claude logo PNG (`~/.claude/assets/images/claude-icon-coral-32.png`), 18×18pt, `isTemplate = false` |
| Count badge | Number of live instances as text right of icon (monospaced digit font) |
| Alert state | Count text turns orange when rate limit > 75%, red when > 90% |
| Idle state | Shows "–" when no instances running, icon dims to 50% opacity |
| Permission alert | Shows "⚠ N" prefix when recent PermissionRequest events detected |

### Dropdown Menu (On Click)

The menu is structured into these sections, top to bottom:

#### Section 1: Live Instances (with aggregate header)
- Section header: `LIVE INSTANCES (N · Xt · X.XGB)` with SF Symbol icon
- Aggregate stats (total instances, total turns, total memory) in the header
- Shows "No live instances" with dimmed text when empty
- `menu.minimumWidth = 340` ensures consistent dropdown width

Each instance gets 2-3 rows:

**Row 1 (Primary)**: `◆ Opus  ~/project-name  12m  45t  ↑12K` — model badge, project, elapsed, turns, tokens
  - Clicking this row focuses the Ghostty tab via AppleScript
  - Right-arrow submenu: View Transcript, Copy PID, Terminate

**Row 2 (Metrics)**: `  CPU 45% · 12.4 tok/s · $0.08/m` — statusline metrics in dim mono
  - Shows CPU%, token speed, cost velocity when available
  - Falls back to basic PID/memory info when statusline unavailable

**Row 3 (Focus file, optional)**: `  📄 src/components/App.tsx` — current file being worked on
  - Only shown when statusline data includes `focus_file`
  - Path shortened with `…` prefix if >35 chars

#### Section 2: Rate Limits (Conditional)
- Shows only when rate limit data is available
- 16-char visual progress bar using `▓░` characters
- `5hr  ▓▓▓▓▓▓▓▓░░░░░░░░  52%  (18K/42K)`
- 4-tier color thresholds:
  - Green: <50% (`.systemGreen`)
  - Yellow: 50-75% (`.systemYellow`)
  - Orange: 75-90% (`.systemOrange`)
  - Red: >90% (`.systemRed`)

#### Section 3: Recent Events
- Section header: `RECENT EVENTS` with colored dot icons
- Last 5 events shown inline (not a submenu)
- Per-event-type symbols with semantic colors:
  - `▶` Started (green)
  - `■` Stopped (red)
  - `⚠` PermissionRequest (yellow)
  - `⟳` Compacted (blue)
  - `·` Other (gray)

#### Section 4: Session History
- Section header: `SESSION HISTORY (N)`
- Last 6 sessions shown as clickable rows
- Each: `◆ ~/project  120t  1.2MB  2h ago` with model-colored badge
- **Clicking a row calls `resumeSession()`** — opens new Ghostty tab, cd's to project, runs `claude --resume`
- Sorted by last modified, most recent first

#### Section 5: Actions
- New Session (⌘N) — opens new Ghostty tab
- Dashboard (⌘D) — opens native SwiftUI dashboard panel
- Refresh (⌘R) — triggers immediate data refresh
- Separator
- Terminate All (N) — red, only shown when instances exist
- Separator
- Quit

## 2.2 User Stories

### US-1: At-a-glance status
> As a developer, I glance at the menu bar and see "5" next to the Claude icon,
> telling me 5 sessions are active without interrupting my flow.

### US-2: Jump to session
> I click the menu bar icon, see my 5 sessions listed by project name, and click
> the one working on `enhancement-product`. Ghostty brings that exact tab to the
> front. Total time: 2 clicks, <1 second.

### US-3: Check rate limits
> I see the icon has turned yellow. I click and see `5hr ████████░░░░ 78%`.
> I know I should pause one session. I click Terminate on the least important one.

### US-4: Review history
> I hover over History and see my recent sessions. I spot one from yesterday
> with 450 turns that I want to resume — the project path tells me where to `cd`.

### US-5: Copy PID for debugging
> A session is stuck. I hover over it, click Copy PID in the submenu, then paste
> into `kill -USR1 <pid>` in my terminal.

## 2.3 Interaction Flows

### Flow 1: Focus a Ghostty Tab
```
User clicks menu icon
  → Menu appears instantly (data pre-cached)
  → User clicks instance row "◆ Opus ~/myproject"
  → App runs AppleScript:
      tell application "Ghostty"
        set terms to every terminal whose working directory contains "myproject"
        if count of terms > 0 then
          focus item 1 of terms
        end if
      end tell
  → Ghostty activates and focuses the matching tab
  → Menu dismisses automatically
```

### Flow 2: Terminate Instance
```
User clicks menu icon
  → Hovers over instance row → submenu appears
  → Clicks "Terminate" (red text)
  → App sends SIGTERM to PID
  → After 3s, checks if still alive → sends SIGKILL
  → Menu refreshes on next open (timer-based)
```

### Flow 3: Rate Limit Warning
```
Background timer detects rate limit > 75%
  → Menu bar icon tints yellow
  → Next menu open shows rate limit bar prominently
  → If > 90%, icon tints red + rate limit bar text turns red
```

## 2.4 Edge Cases

| Scenario | Behavior |
|----------|----------|
| No instances running | Icon shows "–", menu shows "No live instances" with dimmed text |
| Scanner fails | Menu shows last cached data + "⚠ Data may be stale" warning |
| Ghostty not running | Focus action falls back to opening Ghostty app |
| Instance PID died | Next scan removes it from the list automatically |
| 10+ instances | All shown (no truncation) — menu scrolls natively if needed |
| Rate limit unavailable | Rate limit section hidden entirely |
| No events | Events submenu hidden |
| No history | History submenu shows "No sessions found" |

## 2.5 Data Refresh Strategy

| Data | Refresh interval | Trigger |
|------|-------------------|---------|
| Live instances (pgrep + statusline) | Every 5 seconds | Background timer |
| Session history (JSONL scan) | Every 30 seconds | Background timer |
| Rate limits | Every 60 seconds | Background timer |
| Events | Every 30 seconds | Background timer |
| Menu content | Instant | `menuNeedsUpdate` (NSMenuDelegate) |

The menu reads from cached data (populated by background timers), so opening the
menu is always instant — no blocking I/O on click.

---

# Part 3: Designer Doc

## 3.1 Design Philosophy

Inspired by the best macOS menu bar apps:

- **Stats** (exelban/stats) — dense but readable system metrics, SF Symbols, no
  wasted space, seamless light/dark mode via system colors
- **Bartender/Ice** — elegant menu bar management, native feel
- **Raycast** — instant response, keyboard-driven, polished details
- **Apple's own menu extras** (Battery, WiFi, Sound) — the gold standard for
  menu bar items: monochrome template icon, system-native menu, no custom chrome

**Our principles:**
1. **Feel native** — use system fonts, colors, and spacing. Never fight macOS.
2. **Instant response** — menu opens in <16ms. All data pre-cached.
3. **Information density** — show maximum useful info in minimum space.
4. **Zero learning curve** — if you've used any macOS menu extra, you know this one.

## 3.2 Menu Bar Icon

### Icon Design (Implemented)
- **Chosen**: Static Claude logo PNG at `~/.claude/assets/images/claude-icon-coral-32.png`
- Loaded via `NSImage(contentsOfFile:)`, sized to 18×18pt
- **`isTemplate = false`** — preserves the coral color, does not auto-adapt to dark/light
- **Decision history**: SF Symbols (`sparkles`, `sparkles.rectangle.stack`) were tried
  and rejected — the static brand logo is more recognizable and less generic
- **Badge**: Instance count as attributed text right of icon, monospaced digit font 12pt

### Icon States
| State | Appearance |
|-------|-----------|
| Active (1+ instances) | Full opacity icon + coral count number |
| Idle (0 instances) | 50% opacity icon + "–" in tertiary label color |
| Warning (rate limit 75-90%) | Full opacity icon + orange count text |
| Critical (rate limit >90%) | Full opacity icon + red count text |
| Permission pending | "⚠ N" prefix on count text |

## 3.3 Typography

All text uses **system fonts** — no custom fonts, no web fonts.

| Element | Font | Size | Weight | Color |
|---------|------|------|--------|-------|
| Instance model + path | System | 14pt | Bold (Menlo) | labelColor |
| Instance metadata | System | 12pt | Regular (Menlo) | secondaryLabelColor |
| Focus file path | Monospace | 12pt | Regular | tertiaryLabelColor |
| Summary bar | System | 13pt | Regular | labelColor |
| Section headers | System | 11pt | Semibold | secondaryLabelColor |
| Rate limit bar | Monospace | 12pt | Regular | varies by % |
| Submenu items | System | 13pt | Regular | labelColor |
| Action items | System | 13pt | Regular | labelColor |
| Destructive actions | System | 13pt | Regular | systemRed |

## 3.4 Color System

Use **only system semantic colors** — never hardcode hex values in the menu.

| Semantic | NSColor | Used for |
|----------|---------|----------|
| Primary text | `.labelColor` | Instance names, summary |
| Secondary text | `.secondaryLabelColor` | PID, elapsed, metadata |
| Tertiary text | `.tertiaryLabelColor` | Focus file, history age |
| Accent | `.systemBlue` | Clickable links |
| Success | `.systemGreen` | Healthy indicators |
| Warning | `.systemOrange` | Rate limit 75-90% |
| Error | `.systemRed` | Rate limit >90%, terminate actions |
| Separator | `.separatorColor` | Section dividers |

### Model Badge Colors (Updated)
| Model | Badge | Color | RGB |
|-------|-------|-------|-----|
| Opus | ◆ | Warm amber/gold | `(0.95, 0.65, 0.20)` |
| Sonnet | ● | Vibrant blue | `(0.38, 0.58, 1.0)` |
| Haiku | ○ | Teal/mint | `(0.30, 0.82, 0.72)` |
| Unknown | · | `.secondaryLabelColor` | system |

> **Note:** Original plan used `.systemPurple`/`.systemBlue`/`.systemGreen` but these
> were changed to custom RGB values for better visual distinction and brand alignment.

## 3.5 Layout Specifications

### Menu Item Heights
- **Instance primary row**: Standard NSMenuItem height (~22pt)
- **Instance metadata row**: Slightly shorter (custom view, ~18pt)
- **Separator**: System standard (`NSMenuItem.separator()`)

### Padding & Spacing
- Left padding: System default (NSMenuItem handles this)
- Instance group spacing: System separator between groups
- Submenu indentation: System default

### Menu Width
- Let AppKit calculate width naturally from content
- Truncate paths beyond ~35 characters with `…` prefix
- Target comfortable reading at ~300-350pt wide

## 3.6 Custom NSMenuItem Views

For rich content rows (instance metadata, rate limit bars), use custom views via
`NSHostingView` wrapping SwiftUI views assigned to `menuItem.view`.

### Instance Row (Attributed Strings — dropdown menu)
```
┌──────────────────────────────────────────────────┐
│ ◆ Opus  ~/myproject  12m  45t  ↑12K            │  ← Row 1: click = focus tab
│   CPU 45% · 12.4 tok/s · $0.08/m               │  ← Row 2: dim mono metrics
│   📄 src/components/App.tsx                      │  ← Row 3: focus file
└──────────────────────────────────────────────────┘
```

### Rate Limit Bar (Attributed Strings — dropdown menu)
```
┌──────────────────────────────────────────────────┐
│  5hr  ▓▓▓▓▓▓▓▓░░░░░░░░  52%  (32K/42K)        │  ← 16-char bar
│  Week ▓▓░░░░░░░░░░░░░░  12%  (150K/1M)         │  ← 4-tier color
└──────────────────────────────────────────────────┘
```

### Instance Card (SwiftUI — dashboard Live tab)
```
┌──────────────────────────────────────────────────┐
│ ◆ Opus 4.6         ~/myproject          12m     │
│ PID 1234 · 45 turns · ↑12K out                  │
│ CPU 45% · RSS 352MB · 12.4 tok/s · $0.08/m     │
│ WAL since CP: 5 · MCP: 2 healthy                │
│ 📄 src/components/App.tsx                        │
│──────────────────────────────────────────────────│
│ [Focus Tab] [Transcript] [Copy PID] [Terminate] │  ← hover-reveal
└──────────────────────────────────────────────────┘
```

## 3.7 SF Symbols Usage (Updated)

| Context | Symbol | Variant |
|---------|--------|---------|
| Menu bar icon | ~~`sparkles`~~ → Static PNG | Coral Claude logo, `isTemplate = false` |
| Section headers | Various (14pt) | Used in `addSectionHeader()` helper |
| Dashboard action | `rectangle.3.group` | 14pt |
| Refresh action | `arrow.clockwise` | 14pt |
| New session | `plus.circle` | 14pt |
| Event: Started | `▶` (Unicode) | `.systemGreen` |
| Event: Stopped | `■` (Unicode) | `.systemRed` |
| Event: Permission | `⚠` (Unicode) | `.systemYellow` |
| Event: Compacted | `⟳` (Unicode) | `.systemBlue` |
| Quit | – | standard text |

> **Note:** The dropdown menu moved from SF Symbol dots per event to Unicode symbols
> for better cross-version compatibility and more distinct visual differentiation.

## 3.8 Animation & Transitions

**Keep it minimal.** This is a utility, not a showpiece.

- Menu open/close: System default (instant)
- Icon count update: No animation (just changes number)
- Rate limit warning: Icon color change (no animation)
- Data refresh: Silent background update, menu sees new data on next open

**Permission request**: Instead of the originally planned pulse animation, permission
requests are indicated by a `⚠` prefix on the instance count text. The pulse animation
was implemented briefly but removed in favor of the simpler text indicator — less
distracting, equally noticeable.

## 3.9 Responsive Behavior

- **Light/Dark mode**: Automatic via system semantic colors. Template image icons
  auto-adapt. No manual theme switching needed.
- **Reduce Transparency**: System handles vibrancy removal automatically for NSMenu.
- **Increase Contrast**: System semantic colors auto-adjust.
- **Multiple displays**: Menu appears on the display with the menu bar (standard behavior).

## 3.10 Design Examples from Research

### Stats App (exelban/stats)
- Uses popover with custom SwiftUI views for rich data display
- Dense monospaced metrics with color coding
- Each module (CPU, GPU, Memory, etc.) is a separate menu bar item
- Lesson: **Dense is fine if systematically organized**

### Apple Battery Menu Extra
- Template image icon with optional percentage text
- Click opens popover with details (macOS Sonoma+) or NSMenu (older)
- Simple, focused, one concern only
- Lesson: **One menu bar item, one domain. Don't overload.**

### Raycast
- Not a menu bar app per se, but relevant UX: instant response, keyboard nav
- Lesson: **Speed is a feature. If it takes 200ms to open, it feels broken.**

---

# Part 4: Technical Implementation

## 4.1 Architecture Overview

```
┌──────────────────────────────────────────────────────────────┐
│  claude-instances-bar  (single-file Swift binary, ~2340 LOC) │
│                                                              │
│  ┌──────────────┐   ┌──────────────┐   ┌─────────────────┐ │
│  │  BarDelegate  │   │  Scanner     │   │ GhosttyAPI      │ │
│  │  (AppKit)     │   │  (Timer)     │   │ (AppleScript)   │ │
│  │               │   │              │   │                 │ │
│  │ NSStatusItem  │◀──│ scan.sh JSON │   │ focusTab(cwd)   │ │
│  │ NSMenu        │   │ every 5s     │   │ resumeSession() │ │
│  │ NSMenuDelegate│   │              │   │ newTab()        │ │
│  └──────┬───────┘   └──────┬───────┘   └─────────────────┘ │
│         │                   │                                │
│    ┌────▼────┐        ┌────▼────────┐                       │
│    │ Menu    │        │ Cached Data │                       │
│    │ Items   │        │ (ScanResult)│                       │
│    └─────────┘        └────┬────────┘                       │
│                            │                                 │
│                   ┌────────▼─────────┐                      │
│                   │ DashboardData    │                      │
│                   │ (ObservableObj.) │                      │
│                   └────────┬─────────┘                      │
│                            │                                 │
│              ┌─────────────▼──────────────────┐             │
│              │ DashboardController             │             │
│              │ NSPanel + NSHostingView          │             │
│              │ ┌──────────┬──────────────────┐│             │
│              │ │ Sidebar  │ Tab Content       ││             │
│              │ │ Overview │ SwiftUI Views     ││             │
│              │ │ Live     │ (NavigationSplit) ││             │
│              │ │ History  │                   ││             │
│              │ │ Events   │                   ││             │
│              │ │ All Sess │                   ││             │
│              │ └──────────┴──────────────────┘│             │
│              └────────────────────────────────┘             │
└──────────────────────────────────────────────────────────────┘
```

## 4.2 Technology Stack

| Component | Choice | Rationale |
|-----------|--------|-----------|
| Language | Swift 5.9+ | Native macOS, single-file compilation |
| UI Framework | AppKit + SwiftUI hybrid | NSMenu for menu, SwiftUI for custom views |
| Menu system | NSStatusItem + NSMenu + NSMenuDelegate | Instant, native, proven pattern |
| Data source | Shell out to `scan.sh` | Reuse existing scanner, proven correct |
| Tab focus | AppleScript via `NSAppleScript` | Ghostty's official automation API |
| Build | `swiftc -O` (single file) | No Xcode project, fast iteration |
| Process management | LaunchAgent plist | Auto-start on login, restart on crash |

## 4.3 File Structure

```
~/.claude/widgets/claude-instances/
├── native/
│   ├── claude-instances-bar.swift    # Single-file app (~2400 lines)
│   ├── build.sh                      # Compile + install + manage
│   └── .build-info                   # Auto-generated build metadata
├── lib/
│   ├── scan.sh                       # Python scanner → JSON output
│   └── detail.sh                     # Session transcript HTML generator
├── plugin.sh                         # Legacy SwiftBar plugin (kept)
├── render.sh                         # Legacy HTML dashboard renderer
├── dashboard.html                    # Legacy HTML dashboard
├── PLAN.md                           # This document (original design)
└── README.md                         # User-facing documentation
```

**External dependency:**
```
~/.claude/assets/images/claude-icon-coral-32.png   # Menu bar icon (32×32 RGBA PNG)
```

## 4.4 Data Flow

```
Background Timer (5s)
  │
  ▼
Shell out: bash scan.sh → stdout JSON
  │
  ▼
Parse JSON → ScanResult struct
  │
  ▼
Cache in BarDelegate properties
  │
  ╔═══════════════════════════╗
  ║ User clicks menu bar icon ║
  ╚═══════════════════════════╝
  │
  ▼
menuNeedsUpdate(_:) fires (NSMenuDelegate)
  │
  ▼
Read cached ScanResult (no I/O)
  │
  ▼
Build NSMenu items from cached data
  │
  ▼
Menu renders instantly
```

## 4.5 Data Models (Swift — as implemented)

```swift
struct ScanResult: Codable {
    let live: [LiveInstance]
    let history: [SessionHistory]
    let recentEvents: [Event]?
    let limits: RateLimits?
    let liveCount: Int
}

struct LiveInstance: Codable {
    let pid: Int
    let model: String?
    let modelFull: String?           // e.g. "claude-opus-4-6"
    let cwd: String?
    let cwdShort: String?
    let elapsed: String?
    let turns: Int?
    let inputTokens: Int?            // NEW — total input tokens
    let outputTokens: Int?
    let cacheRead: Int?
    let sessionId: String?
    let resumeId: String?            // NEW — for `claude --resume`
    let statusline: StatuslineMetrics?
}

struct StatuslineMetrics: Codable {
    let cpu: String?
    let mem: String?
    let rssMb: String?
    let focusFile: String?
    let mcpHealthy: String?
    let mcpDown: String?
    let tokSpeed: String?
    let costVel: String?             // NEW — cost velocity (cents/min)
    let walSinceCp: String?          // NEW — WAL actions since checkpoint
}

struct SessionHistory: Codable {
    let sessionId: String
    let project: String
    let model: String?
    let turns: Int
    let sizeKb: Double
    let modified: String?
    let tokensIn: Int?               // NEW — total input tokens
    let tokensOut: Int?              // NEW — total output tokens
}

struct Event: Codable {
    let event: String
    let ts: String
    let project: String?
    let sessionId: String?           // NEW — links event to session
}

struct RateLimitEntry: Codable {
    let pct: Double
    let used: Int
    let cap: Int
}

struct RateLimits: Codable {
    let fiveH: RateLimitEntry?       // "5h" JSON key
    let week: RateLimitEntry?
}

// ── Dashboard-only model (not from scan.sh) ──

struct FullSession {
    let sessionId: String
    let project: String
    let projectDirName: String       // raw dir name for path resolution
    let model: String
    let turns: Int
    let sizeKb: Double
    let modified: Date
    let tokensIn: Int
    let tokensOut: Int
    let jsonlPath: String            // full path for transcript viewing
}
```

## 4.6 Ghostty Tab Focus via AppleScript

The key differentiator over SwiftBar. Ghostty exposes a rich AppleScript API:

```swift
func focusGhosttyTab(forCwd cwd: String) {
    let script = """
    tell application "Ghostty"
        activate
        set allTerminals to every terminal whose working directory contains "\(cwd)"
        if (count of allTerminals) > 0 then
            focus item 1 of allTerminals
        end if
    end tell
    """
    let appleScript = NSAppleScript(source: script)
    var error: NSDictionary?
    appleScript?.executeAndReturnError(&error)
    if let error = error {
        dlog("AppleScript error: \(error)")
    }
}
```

**Matching strategy**: Use the instance's `cwd` (working directory) to find the
matching Ghostty terminal. The scan data already provides this. Ghostty's
`working directory` property maps to the terminal's CWD.

**Fallback**: If no matching terminal is found (e.g., process died between scan
and click), just activate Ghostty without targeting a specific terminal.

## 4.7 Scanner Integration

Rather than reimplementing process discovery in Swift, shell out to the existing
`scan.sh` which is already battle-tested:

```swift
func runScanner() -> ScanResult? {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/bash")
    task.arguments = [scanScriptPath]
    
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = FileHandle.nullDevice
    
    do {
        try task.run()
        task.waitUntilExit()
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return try JSONDecoder().decode(ScanResult.self, from: data)
    } catch {
        dlog("Scanner error: \(error)")
        return nil
    }
}
```

This runs on a background timer. The result is cached and the menu reads from cache.

## 4.8 Menu Construction (as implemented)

Using NSMenuDelegate's `menuNeedsUpdate(_:)` — called right before the menu opens:

```swift
func menuNeedsUpdate(_ menu: NSMenu) {
    menu.removeAllItems()
    menu.minimumWidth = 340
    
    guard let data = cachedData else {
        addDimItem(menu, "Scanning...")
        return
    }
    
    addLiveInstancesSection(menu, data)   // header includes aggregate stats
    addRateLimitsSection(menu, data)
    addEventsSection(menu, data)
    addHistorySection(menu, data)          // clickable rows → resumeSession()
    addActionsSection(menu, data)          // ⌘N, ⌘D, ⌘R shortcuts
}
```

**Implementation note:** The dropdown menu uses only `NSMenuItem` with
`NSMutableAttributedString` — no `NSHostingView` in the menu. SwiftUI views are
reserved for the dashboard `NSPanel`. This keeps the menu lightweight and instant.

Helper methods used throughout:
- `addSectionHeader(_:title:icon:count:)` — bold header with SF Symbol
- `addDimMono(_:_:)` — monospaced dim text for metrics rows
- `addAction(_:action:key:)` — action item with optional keyboard shortcut
- `addDimItem(_:_:)` — disabled dim text for informational rows

## 4.9 Build System

Mirrors the i-dream build.sh pattern:

```bash
#!/usr/bin/env bash
# build.sh — Compile and manage the claude-instances menu bar widget.
#
# Usage:
#   bash build.sh              # compile + launch
#   bash build.sh --install    # compile + register LaunchAgent
#   bash build.sh --uninstall  # remove LaunchAgent + kill
#   bash build.sh --logs       # tail debug log
#   bash build.sh --status     # show running state

LABEL="dev.claude-instances.menubar"
OUTPUT="claude-instances-bar"
SOURCE="claude-instances-bar.swift"

# Compile: swiftc -O $SOURCE -o $OUTPUT
# Sign: codesign --sign - --force $OUTPUT
# LaunchAgent: ~/Library/LaunchAgents/$LABEL.plist
```

## 4.10 Process Lifecycle

| Lifecycle | Mechanism |
|-----------|-----------|
| Start | `build.sh` or LaunchAgent (RunAtLoad) |
| Auto-restart | LaunchAgent KeepAlive (SuccessfulExit=false) |
| Stop | Quit menu item → `NSApp.terminate(nil)` |
| Update | `build.sh` kills old, compiles, launches new |
| Debug | `build.sh --logs` → `tail -f /tmp/claude-instances-bar.log` |
| No Dock icon | `LSUIElement = true` in embedded Info.plist |

## 4.11 Native Dashboard (Added post-plan)

The dashboard was not in the original plan. It evolved from the "Dashboard" action
that originally opened `dashboard.html`, into a full native SwiftUI panel.

### Architecture

```swift
class DashboardController {
    var panel: NSPanel?         // floating utility window
    var dashData: DashboardData // ObservableObject bridge
    
    func open() { /* create NSPanel + NSHostingView if needed, show */ }
    func close() { panel?.close() }
    func update(_ data: ScanResult?) { dashData.scanData = data }
}

class DashboardData: ObservableObject {
    @Published var scanData: ScanResult?
    @Published var allSessions: [FullSession] = []
    @Published var isScanning = false
    
    func loadAllSessions() { /* on-demand deep JSONL scan */ }
}
```

### Tabs

| Tab | View | Data Source |
|-----|------|------------|
| Overview | `OverviewTabView` | `ScanResult` (cached) |
| Live | `LiveTabView` + `InstanceCard` | `ScanResult.live` |
| History | `HistoryTabView` | `ScanResult.history` |
| Events | `EventsTabView` + `EventBadge` | `ScanResult.recentEvents` |
| All Sessions | `AllSessionsTabView` + `SessionRow` | `DashboardData.allSessions` (on-demand) |

### All Sessions Deep Scan

The All Sessions tab triggers `scanAllSessions()` — a filesystem walk of
`~/.claude/projects/` that reads every `*.jsonl` session file. This is expensive
(100-500ms depending on session count) so it runs on-demand only when the tab
is selected, not on the 5-second periodic timer.

## 4.12 Performance Targets

| Metric | Target | How |
|--------|--------|-----|
| Menu open latency | <16ms | Pre-cached data, no I/O on click |
| Scanner execution | <100ms | Existing scan.sh, run in background |
| Memory usage | <30MB | No WebKit, no images, just AppKit |
| CPU (idle) | <0.5% | Timer fires every 5s, quick JSON parse |
| CPU (scanning) | <2% | 100ms burst every 5s |
| Binary size | <2MB | Single Swift file, system frameworks only |

## 4.12 Error Handling

| Error | Recovery |
|-------|----------|
| scan.sh fails | Use last cached result + show stale warning |
| JSON parse error | Use last cached result + log error |
| AppleScript fails | Log error, activate Ghostty anyway |
| Ghostty not running | Open Ghostty.app |
| PID no longer exists | Removed on next scan (5s) |
| LaunchAgent crash | Auto-restart via KeepAlive |

---

# Part 5: Implementation Plan

> **All phases completed.** The sections below reflect the original plan with
> completion status and notes on deviations from the plan.

## Phase 1: Skeleton + Scanner (MVP) ✅

**Status**: Complete

### Tasks:
1. ✅ Create `native/` directory and `build.sh`
2. ✅ Write Swift skeleton: `BarDelegate`, `NSStatusItem`, `NSMenu`, `NSMenuDelegate`
3. ✅ Implement scanner integration (shell out to `scan.sh`, parse JSON)
4. ✅ Background timer (5s) for scanner — runs on `DispatchQueue.global(qos: .userInitiated)`
5. ✅ `menuNeedsUpdate` builds menu from cached data
6. ✅ Menu bar icon — **deviation**: static Claude PNG instead of SF Symbol `sparkles`
7. ✅ Live instances: NSMenuItem rows with attributed strings
8. ✅ Test: compile, run, verify menu shows real data

## Phase 2: Tab Focus + Actions ✅

**Status**: Complete

### Tasks:
1. ✅ Implement `focusGhosttyTab(forCwd:)` via NSAppleScript
2. ✅ Wire instance row click to focus action
3. ✅ Implement submenu: View Transcript, Copy PID, Terminate
4. ✅ Implement Terminate (SIGTERM)
5. ✅ Implement Copy PID (NSPasteboard)
6. ✅ Implement transcript viewing (opens transcript file)
7. ✅ Test all actions with real running instances

## Phase 3: Rich Display ✅

**Status**: Complete

### Tasks:
1. ✅ Rich instance display with CPU%, tok/s, $/m metrics
2. ✅ Rate limit bars — 16-char `▓░` with 4-tier color coding
3. ✅ NSMenuItem with attributed strings (no NSHostingView in dropdown)
4. ✅ Model badge colors — **deviation**: amber/blue/teal custom RGB instead of system colors
5. ✅ Aggregate stats in section header (not separate summary bar)
6. ✅ Events with per-type Unicode symbols and colors
7. ✅ History rows — **added**: clickable with `resumeSession()` action
8. ✅ Icon state changes (rate limit warning/critical via text color)
9. ✅ Keyboard shortcuts (⌘N, ⌘D, ⌘R)

## Phase 4: Polish + LaunchAgent ✅

**Status**: Complete

### Tasks:
1. ✅ Build.sh `--install` for LaunchAgent registration
2. ✅ Build.sh `--uninstall`, `--status`, `--logs`
3. ✅ `LSUIElement` (no Dock icon) via embedded Info.plist
4. ✅ Debug logging to `/tmp/claude-instances-bar.log`
5. ✅ Stale data warning when scanner fails (shows cached data)
6. ✅ Permission request indicator — **deviation**: `⚠` text prefix instead of pulse animation
7. ✅ Handle no-instances, no-events, no-history gracefully
8. ✅ Quit menu item
9. ✅ Process dedupe on startup (pgrep/kill)
10. ✅ SwiftBar plugin kept as legacy fallback

## Phase 5: Native Dashboard (Beyond Original Plan) ✅

**Status**: Complete — not in original plan, added during implementation

### Features:
1. ✅ `DashboardController` — manages floating `NSPanel` with `.utilityWindow` style
2. ✅ SwiftUI `NavigationSplitView` sidebar with 5 tabs
3. ✅ **Overview tab** — stat cards (live count, total turns, memory, cache), rate limit bars
4. ✅ **Live tab** — instance cards with full metrics, hover-reveal action buttons, transcript viewer
5. ✅ **History tab** — sortable table (project, model, turns, size, last active)
6. ✅ **Events tab** — timeline view with colored dots and event metadata (`EventBadge`)
7. ✅ **All Sessions tab** — deep scan of ALL past JSONL sessions with search, sort, resume, transcript
8. ✅ `DashboardData` as `ObservableObject` bridging cached scan data to SwiftUI
9. ✅ On-demand `scanAllSessions()` for the All Sessions tab (not on periodic timer)
10. ✅ `.ultraThinMaterial` background for native vibrancy

## Phase 6: Dropdown Redesign (Beyond Original Plan) ✅

**Status**: Complete — not in original plan, added during implementation

### Features:
1. ✅ `addSectionHeader()` helper with SF Symbol icons
2. ✅ `addDimMono()` helper for monospaced dim text
3. ✅ Aggregate stats folded into live instances header
4. ✅ Richer instance rows: CPU%, tok/s, cost velocity, focus file with 📄
5. ✅ Clickable history rows that call `resumeSession()` via AppleScript
6. ✅ `menu.minimumWidth = 340` for consistent dropdown width
7. ✅ Keyboard shortcuts via `NSMenuItem.keyEquivalent`

## Actual Structure (vs Estimate)

The final `claude-instances-bar.swift` is approximately **2,340 lines**:

| Component | Estimated | Actual | Notes |
|-----------|-----------|--------|-------|
| Data models + JSON parsing | ~100 | ~220 | Added `FullSession`, `RateLimitEntry`, `ModelDisplay`, more fields |
| Scanner integration + caching | ~60 | ~150 | Added `scanAllSessions()` deep scan, thread-safe caching |
| Ghostty AppleScript bridge | ~40 | ~80 | Added `resumeSession()`, `activateGhostty()`, `openFile()` |
| Menu construction | ~200 | ~350 | Rich sections, attributed strings, section headers, keyboard shortcuts |
| SwiftUI views | ~100 | ~800 | Full dashboard: 5 tabs, sidebar, instance cards, event badges, all sessions |
| Action handlers | ~80 | ~120 | Added resume, new session, dashboard toggle |
| Icon management | ~60 | ~40 | Simpler (static PNG instead of dynamic SF Symbols) |
| App lifecycle + logging | ~50 | ~80 | Added dedupe, LaunchAgent awareness |
| Dashboard controller | – | ~200 | Not in original plan: `NSPanel`, `DashboardData`, `NSHostingView` |
| Helpers + formatting | – | ~100 | `fmtTokens`, `fmtSize`, `relativeTime`, `shortenPath` |
| **Total** | **~700** | **~2,340** | **3.3× original estimate** |

The primary drivers of the size increase were the native SwiftUI dashboard (not planned)
and the rich dropdown redesign with per-section formatting helpers.

---

# Research Notes

## Sources Consulted

- [What I Learned Building a Native macOS Menu Bar App](https://dev.to/heocoi/what-i-learned-building-a-native-macos-menu-bar-app-4im6)
  — Key insight: use NSMenu not NSPopover, 70/30 SwiftUI/AppKit split
- [Pushing the limits of NSStatusItem](https://multi.app/blog/pushing-the-limits-nsstatusitem)
  — Advanced: custom views in status bar, multiple click targets
- [Stats app (exelban/stats)](https://github.com/exelban/stats)
  — Design reference for dense system monitoring in menu bar
- [Ghostty AppleScript docs](https://ghostty.org/docs/features/applescript)
  — Tab/terminal enumeration, focus, working directory matching
- [Ghostty tab switcher discussion](https://github.com/ghostty-org/ghostty/discussions/11683)
  — Community patterns for Ghostty automation
- [NSPopover Apple docs](https://developer.apple.com/documentation/appkit/nspopover)
  — API reference (decided against using this)
- [Creating Status Bar Apps on macOS](https://www.appcoda.com/macos-status-bar-apps/)
  — Tutorial reference for NSStatusItem patterns
- **i-dream-bar.swift** (local reference at ~/Code/Claude/i-dream/tools/menubar/)
  — Proven single-file Swift menu bar app pattern, build system, LaunchAgent setup

## Key Decisions

| Decision | Choice | Alternative considered |
|----------|--------|----------------------|
| NSMenu vs NSPopover | NSMenu | NSPopover (rejected: slow, non-native feel) |
| Scanner | Reuse scan.sh | Rewrite in Swift (rejected: unnecessary complexity) |
| Tab focus | Ghostty AppleScript | Accessibility API (rejected: harder, Ghostty has native support) |
| Build system | swiftc single-file | Xcode project (rejected: overhead for single-file app) |
| Data refresh | Background timer | Event-driven (rejected: no reliable event source) |
| Custom views | SwiftUI in NSHostingView | Pure AppKit (rejected: SwiftUI is faster to write) |
| Menu bar icon | Static Claude PNG | SF Symbols (tried `sparkles`, rejected: too generic, lost brand identity) |
| Model colors | Custom RGB values | System colors (rejected: poor distinction, didn't match brand) |
| Dashboard | NSPanel (floating) | NSWindow (rejected: NSPanel floats above, better for utility) |
| Permission indicator | `⚠` text prefix | Pulse animation (tried, rejected: too distracting) |
| Resume sessions | AppleScript → Ghostty tab | Direct process launch (rejected: needs terminal context) |
| All Sessions | On-demand deep scan | Periodic scan (rejected: too expensive for background timer) |
