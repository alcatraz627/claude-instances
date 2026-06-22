# Claude Instances Widget — Major Upgrade Plan

<!-- sessions: forge-auto-8c@2026-04-22, tran-rport-7c@2026-05-08, refr-cade-9d@2026-05-09 -->

## Status (as of 2026-05-09)

**Mostly shipped** — Areas 1-5 below are largely landed. The bar binary, scan.sh,
and the new transcript HTML generator together implement nearly everything in the
original plan.

| Area | Status | Notes |
|------|--------|-------|
| 1. Per-session enhancements | ✓ shipped | Tab title, statusline metrics, click→submenu (Finder/Terminal/VSCode), subagent count, session state, blinking, branch + modified-files + last-prompt |
| 2. Top-level usage limits | ✓ shipped | 5h + 7d bars with reset countdowns, color thresholds, configurable warning slider |
| 3. Events deep history | ✓ shipped | Both shallow (menu) and deep (dashboard Events tab) lists from scan.sh |
| 4. Overall usage stats | ✓ shipped | today/week aggregates + model breakdown in scan.sh + Overview tab |
| 5. Update strategy | ✓ shipped | Quick (5s) / Full (30s) tiered scan. User-selectable cadence (1/2/5/10/30/60s + Pause) |

**Still parked** — see "Outstanding work" at the bottom for the two live-update
items and remote-session brainstorm.

---

## Area 1: Per-Session Enhancements (Menu Dropdown)

### 1A. Tab Title Display

**Data source:** `/tmp/claude-tab-topic-<session-uuid>` files. Each contains the human-readable topic (e.g., "File Explorer UI Polish & Actions"). A companion `.session_id` file maps the UUID to the session.

**Implementation:**
- In `scan.sh` → `get_live_instances()`: after finding the session JSONL (which gives us the session UUID), read `/tmp/claude-tab-topic-<uuid>` for the topic string.
- Add `tab_title` field to each live instance JSON output.
- In Swift `LiveInstance` model: add `tabTitle: String?`.
- **Menu display:** Show tab title as the primary label for each session row (replacing or augmenting the CWD path). Format:
  ```
  ◆ opus  File Explorer UI Polish    12:34
     ~/.claude/widgets/claude-instances
     PID 15475 · CPU 3% · 171 MB · 24t · ↑12K
  ```
  - Tab title in **white/primary** weight `.medium`, font size 13
  - CWD drops to the dim sub-line (already exists as Row 2/3)
  - If no tab title available, fall back to current CWD-primary display

**Update strategy:** Tab titles change infrequently (every ~5 turns). Read from `/tmp/` on every 5s scan — negligible cost (stat + read < 0.1ms per file).

### 1B. Statusline Metrics Expansion

**Current metrics in scan.sh:** `proc_cpu`, `proc_mem`, `proc_rss`, `tok_speed`, `cost_vel_cpm`, `mcp_healthy`, `mcp_down`, `focus_file`, `wal_since_checkpoint`.

**New metrics to add from daemon file (`/tmp/claude-statusline-<pid>`):**

| Metric | Daemon Key | Display | Icon | Color |
|---|---|---|---|---|
| Context remaining | *(not in daemon — see note)* | `72%` | `gauge` / bar | green→orange→red gradient |
| Turns | *(count from JSONL — already have)* | `24t` | `arrow.triangle.2.circlepath` | blue |
| Tool calls | *(count from JSONL)* | `38 tools` | `wrench.fill` | purple |
| Cost estimate | *(compute from tokens)* | `$0.42` | `dollarsign.circle` | mint→orange→red |
| Session ID | *(from JSONL)* | `fix-auth-3b` | `tag` | dim gray |
| Running shells | *(not available — see note)* | — | — | — |
| Subagent count | *(not in daemon — see note)* | `2 sa` | `person.2` | cyan |
| Scratchpad count | `scratchpad_count` | `27 sp` | `note.text` | dim |
| PM2 status | `pm2_online`, `pm2_errored` | `6↑ 0✗` | `server.rack` | green/red |

**Key notes on unavailable metrics:**

