// Models.swift
// Codable data models, scan-result types, and small enums/helpers.
// (split from claude-instances-bar.swift — one module, same binary)

import AppKit
import Foundation
import SwiftUI

extension String {
    func leftPad(_ width: Int) -> String {
        if count >= width { return self }
        return String(repeating: " ", count: width - count) + self
    }
}

// ─── Data models ─────────────────────────────────────────────────────────────

struct ScanResult: Codable {
    let live: [LiveInstance]
    let history: [SessionHistory]
    let recentEvents: [Event]?
    let deepEvents: [Event]?
    let limits: RateLimits?
    let aggregates: Aggregates?
    let liveCount: Int

    enum CodingKeys: String, CodingKey {
        case live, history, limits, aggregates
        case recentEvents = "recent_events"
        case deepEvents = "deep_events"
        case liveCount = "live_count"
    }
}

struct SessionState: Codable {
    let state: String?    // thinking, responding, tool_use, tool_result, idle
    let detail: String?   // e.g. tool name or empty
}

struct AggregatesPeriod: Codable {
    let sessions: Int?
    let turns: Int?
    let tokensIn: Int?
    let tokensOut: Int?
    let costUsd: Double?

    enum CodingKeys: String, CodingKey {
        case sessions, turns
        case tokensIn = "tokens_in"
        case tokensOut = "tokens_out"
        case costUsd = "cost_usd"
    }
}

struct Aggregates: Codable {
    let today: AggregatesPeriod?
    let week: AggregatesPeriod?
    let modelBreakdown: [String: Int]?

    enum CodingKeys: String, CodingKey {
        case today, week
        case modelBreakdown = "model_breakdown"
    }
}

struct LiveInstance: Codable {
    let pid: Int
    let model: String?
    let modelFull: String?
    let cwd: String?
    let cwdShort: String?
    let elapsed: String?
    let turns: Int?
    let inputTokens: Int?
    let outputTokens: Int?
    let cacheRead: Int?
    let sessionId: String?
    let resumeId: String?
    let toolCalls: Int?
    let costUsd: Double?
    let tabTitle: String?
    let subagentCount: Int?
    let sessionState: SessionState?
    let statusline: StatuslineMetrics?
    let gitBranch: String?
    let gitModified: Int?
    let lastPrompt: String?
    let permissionMode: String?
    let lastTool: LastTool?

    enum CodingKeys: String, CodingKey {
        case pid, model, cwd, elapsed, turns, statusline
        case modelFull = "model_full"
        case cwdShort = "cwd_short"
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheRead = "cache_read"
        case sessionId = "session_id"
        case resumeId = "resume_id"
        case toolCalls = "tool_calls"
        case costUsd = "cost_usd"
        case tabTitle = "tab_title"
        case subagentCount = "subagent_count"
        case sessionState = "session_state"
        case gitBranch = "git_branch"
        case gitModified = "git_modified"
        case lastPrompt = "last_prompt"
        case permissionMode = "permission_mode"
        case lastTool = "last_tool"
    }
}

/// The most recent tool_use block in a session, emitted by scan.sh.
/// Used by LiveRowView to render a "where did I leave off" hint even
/// when the session is currently idle.
struct LastTool: Codable {
    let name: String
    let target: String?
    let agoSeconds: Int?

    enum CodingKeys: String, CodingKey {
        case name, target
        case agoSeconds = "ago_seconds"
    }
}

