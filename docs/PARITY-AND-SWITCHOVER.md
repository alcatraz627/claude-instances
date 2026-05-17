# V1 → V2 Parity & Switch-over Decision

> **Date:** 2026-05-17 · **Status:** V2 is feature-complete *as a plugin platform* but does **not** match V1 for live-session monitoring. Recommendation: **dual-run, don't switch yet.**

---

## TL;DR

V2 is a different kind of tool than V1, not a strictly-better replacement.

- **V2 wins** on extensibility, design system, debuggability, settings UX, Plugin Manager, and the menubar architecture.
- **V1 wins** on the daily-driver loop you actually live in: seeing your running Claude sessions in real time, with cost/turns/rate-limit visible at a glance.
- **The honest gap is the scanner.** Until V1's `lib/scan.sh` (or equivalent) is ported to feed V2's `sessions` / `overview` / `rate-limit` plugins, V2 can't replace V1 for live-session work.

**Recommended switch-over plan:** keep both binaries running side-by-side, use V2 for new tooling (atone, proposals, memory, scheduled), keep V1 as the live-session view, port the scanner when there's appetite for a 1-day project.

---

## What V2 ships today

After Phases 0–12 (commits `c2a3372` … `2691aa2`):

**Kernel** (HostKernel, ~2.5 kLOC Swift)
- Manifest schema + Registry + closed `contributes.*` namespace + 19-error closed enum
- Plugin protocol (native + script execution)
- PaneContent (5 pane kinds + custom escape hatch)
- EventBus (NotificationCenter-backed)
- FileLogger (sync writes, ring-truncated)
- ResourceSampler (per-plugin metrics)
- SettingsSchema (minimal JSON Schema decoder)
- ScriptExec (timeout + payload cap + spawn budgets)
- CrashReporter (NSException + 5 POSIX signal handlers)
- ~~FSEventsWatcher~~ (disabled — KNOWN-ISSUE FSEVENTS-001)
- MenubarTypes (rich row + badge value)

**Shell** (HostShell, ~2 kLOC Swift)
- NSApplication bootstrap with `LSUIElement`
- NSPanel dashboard with NavigationSplitView
- DesignTokens (7 namespaces, settings-aware text/density scaling)
- 5 pane renderers + ErrorPaneView + skeleton state
- PlatformRegistry (load + dispatch + commands + bus + sampler + loggers)
- DashboardSurface (sidebar grouped by section, .id() forces tab atomic swap)
- MenubarSurface (rich rows via pure-AppKit NSView, HotkeyAwareMenu for ⌘keys)
- StatusbarBadgeSurface (one NSStatusItem per badge)
- SettingsTab + PluginManagerTab + SchemaForm
- HostSettingsStore (debounced state.json + NSApp.appearance bridge)

**8 plugins shipped**
| ID | Type | Source | Notes |
|---|---|---|---|
| about | native | host info | static |
| overview | native | demo data | placeholder until scanner |
| events | native | demo data | placeholder until scanner |
| sessions | script | `~/.claude/projects/` | reads transcripts on disk (548 found) |
| atone | script | `~/.claude/atone/` | 95 events, S3 count badge |
| scheduled | script | `crontab` + `~/Library/LaunchAgents/` | 19 launchd + 3 cron |
| proposals | script | `~/.claude/proposals.jsonl` | 90 entries (17 open) |
| memory | script | `~/.claude/memory/` | 17 entries |

**Other**
- `claude-widget` scaffolding CLI (`new` / `validate` / `doctor` / `install-hook`)
- Pre-commit hook validating changed plugins
- Comprehensive logging (host.log + per-plugin .log + crash.log)
- Architecture doc + implementation plan + known-issues + previous review reports

---

## What V1 has that V2 doesn't