1. **Context remaining %** — The daemon (`process-stats-daemon.sh`) does NOT write this. It's only available in the statusline's stdin JSON payload from Claude Code hooks. **Solution:** Add a new section to the daemon that reads from `/tmp/claude-context-<pid>` — the statusline already writes this: `printf "%.0f" "$remaining" > "$CTX_FILE"` at line ~610. So we just need to read that file. The file path is `/tmp/claude-ctx-<PPID>` or similar — need to verify the exact variable name.

   **Actually**, looking at the statusline code more carefully:
   ```bash
   CTX_FILE="/tmp/claude-ctx-${PPID}"
   [[ -n "${remaining:-}" && "$remaining" != "null" ]] && printf "%.0f" "$remaining" > "$CTX_FILE"
   ```
   So the context % IS written to `/tmp/claude-ctx-<pid>`. scan.sh can read it directly.

2. **Running shells** — No data source. Claude Code doesn't expose active shell processes. We could count child bash processes of the claude PID, but this would be unreliable (hooks, statusline daemon itself are also bash children). **Decision: SKIP this metric.**

3. **Subagent count** — The statusline reads this from the process list (looking for child claude processes). scan.sh could do the same: for each live claude PID, `pgrep -P <pid> -f claude` to find child agents. **Implementation:** Add to `get_live_instances()` — one extra `pgrep` per live instance.

4. **Tool call count** — Not tracked in daemon or files. Must be counted from the JSONL session file. The JSONL has `type: "tool_use"` and `type: "tool_result"` entries. **Implementation:** In `get_session_tokens()`, also count tool_use entries. Cheap since we already read the JSONL.

**scan.sh changes (new fields per live instance):**
```python
'statusline': {
    # existing...
    'ctx_remaining': statusline.get('ctx_remaining', ''),  # NEW — from /tmp/claude-ctx-<pid>
    'scratchpad_count': statusline.get('scratchpad_count', ''),  # NEW
    'pm2_online': statusline.get('pm2_online', ''),  # NEW
    'pm2_errored': statusline.get('pm2_errored', ''),  # NEW
},
'tab_title': tab_title,  # NEW
'tool_calls': tool_call_count,  # NEW — from JSONL
'subagent_count': subagent_count,  # NEW — from pgrep
'cost_usd': cost_estimate,  # NEW — computed from tokens + model
```

**Swift model changes (`LiveInstance`):**
```swift
var tabTitle: String?
var toolCalls: Int?
var subagentCount: Int?
var costUsd: Double?
// StatuslineMetrics additions:
var ctxRemaining: String?
var scratchpadCount: String?
var pm2Online: String?
var pm2Errored: String?
```

**Menu row color scheme (matching statusline conventions):**

| Metric | Color Logic |
|---|---|
| Model badge | opus=amber, sonnet=blue, haiku=teal (existing) |
| CPU | green <20%, orange 20-50%, red >50% |
| Memory | green <500MB, orange 500-1000, red >1000 |
| Context % | green >50%, orange 25-50%, red <25% |
| Cost | mint <$0.25, orange $0.25-$1, red >$1 |
| MCP | green (healthy), red (down) |
| Subagents | cyan always |

### 1C. Click Folder → Open in Finder

**Current behavior:** Clicking the CWD row calls `focusGhosttyTab(forCwd:)` — focuses the Ghostty terminal tab.

**Change:** Add a **submenu item** "Open in Finder" to each instance's existing submenu (which already has Focus Terminal, View Transcript, Copy PID, Terminate).

```swift
let finderItem = NSMenuItem(title: "Open in Finder", action: #selector(openInFinder(_:)), keyEquivalent: "")
finderItem.target = self
finderItem.representedObject = inst.cwd
setIcon(finderItem, "folder")
submenu.addItem(finderItem)
```

Handler:
```swift
@objc private func openInFinder(_ sender: NSMenuItem) {
    guard let cwd = sender.representedObject as? String else { return }
    NSWorkspace.shared.open(URL(fileURLWithPath: cwd))
}
```

**Also:** In the Dashboard's InstanceCard, add a small folder icon button next to the CWD path that opens Finder.

### 1D. Subagent History

**Data source:** The JSONL session file contains subagent spawn/completion entries. Events.jsonl also logs `SubagentStop` events.

**For live instances:** Count running subagents via `pgrep -P <pid> -f claude` (quick).

**For menu display:** Show subagent count inline on the metrics row:
```
   PID 15475 · CPU 3% · 24t · 2 sa(Explore,code-review)
```
If count > 0, show names. Use cyan color matching statusline convention.