extension LiveInstance {
    /// Return a copy with `gitBranch` / `gitModified` / `lastPrompt` taken
    /// from `prev` when self's values are empty/zero. Used by the quick-
    /// scan merge path: --quick mode in scan.sh skips the expensive git
    /// + JSONL reads, emitting empty values; we preserve the last full-
    /// scan values so the menu doesn't flicker enrichment fields off
    /// every tick.
    func preservingEnrichment(from prev: LiveInstance) -> LiveInstance {
        let mergedBranch:    String? = (gitBranch?.isEmpty   ?? true) ? prev.gitBranch   : gitBranch
        let mergedModified:  Int?    = ((gitModified ?? 0) > 0)        ? gitModified     : prev.gitModified
        let mergedPrompt:    String? = (lastPrompt?.isEmpty  ?? true) ? prev.lastPrompt  : lastPrompt
        let mergedPerm:      String? = (permissionMode?.isEmpty ?? true) ? prev.permissionMode : permissionMode
        let mergedLastTool:  LastTool? = lastTool ?? prev.lastTool
        return LiveInstance(
            pid: pid, model: model, modelFull: modelFull,
            cwd: cwd, cwdShort: cwdShort, elapsed: elapsed,
            turns: turns,
            inputTokens: inputTokens, outputTokens: outputTokens,
            cacheRead: cacheRead,
            sessionId: sessionId, resumeId: resumeId,
            toolCalls: toolCalls, costUsd: costUsd,
            tabTitle: tabTitle, subagentCount: subagentCount,
            sessionState: sessionState, statusline: statusline,
            gitBranch: mergedBranch,
            gitModified: mergedModified,
            lastPrompt: mergedPrompt,
            permissionMode: mergedPerm,
            lastTool: mergedLastTool
        )
    }
}

struct StatuslineMetrics: Codable {
    let cpu: String?
    let mem: String?
    let rssMb: String?
    let focusFile: String?
    let mcpHealthy: String?
    let mcpDown: String?
    let tokSpeed: String?
    let costVel: String?
    let walSinceCp: String?
    let ctxRemaining: String?
    let scratchpadCount: String?
    let pm2Online: String?
    let pm2Errored: String?

    enum CodingKeys: String, CodingKey {
        case cpu, mem
        case rssMb = "rss_mb"
        case focusFile = "focus_file"
        case mcpHealthy = "mcp_healthy"
        case mcpDown = "mcp_down"
        case tokSpeed = "tok_speed"
        case costVel = "cost_vel"
        case walSinceCp = "wal_since_cp"
        case ctxRemaining = "ctx_remaining"
        case scratchpadCount = "scratchpad_count"
        case pm2Online = "pm2_online"
        case pm2Errored = "pm2_errored"
    }
}

struct SessionHistory: Codable {
    let sessionId: String
    let project: String
    let model: String?
    let turns: Int
    let sizeKb: Double
    let modified: String?
    let tokensIn: Int?
    let tokensOut: Int?
    let costUsd: Double?

    enum CodingKeys: String, CodingKey {
        case project, model, turns, modified
        case sessionId = "session_id"
        case sizeKb = "size_kb"
        case tokensIn = "tokens_in"
        case tokensOut = "tokens_out"
        case costUsd = "cost_usd"
    }
}

struct Event: Codable {
    let event: String
    let ts: String
    let project: String?
    let sessionId: String?
    let model: String?
    let tabTitle: String?
    let tool: String?

    enum CodingKeys: String, CodingKey {
        case event, ts, project, model, tool
        case sessionId = "session_id"
        case tabTitle = "tab_title"
    }
}

struct RateLimitEntry: Codable {
    let pct: Double
    let used: Int
    let cap: Int
}

struct RateLimits: Codable {
    let fiveH: RateLimitEntry?
    let week: RateLimitEntry?
    let resetsAt: String?       // 5h window reset
    let resetsAtWeekly: String? // 7d window reset (added 2026-05)

    enum CodingKeys: String, CodingKey {
        case fiveH = "5h"
        case week
        case resetsAt       = "resets_at"
        case resetsAtWeekly = "resets_at_weekly"
    }
}

// ─── Model display config ────────────────────────────────────────────────────

struct ModelDisplay {
    let badge: String
    let label: String
    let color: NSColor
}

let defaultModel = ModelDisplay(badge: "·", label: "?", color: .secondaryLabelColor)

// ─── Menu color palette ──────────────────────────────────────────────────────
//
// The 12 user-tunable color tokens. Each token has a default (the value
// we ship) and may be overridden via UserDefaults; the Settings tab in the
// dashboard lets the user pick from a Tailwind swatch grid. PaletteStore
// is the single source of truth: every per-color constant below is a
// computed `var` that reads `PaletteStore.shared.color(for:)` so user
// changes propagate to the next render without any cache to invalidate.
//
// System text colors (labelColor / secondary / tertiary / quaternary) are
// intentionally NOT in the palette — those auto-adapt to dark/light mode
// via AppKit's semantic system. Making them user-tunable would break that
// adaptation. The palette governs *aesthetic* colors only.