| V1 feature | V2 status | Cost to port |
|---|---|---|
| Live Claude session list (running PIDs) | **MISSING** | High — needs scan.sh port or Swift equivalent |
| Cost per session ($) | **MISSING** | Medium — depends on scan.sh having the data |
| Turn count per session | **MISSING** | Same |
| Last-tool indicator | **MISSING** | Same |
| Permission-mode badge | **MISSING** | Same |
| Rate-limit countdown | **MISSING** | Medium — needs limits.json source |
| 5h / weekly usage % | **MISSING** | Same |
| Compaction warning indicator | **MISSING** | Same |
| Per-session transcript viewer | **MISSING** | High — V1 has a custom HTML server + JS |
| All Sessions search-as-you-type | **MISSING** (DX-reviewer said don't port) | High + worse UX |
| History tab (resumeable past sessions) | **PARTIAL** (V2 lists files; V1 has resume action) | Medium |
| Events tab (per-session event timeline) | **DEMO ONLY** | Medium — needs scan.sh |
| StatCards (top of Overview) | **DEMO ONLY** | Medium |

**Common dependency:** all of the above need V1's scanner (`lib/scan.sh`) or a Swift equivalent that produces the same JSON shape (`scan/limits.json`, `scan/live.json`, `scan/events.json`, `scan/history.json`).

---

## What V2 has that V1 doesn't

| V2 feature | V1 status |
|---|---|
| Plugin architecture (drop a folder, get a tab) | None |
| Plugin Manager UI (health, toggle, drill-in) | None |
| Per-plugin settings auto-form from JSON Schema | None |
| Settings tab with text-size / density scaling | Hardcoded |
| Color scheme bridge (System / Light / Dark) NSApp-level | Hardcoded |
| Pre-commit plugin validation | None |
| Scaffolding CLI | None |
| Atone integration (95 events, S3 count badge) | None |
| Proposals queue browser | None |
| Memory browser | None |
| Scheduled jobs unified (cron + launchd) | None |
| Sessions transcript count (today / week / total) | None |
| Comprehensive logging (host + per-plugin + crash) | Per-instance logs only |
| Crash reporter (NSException + signals → crash.log) | None |
| Design system with token registry | Hardcoded |
| Menubar.item richer rendering | Per-row LiveRowView (similar, less extensible) |
| State.json with state_version migration safety | None |

---

## Switch-over options

### Option A — Stay dual-binary forever (recommended for now)

V1 and V2 both run, both have their own menu-bar icons (puzzle vs claude logo). Each does its job:
- V1 handles live session work.
- V2 handles everything else.

Cost: two menu-bar icons. Benefit: zero regression risk, no missing features.

How to apply: do nothing. Both are launching today.

### Option B — Retire V1 now

Unload V1's launchd plist, accept the gap in live-session features.

```bash
launchctl unload ~/Library/LaunchAgents/dev.claude-instances.menubar.plist
```

Cost: lose live session monitoring + rate-limit + per-session cost/turns until scanner port. Benefit: one menu-bar icon, single source of truth.

**Don't recommend this** unless you've stopped relying on V1's live view.

### Option C — Port the scanner, then retire V1

1. Copy V1's `lib/scan.sh` (or its Swift equivalent) into V2's repo as `lib/scan.sh`.
2. Write a host service in HostKernel that runs it on a 5s cadence and exposes `~/.claude/state/scan.json`.
3. Build native plugins for Live / Rate-limit / Overview that read from that JSON.
4. Verify parity with V1 for 1 week.
5. Then unload V1.

Estimated effort: **1 day** for steps 1–3 if the V1 scanner ports cleanly. Add another day for verification + iteration.

### Option D — Embrace V2 as the platform; replace V1 piecemeal

Same as C but no commitment to retire V1 until each individual piece is verified. Most cautious; longest tail.

---

## Recommended decision

**Stay on A (dual-binary) for now, with a soft target of C (port scanner) when there's a stretch of time for a 1-day project.**

The V2 platform is the right long-term home. V1's scanner is the only thing keeping it ahead, and that's a finite gap to close. But there's no urgency — V2 isn't blocking anything by missing those features, and V1 isn't blocking V2 development.

---

## What "done" looks like for Phase 13

This phase is verification, not building. Concrete actions:

1. ✅ This document exists (commit `<this commit>`)
2. ✅ Both V1 and V2 are running, side-by-side, in your menu bar today
3. ✅ `legacy/v1` git branch preserves V1 at the fork point (commit `4d4ebeb`)
4. ✅ `main` git branch keeps the active V1 binary
5. ✅ `v2` git branch holds everything from Phases 0–12
6. ⏸ Decision on switch-over deferred — see Option A above

If you take Option C later: that's its own Phase 14 (scanner port). I'd outline that as 4–5 sub-tasks once you decide to start.

---

## Open polish items (small, can wait)

- Rich menubar rows currently have no commands wired (sessions / proposals / atone rows are informational only). Adding `command_id` to each plugin's row JSON + the corresponding `contributes.commands` entry would make ⌘1 do something real.
- TABLE-001 hover layout shift (known issue, cosmetic).
- FSEVENTS-001 disabled FSEvents → polling fallback (known issue, stability win).
- Settings tab feels sparse now that per-plugin sections moved to Plugin Manager — could add a "host activity log" mini-pane (last 50 host events) for quick diagnostics.
- The dashboard has a 3-section sidebar (Dashboard / Tools / System) plus a "Plugins" tab for management; with more plugins this will need either grouping refinement or alphabetization within sections.

---

*End of Phase 13. V2 development pauses here pending scanner port (Option C) or user direction to retire V1 (Option B) or continue extending the platform (more script plugins, more surfaces).*