**For Dashboard LiveTabView:** Add a collapsible "Subagents" section to each InstanceCard showing:
- Active subagent count and types
- This is lightweight — no deep JSONL parsing needed for live view

**For events history:** SubagentStop events already appear in events.jsonl. Expand the event type filter in scan.sh to also capture `SubagentStart` (if logged) — currently only `SubagentStop` is captured in events.

### 1E. Blinking Animations & Better Visualization

**Menu bar icon:**
- When any session has a PermissionRequest pending: blink the `⚠` indicator (use NSTimer to toggle visibility every 0.8s)
- When rate limit > 90%: pulse the count text between red and dim

**Menu dropdown:**
- Active sessions: add a small green pulsing dot (● ) before the model badge
- Permission pending: orange blinking ⚠ on the relevant session row

**Dashboard (SwiftUI):**
- InstanceCard: add a subtle animated gradient border when the instance is actively generating (tok_speed > 0)
- Rate limit bars: animate fill changes with `.animation(.easeInOut(duration: 0.3))`
- Event timeline dots: fade-in animation when new events appear

**Implementation approach:**
- Menu bar blinking: `NSTimer` toggling `btn.attributedTitle` every 800ms when conditions met
- SwiftUI animations: native `.animation()` modifiers — zero overhead when idle
- Condition for "active": `tok_speed > 0` (instance is producing tokens right now)

### 1F. Session State Display (Thinking / Tool Call / Job)

**Feasibility analysis:**

Claude Code does NOT expose real-time internal state (thinking, tool execution) via any file or API that an external observer can read. The available signals are:

1. **`tok_speed > 0`** → instance is actively generating output (could be thinking or responding)
2. **`PostToolUse` events in events.jsonl** → tool was just used (after the fact, not real-time)
3. **Process CPU > threshold** → likely active vs idle
4. **Focus file changes** → indicates file read/write activity
5. **JSONL last entry type** → the most recent entry in the session JSONL tells us what happened last

**Proposed "inferred state" approach:**

Read the last 1-2 entries from the session JSONL (fast — seek to end, read backward). Map to display state:

| Last JSONL Entry | Inferred State | Display |
|---|---|---|
| `type: "assistant"` with no tool_use | 💬 Responding | `💬 responding` (green) |
| `type: "assistant"` with tool_use | 🔧 Tool: `<name>` | `🔧 Read: path.ts` (purple) |
| `type: "tool_result"` | ⏳ Processing | `⏳ processing tool result` (blue) |
| `type: "user"` | 🤔 Thinking | `🤔 thinking...` (amber) |
| Nothing recent + CPU low | 💤 Idle | `💤 waiting for input` (dim) |
| Nothing recent + CPU high | ⚙ Working | `⚙ working...` (amber) |

**Implementation in scan.sh:**
```python
def get_session_state(filepath, pid):
    """Read last 2 JSONL entries to infer current session state."""
    # Seek to last 10KB of file, parse last 2 valid JSON lines
    # Return: {'state': 'thinking|responding|tool_use|idle', 'detail': '...'}
```

**Display:** New row in the menu between the model badge row and the metrics row:
```
  ◆ opus  File Explorer UI Polish    12:34
     🔧 Edit: src/components/Nav.tsx
     ~/.claude/widgets/...
     PID 15475 · CPU 3% · 24t
```

**Caveat:** This is a best-effort inference, not real-time state. The JSONL is written after each message round-trip, so there's a delay. State display should be labeled "Last activity" not "Currently doing".

**Update frequency:** Every 5s scan — reads last ~5KB of JSONL per instance. Acceptable cost.

---

## Area 2: Top-Level Anthropic Usage Limits

**Current state:** Rate limits are shown in the menu as a text-based bar:
```
  5h  ▓▓▓▓▓▓▓░░░░░░░░░  42%  1.2M/2.8M
```

**Data source:** `~/.claude/widgets/.limits.json` — already read by scan.sh. Contains `five_h` and `week` with `pct`, `used`, `cap` fields.

**Enhancement:**

### Menu Display (top of dropdown, before live instances)

```
┌─────────────────────────────────────────┐
│  ⏱ 5h   ████████░░░░░░░░  42%  1.2M/2.8M
│  📅 7d   ███░░░░░░░░░░░░░  18%  3.1M/17M
│  🔄 Resets: 2h 14m │ ⚡ Tier: Pro
└─────────────────────────────────────────┘
```