// ─── User preferences read at runtime ──────────────────────────────────────
//
// Single notification name so callers don't have to know which key changed —
// they just call the read function each time. The Settings UI posts this
// after every @AppStorage write; the bar's BarDelegate observes and re-
// renders.

extension Notification.Name {
    static let menuBehaviorDidChange = Notification.Name("MenuBehavior.didChange")
}

/// Stack-spacing in points for a LiveRowView, derived from the user's
/// chosen density. Read on every LiveRowView.update() so changes propagate
/// to the next render without view recreation.
func densitySpacing() -> CGFloat {
    switch UserDefaults.standard.string(forKey: "density") ?? "comfortable" {
    case "compact":     return 0
    case "cozy":        return 2
    default:            return 4   // comfortable
    }
}

// ─── Row visibility ────────────────────────────────────────────────────────
//
// Each non-critical line in the live menu row can be toggled off via
// Settings → Row Visibility. The user's call about how dense the row
// should be — except for the two critical lines (header + metrics) which
// are always shown because hiding either makes the row useless.
//
// Persisted under "row.<key>" in UserDefaults. Default: ALL visible.
// LiveRowView.update() consults `rowShows(_:)` at every relevant
// addLine() call site.

enum RowElement: String, CaseIterable, Identifiable {
    case tabTitle       = "tabTitle"
    case fullPath       = "fullPath"
    case stateDetail    = "stateDetail"
    case lastPrompt     = "lastPrompt"
    case lastTool       = "lastTool"
    case compactionWarn = "compactionWarn"
    case focusFile      = "focusFile"
    case mcpDown        = "mcpDown"

    var id: String { rawValue }

    /// Critical lines (header + metrics) aren't in this enum — they're
    /// never toggleable. Anything in this enum is user-hideable.
    var displayName: String {
        switch self {
        case .tabTitle:       return "Tab title"
        case .fullPath:       return "Full cwd path"
        case .stateDetail:    return "Active state detail"
        case .lastPrompt:     return "Last user prompt"
        case .lastTool:       return "Last tool ran"
        case .compactionWarn: return "Compaction warning"
        case .focusFile:      return "Focus file"
        case .mcpDown:        return "MCP down warning"
        }
    }

    var hint: String {
        switch self {
        case .tabTitle:       return "Shown when terminal tab title differs from leaf folder"
        case .fullPath:       return "Full ~/path/to/project line under the leaf folder"
        case .stateDetail:    return "‘🔧 tool_use: Reading foo.tsx’-style row when not idle"
        case .lastPrompt:     return "‘❯ <first 80 chars of last user message>’"
        case .lastTool:       return "‘last: Edit src/foo.tsx · 4s ago’ context line"
        case .compactionWarn: return "‘⚠ Context low (N%) — compaction imminent’ ‹safety›"
        case .focusFile:      return "‘📄 <file>’ that the session is currently editing"
        case .mcpDown:        return "‘⚠ MCP down: <name>’ when any MCP server is unreachable ‹safety›"
        }
    }

    var isSafetyRelevant: Bool {
        switch self {
        case .compactionWarn, .mcpDown: return true
        default:                        return false
        }
    }
}

/// True iff the user has chosen to show this row element. Default: true.
/// Critical lines (header + metrics) bypass this check entirely.
func rowShows(_ el: RowElement) -> Bool {
    let key = "row.\(el.rawValue)"
    if UserDefaults.standard.object(forKey: key) == nil { return true }
    return UserDefaults.standard.bool(forKey: key)
}

func setRowShows(_ el: RowElement, _ shown: Bool) {
    UserDefaults.standard.set(shown, forKey: "row.\(el.rawValue)")
    NotificationCenter.default.post(name: .menuBehaviorDidChange, object: nil)
}

// ─── Submenu keybinds ──────────────────────────────────────────────────────
//
// Each per-instance submenu action ("Open in Finder" etc.) is bound to a
// single-character keyEquivalent that fires while the submenu is the
// focused menu. Defaults are picked to be mnemonic (`f` for Finder, etc.)
// and user-overridable via Settings → Keybinds. Persisted under
// "keybind.<action>" in UserDefaults; reads at submenu-construction time.