**Color-coded progress bar using attributed strings:**
- 0-50%: green (`systemGreen`)
- 50-75%: yellow (`systemYellow`)
- 75-90%: orange (`systemOrange`)
- 90-100%: red (`systemRed`)

**New data needed in scan.sh:**
- Reset time for 5h window (compute from `resets_at` field if available in limits cache)
- Current tier (if detectable — may not be available; skip if not)

**Implementation:**
- Promote rate limits to the TOP of the menu (before live instances)
- Use `▓`/`░` characters with colored attributed strings (existing approach, just move position)
- Add a "reset countdown" line if resets_at data is available
- Progress bar width: 20 characters for better visual resolution

### Dashboard Enhancement

Already has `RateLimitRow` with `GeometryReader` progress bar. Enhancements:
- Add animated fill transitions
- Show reset countdown timer
- Add historical usage sparkline if data is available (would need to track limits over time — deferred to v2)

---

## Area 3: Events Deep History

### Current State
- scan.sh reads last 10 events from `~/.claude/events.jsonl`
- Filters: `SessionStart`, `Stop`, `PermissionRequest`, `PostCompact`
- Menu shows last 5 in the dropdown
- Dashboard Events tab shows all 10 in a timeline

### Enhancement: Sub-Menu with Deep History

**Menu structure:**
```
▸ Recent Events (5)
    ▶ 03:18  File Explorer UI Polish    SessionStart  ◆ opus
    ■ 03:02  scan-sessions              Stop          ● sonnet
    ⚠ 02:55  frontend                   Permission    ◆ opus
    ⟳ 02:41  scripts                    Compact       ◆ opus
    ▶ 02:30  enhancement-product        SessionStart  ● sonnet
    ─────────────────────────────
    ▸ Show more (50 events) →   [submenu with deeper history]
```

**Per-event additions:**
- **Model name:** Already in events.jsonl for some event types. For events that don't have it, look up from the session's JSONL (first assistant message model field). Cache the session→model mapping.
- **Tab title:** Read from `/tmp/claude-tab-topic-<session-uuid>` using the session_id from the event. Fall back to project name if file doesn't exist (old sessions).

**scan.sh changes:**
```python
def get_recent_events(max_events=10, deep_max=50):
    """Get recent events. Also capture model + tab title per event."""
    # For deep history: read last 200 lines, filter to supported types
    # For each event with a session_id:
    #   - Look up model from JSONL (cache in a dict)
    #   - Look up tab title from /tmp/claude-tab-topic-<sid>
```

**New event types to capture:**
- `SubagentStart` / `SubagentStop` — show subagent lifecycle
- `PostToolUse` — show major tool uses (filter to Edit, Write, Bash only — skip Read/Grep noise)
- `PreCompact` — show auto-compact triggers

**Menu implementation:**
- Main event list: 5 most recent (existing, but with model + title added)
- "Show more →" item: opens a submenu with 50 events in the same format
- Each event row: `icon  time  tab_title_or_project  event_type  model_badge`

**Dashboard Events tab:**
- Increase default count from 10 to 50
- Add model badge (colored pill) and tab title to each event row
- Add filter toggles: by event type, by model, by project
- Add search field

---

## Area 4: Overall Claude Usage Stats

**New "Usage" section in the menu** (after rate limits, before live instances):

```
📊 Usage
   Today:  12 sessions · 847t · $2.34 · 4h 12m
   Week:   38 sessions · 2.1K turns · $8.92
   Models: opus ×24 · sonnet ×11 · haiku ×3
```

**Data source:** Computed from `history[]` in scan.sh output. Already has per-session: model, turns, tokens_in, tokens_out, cost_usd, modified timestamp.

**Implementation in scan.sh:**
Add an `aggregate` field to the JSON output:
```python
def compute_aggregates(history):
    today = datetime.now(timezone.utc).date()
    week_ago = today - timedelta(days=7)
    
    today_sessions = [s for s in history if s['modified'][:10] == str(today)]
    week_sessions = [s for s in history if s['modified'][:10] >= str(week_ago)]
    
    return {
        'today': {
            'sessions': len(today_sessions),
            'turns': sum(s['turns'] for s in today_sessions),
            'cost_usd': sum(s.get('cost_usd', 0) for s in today_sessions),
            'tokens_out': sum(s.get('tokens_out', 0) for s in today_sessions),
        },
        'week': {
            'sessions': len(week_sessions),
            'turns': sum(s['turns'] for s in week_sessions),
            'cost_usd': sum(s.get('cost_usd', 0) for s in week_sessions),
            'tokens_out': sum(s.get('tokens_out', 0) for s in week_sessions),
        },
        'model_breakdown': model_counts,  # {'opus': 24, 'sonnet': 11, ...}
    }
```

**Menu display:** Compact 2-3 line summary (not a submenu — inline).

**Dashboard Overview tab:** Already shows stat cards. Add:
- "Today" vs "This Week" toggle/comparison
- Model breakdown pie chart or horizontal bar
- Cost trend (if we track daily costs over time — would need a small cache file)

---

## Area 5: Update Strategy (Critical Design Decision)

### Current Architecture
```
scan.sh (Python) → JSON stdout → BarDelegate.refreshData() (every 5s)
                                  └→ cachedData (ScanResult)
                                      ├→ NSMenu (menuNeedsUpdate, on-demand)
                                      └→ Dashboard (ObservableObject, if open)
```

### Current Timing
- Full scan cycle: ~150-300ms (pgrep + lsof per instance + JSONL reads)
- Runs every 5 seconds
- History/events only change between scans if a session starts/stops

### Proposed Tiered Refresh

**Tier 1 — Hot data (every 5s, existing cycle):**
- Live instance list (pgrep + lsof + statusline files)
- Tab titles (stat + read tiny files)
- Session state inference (read last 5KB of each live JSONL)
- Context remaining % (read /tmp/claude-ctx-<pid>)
- Subagent count (pgrep -P)

**Tier 2 — Warm data (every 30s):**
- Event history (read events.jsonl tail)
- Session history (enumerate JSONL files, read headers)
- Usage aggregates (computed from history)

**Tier 3 — Cold data (every 60s):**
- Rate limits (read .limits.json cache)
- All Sessions deep scan (only when Dashboard "All Sessions" tab is active)

**Implementation:** Add a `--tier` flag to scan.sh:
```bash
scan.sh --tier hot    # returns: live[], tab_titles, session_states, ctx%
scan.sh --tier warm   # returns: events[], history[], aggregates{}
scan.sh --tier cold   # returns: limits{}
```

Or simpler: scan.sh always returns everything, but BarDelegate calls it every 5s and only updates hot data. Warm/cold data uses separate timers. The Python script is fast enough (~200ms) that running the full scan every 5s is fine. The bigger cost savings come from NOT doing expensive JSONL parsing (history) every 5s.

**Recommended approach:** Keep single scan.sh call but add `--quick` flag that skips history enumeration and deep JSONL reads:
```bash
scan.sh          # full scan (live + history + events + limits + aggregates) ~250ms
scan.sh --quick  # quick scan (live + tab titles + session state only) ~80ms
```

BarDelegate alternates:
- Every 5s: `--quick` scan
- Every 30s: full scan (replaces the quick scan on that tick)

### Performance Budget

| Operation | Per-instance | Total (3 instances) |
|---|---|---|
| pgrep + lsof | ~20ms | ~60ms |
| Read statusline file | <1ms | <3ms |
| Read tab topic file | <1ms | <3ms |
| Read context % file | <1ms | <3ms |
| pgrep for subagents | ~5ms | ~15ms |
| Read last 5KB of JSONL | ~2ms | ~6ms |
| **Quick total** | | **~90ms** |
| History enumeration | — | ~80ms |
| Events tail read | — | ~10ms |
| Aggregates compute | — | ~5ms |
| Limits file read | — | <1ms |
| **Full total** | | **~185ms** |

Well within the 5s budget. No resource drain concerns.

---

## Implementation Phases

### Phase 1: Data Pipeline (scan.sh)
1. Add `tab_title` field (read from /tmp/claude-tab-topic-*)
2. Add `ctx_remaining` (read from /tmp/claude-ctx-*)
3. Add `tool_calls` count (from JSONL)
4. Add `subagent_count` (from pgrep -P)
5. Add `session_state` inference (from JSONL tail)
6. Add `cost_usd` per live instance (from tokens + model rates)
7. Expand event capture (model, tab_title per event; more event types)
8. Add `aggregates` section (today/week stats, model breakdown)
9. Add `--quick` flag for lightweight scans
10. Add new statusline fields: `scratchpad_count`, `pm2_online`, `pm2_errored`