/// A submenu action that can be triggered by a keyboard shortcut.
enum SubmenuAction: String, CaseIterable, Identifiable {
    case openInFinder    = "openInFinder"
    case openInTerminal  = "openInTerminal"
    case openInVSCode    = "openInVSCode"
    case viewTranscript  = "viewTranscript"
    case copyPID         = "copyPID"
    case terminate       = "terminate"

    var id: String { rawValue }

    /// Human-readable name shown in the Settings table.
    var displayName: String {
        switch self {
        case .openInFinder:   return "Open in Finder"
        case .openInTerminal: return "Open in Terminal"
        case .openInVSCode:   return "Open in VSCode"
        case .viewTranscript: return "View Transcript"
        case .copyPID:        return "Copy PID"
        case .terminate:      return "Terminate"
        }
    }

    /// Default single-character keybind.
    var defaultKey: String {
        switch self {
        case .openInFinder:   return "f"
        case .openInTerminal: return "t"
        case .openInVSCode:   return "c"   // "c" for code; doesn't conflict with copy because copy lives in same submenu
        case .viewTranscript: return "v"
        case .copyPID:        return "p"
        case .terminate:      return "x"   // "x" for kill (avoids accidental ⌘⌫)
        }
    }
}

/// Resolves the active keybind for a submenu action — user override if
/// present, else the bundled default. Empty string disables the binding
/// (user can explicitly clear via Settings).
func keybindFor(_ action: SubmenuAction) -> String {
    if let custom = UserDefaults.standard.string(forKey: "keybind.\(action.rawValue)") {
        return custom
    }
    return action.defaultKey
}

func setKeybind(_ action: SubmenuAction, _ key: String) {
    UserDefaults.standard.set(key, forKey: "keybind.\(action.rawValue)")
    NotificationCenter.default.post(name: .menuBehaviorDidChange, object: nil)
}

func resetKeybind(_ action: SubmenuAction) {
    UserDefaults.standard.removeObject(forKey: "keybind.\(action.rawValue)")
    NotificationCenter.default.post(name: .menuBehaviorDidChange, object: nil)
}

func keybindIsOverridden(_ action: SubmenuAction) -> Bool {
    return UserDefaults.standard.object(forKey: "keybind.\(action.rawValue)") != nil
}

/// Short human-readable elapsed string for a count of seconds. Used by
/// the "last tool ran" hint line: `4s`, `2m`, `28m`, `1h`, etc. Returns
/// "0s" for negative or invalid input.
func formatAgo(seconds n: Int) -> String {
    let s = max(0, n)
    if s < 60     { return "\(s)s" }
    if s < 3600   { return "\(s / 60)m" }
    if s < 86_400 { return "\(s / 3600)h" }
    return "\(s / 86_400)d"
}

// Cached DateFormatters for the user's 24h-vs-12h preference. Previously
// userTimeFormatter() allocated a fresh DateFormatter per call — and was
// being called once per AllSessions row × every dashboard refresh, which
// was milliseconds of avoidable work on the main thread per tick.
//
// We hold four formatters (2 dimensions × 2 values). When the user
// toggles time.use24h, we wipe the cache via .menuBehaviorDidChange.

var _timeFormatterCache: [String: DateFormatter] = [:]
let _timeFormatterQueue = DispatchQueue(label: "claude.tf.cache")

func userTimeFormatter(includesDate: Bool = false) -> DateFormatter {
    let use24h = UserDefaults.standard.bool(forKey: "time.use24h")
    let key = "\(use24h ? "24" : "12")-\(includesDate ? "d" : "t")"
    return _timeFormatterQueue.sync {
        if let cached = _timeFormatterCache[key] { return cached }
        let f = DateFormatter()
        let time = use24h ? "HH:mm" : "h:mm a"
        f.dateFormat = includesDate ? "MMM d, \(time)" : time
        _timeFormatterCache[key] = f
        return f
    }
}

func invalidateTimeFormatterCache() {
    _timeFormatterQueue.sync { _timeFormatterCache.removeAll() }
}