### Phase 2: Swift Data Models
1. Extend `LiveInstance` with new fields
2. Extend `StatuslineMetrics` with new fields
3. Add `SessionState` struct
4. Extend `Event` with model + tabTitle
5. Add `Aggregates` struct
6. Update `ScanResult` to include aggregates

### Phase 3: Menu Dropdown Upgrade
1. Reorder: Rate Limits → Usage Stats → Live Instances → Events → History → Actions
2. Per-instance: tab title as primary label, state indicator, expanded metrics
3. Add "Open in Finder" to instance submenu
4. Events: add model + title, add "Show more" submenu
5. Usage stats section (today/week summary)
6. Blinking/pulsing for permission requests and rate limit warnings

### Phase 4: Dashboard SwiftUI Upgrade
1. InstanceCard: add tab title, state indicator, expanded metrics, Finder button
2. Rate limit bars: add animation, reset countdown
3. Events tab: add model badges, tab titles, filters, search, expanded history
4. Overview: add today/week comparison, model breakdown
5. Animations: gradient borders on active instances, fade-in on new events

### Phase 5: Polish & Performance
1. Implement `--quick` scan alternation
2. Menu bar icon: blinking on permission, pulsing on rate limit
3. Verify memory/CPU usage under load (5 live instances)
4. Edge cases: missing files, stale data, zombie processes

---

## Files Modified

| File | Changes |
|---|---|
| `lib/scan.sh` | New fields, --quick flag, aggregates, expanded events |
| `native/claude-instances-bar.swift` | Data models, menu construction, dashboard views, animations |
| `PLAN.md` | Update with Phase 7 (this upgrade) |

No new files needed — this is purely extending the existing 2-file architecture.

---

## Open Questions for User Review

1. **Menu order:** Currently: Live → Limits → Events → History → Actions. Proposed: Limits → Usage → Live → Events → History → Actions. Preference?

2. **Session state label:** "Last activity: 🔧 Edit src/Nav.tsx" vs just "🔧 Edit src/Nav.tsx" — how verbose?

3. **Event types in dropdown:** Currently 4 types (SessionStart, Stop, Permission, Compact). Add SubagentStop, PostToolUse(Edit/Write/Bash only)? Or keep it minimal?

4. **Usage stats in menu:** Inline 2-3 lines, or a submenu? Inline is faster to scan, submenu is less cluttered.

5. **Animation intensity:** Subtle (border glow, opacity changes) vs prominent (blinking text, pulsing icons)?

---

## PARKED — Remote session support

<!-- sessions: tran-rport-7c@2026-05-08 -->

> Discussed but deferred. Pick this up next time we open the bar for improvements.

Today the bar reads only local sources: `~/.claude/projects/*.jsonl` for transcripts, `~/.claude/widgets/.limits.json` for rate limits, `lsof`/`ps` for live process state. Going remote breaks every one of those assumptions, so the design question is **which signal stream is worth shipping over the wire**.

### Three viable shapes

#### A. SSH-tail mode (1–2 days)
Treat each remote host as a "virtual instance" by tailing its transcript JSONL and `.limits.json` over SSH.

- Config: `~/.claude/widgets/remotes.json` listing `[{host, user, key, claude_dir}]`
- Polling: per-remote `Process` running `ssh user@host "tail -F …"` piped into the bar's data model
- UI: remotes appear under a "🌐 Remote" section, host badge prefix on each row
- **Pros:** zero remote-side install, uses existing SSH config
- **Cons:** SSH tail brittle on host sleep (reconnect storms), transcript paths differ across users, "Open in Terminal" can't focus a remote tab
- **Best fit:** dev boxes / VPS where you already SSH all day

#### B. Lightweight remote agent (~1 week)
Small `claude-instances-agent` Go/Rust binary on each remote host. Bar speaks to it over a multiplexed connection.

- Protocol: WebSocket or gRPC streaming. Server emits `LiveUpdate` (instances + limits + recent events) every Ns; client requests `GetTranscript(sessionId)` on demand
- Auth: shared secret in `~/.claude/widgets/remote-token` or mTLS via existing SSH cert
- Discovery: zeroconf on LAN + explicit list for WAN
- UI: same as A but more responsive; agent can compute deltas server-side; "Open in Terminal" shells `ssh user@host "cd <cwd>; tmux new-session -As <id>"`
- **Pros:** efficient (one connection, push not poll), secret stays out of bash history
- **Cons:** extra binary to install/update on each remote; need a release pipeline
- **Best fit:** small fleet of dev/CI machines you control

#### C. Cloud sync via shared storage (2–3 weeks)
Transcript JSONLs and `.limits.json` mirrored to a shared bucket (S3, R2, iCloud Drive); bar reads the union across "your devices."

- Mechanism: sync daemon writes `s3://your-bucket/<host>/<session>.jsonl` with append-only semantics; bar polls bucket index
- Identity: per-user prefix; per-host subdir
- UI: single global "your live work" view across laptop + desktop + remote box; transcripts stay searchable even after originating machine is offline
- **Pros:** works through NAT, survives sleep/reconnect, gives a permanent searchable archive for free
- **Cons:** requires bucket + credentials; latency floor of next poll cycle; PII leaves the device — needs encryption-at-rest design + retention policy; you're operating storage now
- **Best fit:** power user with multiple machines OR small team setup

### Recommendation

Start with **A** (SSH-tail). Weekend project, proves whether remote visibility is actually used before investing in B/C. The data model already supports an arbitrary `Instance` list; just need a remote scanner that emits matching JSON. "Open in Terminal" for remote rows degrades gracefully to "Open SSH in Ghostty."

### First concrete commit if A is chosen

1. `~/.claude/widgets/remotes.json` schema + reader on the bar side
2. New scanner mode `lib/scan-remote.sh <host>` that emits the same JSON shape as `lib/scan.sh` but sourced via SSH
3. Bar's `runScanner` becomes `runScanners` — fans out to each configured host in parallel, merges results
4. Header bar adds `· 🌐 N remotes` count when any are configured
5. Per-remote status: a small "⚠ unreachable" badge if SSH fails N times in a row

---

## ✓ SHIPPED — Live-update while menu is open

<!-- sessions: refr-cade-9d@2026-05-09 -->

> Shipped in commit `cc41d0a` (2026-05-09). New `LiveRowView: NSView` class
> collapses the per-instance attributedTitle chain into one view-based menu
> item; `BarDelegate.runningRows[pid]` tracks them; `refreshLiveRows()` runs
> on every scan tick when `menuIsOpen`. menuWillOpen also kicks off an
> immediate refreshData for fresh-on-open data.
>
> Original parking-lot brief retained below for archaeology.

---

### (Original) Why it was parked

### Why it's parked

NSMenu in AppKit re-evaluates `menuNeedsUpdate(_:)` only when the menu is *about
to open*. While the menu is held visible, item attributedTitles are static. The
scan timer (now user-configurable cadence) keeps `cachedData` fresh in the
background, but the on-screen rows don't reflect the new data until close + reopen.

### What needs to change

1. **Convert per-instance rows to view-based items.** Replace the chain of
   `attributedTitle`-based NSMenuItems (row1 / row1.25 / row1.5 / row2 / focus
   file / MCP-down) with a single `RunningInstanceRowView: NSView` that owns
   its own NSTextField/NSStackView for each piece. NSMenuItem.view wires it in.
2. **Track the view-set per pid.** BarDelegate holds `[Int: RunningInstanceRowView]`.
   When `refreshData()` updates `cachedData`, iterate the dict and call each
   view's `update(with: LiveInstance)` method to mutate its labels in place.
   View-based items DO live-redraw while the menu is open — that's the whole
   point of the change.
3. **Handle add/remove.** When a new instance appears or one dies between
   ticks, splice the menu items inline (NSMenu supports this for view-based
   items without flicker, IF the menu doesn't have to recompute layout
   substantially).
4. **Preserve hover/click semantics.** The current row1 has a submenu attached;
   verify view-based items still propagate hover-over to reveal the submenu.

### First concrete commit

- New `RunningInstanceRowView.swift` (or inline in the bar file) — pure view,
  takes a `LiveInstance`, exposes `update(with:)`.
- Extract the existing row-build logic (lines ~1075–1175 of the bar source)
  into `RunningInstanceRowView.populate(from:)`.
- BarDelegate gains `runningRows: [Int: RunningInstanceRowView]` keyed by pid.
- `refreshData()` end branch: for each cached live instance, find or create
  the row view, call `update(with: inst)`. Stale pids removed.

### Risk / cost

Medium-large. ~200-400 LoC. Visual regression risk: hover behavior, submenu
attachment, scroll-when-many-instances all need re-verifying. Recommend
implementing behind a feature flag (UserDefaults `liveMenuRefresh: Bool`)
so it can be A/B'd against the current static behavior.

---

## ✓ SHIPPED — Live-update while transcript is open

<!-- sessions: tran-rport-7c@2026-05-08, refr-cade-9d@2026-05-09 -->

> Shipped in commit `0eb93bf` (2026-05-09). New `lib/detail-server.py` is a
> small localhost http.server (port 5400 + pid % 500) that serves /tmp/ as
> static files AND exposes `/regen` for synchronous on-demand disk regen.
> Browser opens via `http://127.0.0.1:<port>/...` so fetch-from-self works.
> JS `livePoll()` runs every 30s — calls /regen, fetches HTML, swaps
> #msgs in place. State (theme/search/scroll/chips) preserved.
>
> Original parking-lot brief retained below for archaeology.

---

### (Original) Why it was parked

### Why it's parked

The transcript page lives at `file:///tmp/claude-widget-<pid>.html`. Chrome
(since 67, 2018) blocks `fetch()` between `file://` URLs as a security
measure. The current page does NOT auto-refresh the DOM — the daemon
regenerates the file on disk every 5 minutes, and the user clicks ↻ Refresh
to do a full page reload. That works but isn't truly live.

### What needs to change

1. **Spawn a tiny HTTP server in detail.sh.** Per-PID port (e.g.
   `5400 + (pid % 500)`), bind to `127.0.0.1`, serve the `/tmp/` directory.
   Use Python's built-in `http.server` module so no new dependencies. Dedupe
   via lockfile so re-clicks don't spawn duplicates.
2. **Open the page via `http://127.0.0.1:port/claude-widget-<pid>.html`**
   instead of `file://`. The fetch + same-origin checks now succeed.
3. **JS polling loop.** Every 30s (or user-configurable), `fetch(self_url + '?_=' + Date.now(), {cache: 'no-store'})`.
   Parse with `DOMParser`, extract `#msgs` innerHTML, swap in place. Re-run
   marked + hljs only on the NEW message nodes (not the whole page).
4. **State preservation.** Theme, search, scroll, expanded `<details>`, role
   chip toggles all stay in place because we're patching DOM, not reloading.

### First concrete commit

- detail.sh starts a localhost http.server (idempotent) before opening browser.
- Replace meta-refresh (already removed) with a JS poll loop.
- Diff messages by `data-search` + count: only patch when content actually
  changed (avoids unnecessary marked/hljs re-runs).

### Risk / cost

Medium. ~150 LoC + browser CORS testing. Risk: server lifecycle (when do we
shut it down? on Claude PID death? after N minutes idle?). Use the same
exit-when-Claude-dies mechanic as the regen daemon already has.

---

## PARKED — True line-level red/green diff

> Mentioned in commit `9434db5` ("True line-level diff … is parked because
> it needs to interleave with hljs's <span> output").

Currently OLD/NEW panes get red/green pane *tints* but no per-line markers.
Doing real line-level diff requires running diff before hljs (so hljs sees
clean code) and then wrapping line spans with `.diff-removed` / `.diff-added`
classes. Or running hljs first and post-processing the rendered HTML.
Either way is invasive — diff2html (~30KB CDN) would do it cleanly.

---

## Outstanding work — short list (priority for next pickup)

1. ~~Live-update while menu is open~~ ✓ shipped (2026-05-09, commit `cc41d0a`)
2. ~~Live-update while transcript is open~~ ✓ shipped (2026-05-09, commit `0eb93bf`)
3. **Remote sessions: SSH-tail mode** (above) — totally optional, weekend project
4. **True line-level diff for Edit panes** (above) — nice-to-have. Currently
   shows red/green pane tints + syntax-highlighted code; full per-line
   red-strike/green-add would need diff2html (~30KB CDN) or an inline
   diff-match-patch implementation.

Everything else in the original plan has shipped.

