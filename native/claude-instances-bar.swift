// claude-instances-bar.swift
// Native macOS menu-bar widget for monitoring Claude Code instances.
//
// Compile & run:
//   bash native/build.sh              # build + launch
//   bash native/build.sh --install    # build + register LaunchAgent
//   bash native/build.sh --status     # show running state

import AppKit
import Foundation
import SwiftUI

// ─── Paths ────────────────────────────────────────────────────────────────────

private let home         = FileManager.default.homeDirectoryForCurrentUser.path
private let widgetDir    = home + "/.claude/widgets/claude-instances"
private let scanScript   = widgetDir + "/lib/scan.sh"
private let detailScript = widgetDir + "/lib/detail.sh"
private let renderScript = widgetDir + "/render.sh"
private let dashboardHTML = widgetDir + "/dashboard.html"
private let logDir       = home + "/Library/Logs/ClaudeInstances"
private let debugLog     = logDir + "/bar.log"
private let debugLogPrev = logDir + "/bar.log.1"
private let iconPath     = home + "/.claude/widgets/claude-instances/native/claude-logo.svg"

// ─── Logging ──────────────────────────────────────────────────────────────────
//
// Three levels (info / warn / error), persistent under ~/Library/Logs/ClaudeInstances/,
// size-rotated at 1 MB (one .1 backup retained).
//
// Format: ISO8601 [pid] [LEVEL] message
//
// Use:
//   dlog("scanner finished")     // INFO
//   dwarn("pipe closed early")   // WARN
//   derr("scanner status=\(s)")  // ERROR

private enum LogLevel: String { case info = "INFO", warn = "WARN", error = "ERROR" }

private let logRotateBytes: UInt64 = 1_000_000
private let pidStr = String(ProcessInfo.processInfo.processIdentifier)

private func ensureLogDir() {
    try? FileManager.default.createDirectory(
        atPath: logDir, withIntermediateDirectories: true)
}

private func rotateLogIfNeeded() {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: debugLog),
          let size = attrs[.size] as? UInt64, size > logRotateBytes else { return }
    try? FileManager.default.removeItem(atPath: debugLogPrev)
    try? FileManager.default.moveItem(atPath: debugLog, toPath: debugLogPrev)
}

private func writeLog(_ level: LogLevel, _ msg: String) {
    ensureLogDir()
    rotateLogIfNeeded()
    let ts   = ISO8601DateFormatter().string(from: Date())
    let line = "\(ts) [\(pidStr)] [\(level.rawValue)] \(msg)\n"
    guard let data = line.data(using: .utf8) else { return }
    if let fh = FileHandle(forWritingAtPath: debugLog) {
        fh.seekToEndOfFile(); fh.write(data); fh.closeFile()
    } else {
        try? data.write(to: URL(fileURLWithPath: debugLog))
    }
}

private func dlog (_ msg: String) { writeLog(.info,  msg) }
private func dwarn(_ msg: String) { writeLog(.warn,  msg) }
private func derr (_ msg: String) { writeLog(.error, msg) }

/// Pretty-print an NSError so multi-line dumps fit on one log line.
private func fmtErr(_ error: Error) -> String {
    let ns = error as NSError
    return "\(ns.domain) #\(ns.code): \(ns.localizedDescription)"
}

/// Pretty-print the NSDictionary returned by `NSAppleScript.executeAndReturnError`.
/// Strips noisy keys (NSAppleScriptErrorRange) and surfaces brief message + code + app.
private func fmtASErr(_ info: NSDictionary) -> String {
    let brief = info["NSAppleScriptErrorBriefMessage"] as? String
             ?? info["NSAppleScriptErrorMessage"] as? String
             ?? "unknown error"
    let num   = (info["NSAppleScriptErrorNumber"] as? NSNumber)?.intValue ?? -1
    let app   = info["NSAppleScriptErrorAppName"] as? String ?? "?"
    return "AppleScript[\(app) #\(num)]: \(brief)"
}

// ─── Formatting helpers ──────────────────────────────────────────────────────

private func fmtTokens(_ n: Int) -> String {
    switch n {
    case 1_000_000...: return String(format: "%.1fM", Double(n) / 1_000_000)
    case 1_000...:     return String(format: "%.0fK", Double(n) / 1_000)
    default:           return "\(n)"
    }
}

private func fmtSize(_ kb: Double) -> String {
    return kb > 1024 ? String(format: "%.1fM", kb / 1024) : "\(Int(kb))K"
}

private func relativeTime(_ isoString: String?) -> String {
    guard let s = isoString else { return "?" }
    let fmt = ISO8601DateFormatter()
    fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    var date = fmt.date(from: s)
    if date == nil {
        let fmt2 = ISO8601DateFormatter()
        date = fmt2.date(from: s)
    }
    if date == nil {
        // Try replacing Z with +00:00 for fractional seconds
        let cleaned = s.replacingOccurrences(of: "Z", with: "+00:00")
        date = fmt.date(from: cleaned)
    }
    guard let d = date else { return "?" }
    let secs = Date().timeIntervalSince(d)
    switch secs {
    case ..<60:    return "now"
    case ..<3600:  return "\(Int(secs / 60))m"
    case ..<86400: return "\(Int(secs / 3600))h"
    default:       return "\(Int(secs / 86400))d"
    }
}

private func fmtCost(_ usd: Double) -> String {
    if usd >= 1.0 { return String(format: "$%.2f", usd) }
    if usd >= 0.01 { return String(format: "%.0f¢", usd * 100) }
    if usd > 0 { return String(format: "%.1f¢", usd * 100) }
    return "–"
}

private func shortenPath(_ path: String?, maxLen: Int = 32) -> String {
    guard let p = path, !p.isEmpty else { return "?" }
    if p.count <= maxLen { return p }
    return "…" + p.suffix(maxLen - 1)
}

private func rateLimitCountdown(_ resetsAt: String?) -> String? {
    guard let str = resetsAt, !str.isEmpty else { return nil }
    var resetDate: Date?
    if let epoch = Double(str) {
        resetDate = Date(timeIntervalSince1970: epoch)
    } else {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        resetDate = fmt.date(from: str)
        if resetDate == nil {
            let fmt2 = ISO8601DateFormatter()
            resetDate = fmt2.date(from: str)
        }
    }
    guard let rd = resetDate else { return nil }
    let secs = rd.timeIntervalSinceNow
    guard secs > 0 else { return nil }
    let totalMin = Int(secs) / 60
    let d = totalMin / 1440
    let h = (totalMin % 1440) / 60
    let m = totalMin % 60
    // Use day-precision for week-scale windows so "5d 3h" doesn't show as
    // "123h 0m". Keep minute precision for short windows so the 5h bar
    // still ticks visibly.
    if d > 0 { return "\(d)d \(h)h" }
    if h > 0 { return "\(h)h \(m)m" }
    return "\(m)m"
}

// ─── String helpers ──────────────────────────────────────────────────────────

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
            lastPrompt: mergedPrompt
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

private struct ModelDisplay {
    let badge: String
    let label: String
    let color: NSColor
}

private let defaultModel = ModelDisplay(badge: "·", label: "?", color: .secondaryLabelColor)

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

enum PaletteToken: String, CaseIterable {
    case modelOpus      = "model.opus"       // Opus model badge
    case modelSonnet    = "model.sonnet"     // Sonnet model badge
    case modelHaiku     = "model.haiku"      // Haiku model badge
    case metricCost     = "metric.cost"      // $ cost values
    case metricTokens   = "metric.tokens"    // ↑ token counts
    case metricMemory   = "metric.memory"    // MB memory values
    case accentBranch   = "accent.branch"    // ⎇ branch badge
    case accentSubagent = "accent.subagent"  // ↳N subagent badge
    case stateActive    = "state.active"     // state-detail row (thinking/responding)
    case warnHigh       = "warn.high"        // compaction-imminent, MCP-down, ctx <30
    case warnMid        = "warn.mid"         // modified <20, ctx <60
    case successHigh    = "success.high"     // ctx ≥60%, ↑tokens

    /// Short human-readable name shown in the Settings table.
    var displayName: String {
        switch self {
        case .modelOpus:      return "Opus"
        case .modelSonnet:    return "Sonnet"
        case .modelHaiku:     return "Haiku"
        case .metricCost:     return "Cost"
        case .metricTokens:   return "Tokens"
        case .metricMemory:   return "Memory"
        case .accentBranch:   return "Branch"
        case .accentSubagent: return "Subagent"
        case .stateActive:    return "Active state"
        case .warnHigh:       return "Warning (high)"
        case .warnMid:        return "Warning (mid)"
        case .successHigh:    return "Success"
        }
    }

    /// What this token is used for. One sentence; surfaces in the Settings UI.
    var usage: String {
        switch self {
        case .modelOpus:      return "Opus model badge ◆"
        case .modelSonnet:    return "Sonnet model badge ●"
        case .modelHaiku:     return "Haiku model badge ○"
        case .metricCost:     return "Per-session cost values ($N.NN)"
        case .metricTokens:   return "Output token counts (↑NK)"
        case .metricMemory:   return "Resident memory (NMB)"
        case .accentBranch:   return "Git branch badge (⎇branch)"
        case .accentSubagent: return "Subagent count badge (↳N)"
        case .stateActive:    return "Active-state row (thinking / responding / tool use)"
        case .warnHigh:       return "Critical warnings: compaction imminent, MCP down, modified ≥20"
        case .warnMid:        return "Mid-severity: ctx <60%, modified <20"
        case .successHigh:    return "Healthy state: ctx ≥60%, fast token rate"
        }
    }
}

final class PaletteStore {
    static let shared = PaletteStore()

    static let didChangeNotification = Notification.Name("PaletteStore.didChange")

    /// Baked-in defaults. Survive user reset.
    private let defaults: [PaletteToken: NSColor] = [
        .modelOpus:      .systemOrange,
        .modelSonnet:    .systemBlue,
        .modelHaiku:     NSColor.systemTeal.shadow(withLevel: 0.25)!,
        .metricCost:     NSColor(calibratedRed: 0.95, green: 0.72, blue: 0.30, alpha: 1.0),
        .metricTokens:   NSColor.systemGreen.shadow(withLevel: 0.35)!,
        .metricMemory:   NSColor(calibratedRed: 0.55, green: 0.75, blue: 0.95, alpha: 1.0),
        .accentBranch:   NSColor.systemTeal.shadow(withLevel: 0.25)!,
        .accentSubagent: NSColor(calibratedRed: 0.55, green: 0.82, blue: 0.88, alpha: 1.0),
        .stateActive:    NSColor.systemTeal.shadow(withLevel: 0.25)!,
        .warnHigh:       NSColor(calibratedRed: 0.90, green: 0.42, blue: 0.42, alpha: 1.0),
        .warnMid:        NSColor.systemYellow.shadow(withLevel: 0.30)!,
        .successHigh:    NSColor.systemGreen.shadow(withLevel: 0.35)!,
    ]

    private let prefix = "palette."

    /// Returns the user-set override if present, else the baked-in default.
    func color(for token: PaletteToken) -> NSColor {
        if let hex = UserDefaults.standard.string(forKey: prefix + token.rawValue),
           let c = NSColor.fromHex(hex) {
            return c
        }
        return defaults[token] ?? .labelColor
    }

    /// Returns the hex string ("#RRGGBB") of the current value (user or default).
    func hex(for token: PaletteToken) -> String {
        return color(for: token).hexString
    }

    /// True if the user has overridden this token.
    func isOverridden(_ token: PaletteToken) -> Bool {
        return UserDefaults.standard.string(forKey: prefix + token.rawValue) != nil
    }

    func set(_ token: PaletteToken, hex: String) {
        UserDefaults.standard.set(hex, forKey: prefix + token.rawValue)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    func reset(_ token: PaletteToken) {
        UserDefaults.standard.removeObject(forKey: prefix + token.rawValue)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    func resetAll() {
        for t in PaletteToken.allCases {
            UserDefaults.standard.removeObject(forKey: prefix + t.rawValue)
        }
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    /// Default value (without user override) — used by the Settings UI to
    /// label the "reset" button's destination.
    func defaultColor(for token: PaletteToken) -> NSColor {
        return defaults[token] ?? .labelColor
    }
}

// MARK: NSColor ↔ hex
extension NSColor {
    /// "#RRGGBB" (drops alpha — palette colors are opaque).
    var hexString: String {
        let c = self.usingColorSpace(.sRGB) ?? self
        let r = Int(round(c.redComponent   * 255))
        let g = Int(round(c.greenComponent * 255))
        let b = Int(round(c.blueComponent  * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    /// Parses "#RRGGBB" or "RRGGBB". Returns nil for invalid input.
    static func fromHex(_ s: String) -> NSColor? {
        var hex = s.trimmingCharacters(in: .whitespaces)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let val = UInt32(hex, radix: 16) else { return nil }
        let r = CGFloat((val >> 16) & 0xFF) / 255.0
        let g = CGFloat((val >>  8) & 0xFF) / 255.0
        let b = CGFloat( val        & 0xFF) / 255.0
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1.0)
    }
}

// ─── Per-color accessor constants (read from PaletteStore at call time) ──────
//
// Computed vars so each access reads the current PaletteStore value. User
// changes via the Settings tab propagate to the next render with zero plumbing.

private var menuGreen:     NSColor { PaletteStore.shared.color(for: .successHigh)    }
private var menuYellow:    NSColor { PaletteStore.shared.color(for: .warnMid)        }
private var menuCyan:      NSColor { PaletteStore.shared.color(for: .accentSubagent) } // legacy alias
private var menuTeal:      NSColor { PaletteStore.shared.color(for: .accentBranch)   }
private var menuRed:       NSColor { PaletteStore.shared.color(for: .warnHigh)       }
private var costColor:     NSColor { PaletteStore.shared.color(for: .metricCost)     }
private var tokensColor:   NSColor { PaletteStore.shared.color(for: .metricTokens)   }
private var memColor:      NSColor { PaletteStore.shared.color(for: .metricMemory)   }
private var subagentColor: NSColor { PaletteStore.shared.color(for: .accentSubagent) }
private var coralAccent:   NSColor { .systemGray }   // structural, not in palette

private func modelDisplay(_ name: String?) -> ModelDisplay {
    // Resolve model color from PaletteStore at call time so user changes via
    // Settings propagate without needing to rebuild modelConfig.
    guard let n = name else { return defaultModel }
    switch n {
    case "opus":   return ModelDisplay(badge: "◆", label: "Opus",
                                       color: PaletteStore.shared.color(for: .modelOpus))
    case "sonnet": return ModelDisplay(badge: "●", label: "Sonnet",
                                       color: PaletteStore.shared.color(for: .modelSonnet))
    case "haiku":  return ModelDisplay(badge: "○", label: "Haiku",
                                       color: PaletteStore.shared.color(for: .modelHaiku))
    default:       return defaultModel
    }
}

// ─── Ghostty AppleScript bridge ──────────────────────────────────────────────

private func focusGhosttyTab(forCwd cwd: String) {
    // Extract the last path component for matching (more reliable)
    let dirName = (cwd as NSString).lastPathComponent
    let script = """
    tell application "Ghostty"
        activate
        try
            set allTerminals to every terminal whose working directory contains "\(dirName)"
            if (count of allTerminals) > 0 then
                focus item 1 of allTerminals
            end if
        end try
    end tell
    """
    let appleScript = NSAppleScript(source: script)
    var error: NSDictionary?
    appleScript?.executeAndReturnError(&error)
    if let error = error {
        derr("focus failed: \(fmtASErr(error))")
        // Fallback: just activate Ghostty
        let fallback = NSAppleScript(source: "tell application \"Ghostty\" to activate")
        fallback?.executeAndReturnError(nil)
    }
}

private func activateGhostty() {
    let script = NSAppleScript(source: "tell application \"Ghostty\" to activate")
    script?.executeAndReturnError(nil)
}

/// Launch `claude --resume <sessionId>` in a new Ghostty tab
private func resumeSession(sessionId: String, cwd: String? = nil) {
    let dir = cwd ?? home
    let esc_dir = dir.replacingOccurrences(of: "\"", with: "\\\"")
    let esc_sid = sessionId.replacingOccurrences(of: "\"", with: "\\\"")
    let script = """
    tell application "Ghostty"
        activate
        tell application "System Events"
            keystroke "t" using command down
            delay 0.3
            keystroke "cd \\"\(esc_dir)\\" && claude --resume \\"\(esc_sid)\\""
            key code 36
        end tell
    end tell
    """
    let appleScript = NSAppleScript(source: script)
    var error: NSDictionary?
    appleScript?.executeAndReturnError(&error)
    if let error = error {
        derr("resume failed: \(fmtASErr(error))")
    }
}

/// Open a file in the default viewer (Finder/Chrome)
private func openFile(_ path: String) {
    NSWorkspace.shared.open(URL(fileURLWithPath: path))
}

// ─── All-Sessions Scanner ────────────────────────────────────────────────────
// Deep scan for ALL session JSONL files — used by the "All Sessions" dashboard tab.
// Not called on the periodic timer; only invoked on-demand.

struct FullSession {
    let sessionId: String
    let project: String
    let projectDirName: String   // raw dir name for path resolution
    let model: String
    let turns: Int
    let sizeKb: Double
    let modified: Date
    let tokensIn: Int
    let tokensOut: Int
    let jsonlPath: String        // full path for transcript/log viewing
}

private func scanAllSessions() -> [FullSession] {
    let projectsDir = home + "/.claude/projects"
    let fm = FileManager.default
    guard fm.fileExists(atPath: projectsDir) else { return [] }

    var results: [FullSession] = []
    guard let enumerator = fm.enumerator(atPath: projectsDir) else { return [] }

    while let relative = enumerator.nextObject() as? String {
        guard relative.hasSuffix(".jsonl"),
              !relative.hasPrefix("."),
              !(relative as NSString).lastPathComponent.hasPrefix(".")
        else { continue }

        let fullPath = projectsDir + "/" + relative
        guard let attrs = try? fm.attributesOfItem(atPath: fullPath),
              let modDate = attrs[.modificationDate] as? Date,
              let fileSize = attrs[.size] as? UInt64
        else { continue }

        let sessionId = ((relative as NSString).lastPathComponent as NSString).deletingPathExtension
        let parentDir = ((relative as NSString).deletingLastPathComponent as NSString).lastPathComponent

        // Derive project display name
        var projectDisplay = parentDir.replacingOccurrences(of: "-", with: "/")
        if projectDisplay.hasPrefix("/") { projectDisplay = String(projectDisplay.dropFirst()) }
        let segs = projectDisplay.split(separator: "/").filter { !$0.isEmpty }
        if segs.count > 2 {
            projectDisplay = segs.suffix(2).joined(separator: "/")
        }

        // Quick model detection: read first 4KB
        var model = "unknown"
        var turns = 0
        if let fh = FileHandle(forReadingAtPath: fullPath) {
            defer { fh.closeFile() }
            let head = fh.readData(ofLength: 4096)
            if let headStr = String(data: head, encoding: .utf8) {
                for line in headStr.split(separator: "\n") {
                    if line.contains("\"type\":\"assistant\"") || line.contains("\"type\": \"assistant\"") {
                        if let modelMatch = line.range(of: "\"model\":\"", options: .literal) ??
                                            line.range(of: "\"model\": \"", options: .literal) {
                            let afterModel = line[modelMatch.upperBound...]
                            if let endQuote = afterModel.firstIndex(of: "\"") {
                                let m = String(afterModel[..<endQuote])
                                if m.contains("opus") { model = "opus" }
                                else if m.contains("sonnet") { model = "sonnet" }
                                else if m.contains("haiku") { model = "haiku" }
                                else { model = m }
                            }
                            break
                        }
                    }
                }
            }
            // Estimate turns from file size (rough: ~2KB per turn average)
            turns = max(1, Int(fileSize / 2048))
        }

        results.append(FullSession(
            sessionId: sessionId,
            project: projectDisplay,
            projectDirName: parentDir,
            model: model,
            turns: turns,
            sizeKb: Double(fileSize) / 1024.0,
            modified: modDate,
            tokensIn: 0,
            tokensOut: 0,
            jsonlPath: fullPath
        ))
    }

    results.sort { $0.modified > $1.modified }
    return results
}

// ─── Scanner ─────────────────────────────────────────────────────────────────

private func runScanner(quick: Bool = false) -> ScanResult? {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/bash")
    task.arguments = quick ? [scanScript, "--quick"] : [scanScript]
    task.environment = ProcessInfo.processInfo.environment

    let outPipe = Pipe()
    let errPipe = Pipe()
    task.standardOutput = outPipe
    task.standardError  = errPipe

    do {
        try task.run()
        task.waitUntilExit()

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let stderr  = String(data: errData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if task.terminationStatus != 0 {
            let mode = quick ? "--quick" : "full"
            derr("scanner \(mode) exit=\(task.terminationStatus)" +
                 (stderr.isEmpty ? "" : " stderr=\(stderr.prefix(400))"))
            return nil
        }
        if !stderr.isEmpty {
            // Scanner succeeded but emitted warnings — surface them at WARN level.
            dwarn("scanner stderr: \(stderr.prefix(400))")
        }
        do {
            return try JSONDecoder().decode(ScanResult.self, from: outData)
        } catch {
            let preview = String(data: outData.prefix(200), encoding: .utf8) ?? "<non-utf8>"
            derr("scanner JSON decode failed: \(fmtErr(error)) — first 200B: \(preview)")
            return nil
        }
    } catch {
        derr("scanner launch failed: \(fmtErr(error))")
        return nil
    }
}

// ─── LiveRowView: per-instance live-updating menu content ───────────────────
//
// Replaces the previous chain of per-instance attributedTitle NSMenuItems
// (row1 + row1.25 + row1.5 + state-detail + last-prompt + metrics +
// compaction-warn + focus-file + mcp-down) with a single view-based menu
// item. Because the view renders itself, we can mutate its labels in place
// while the menu is open — AppKit does not redraw attributedTitle of an
// open standard menu item.
//
// Each instance becomes ONE NSMenuItem.view; the per-instance submenu is
// still attached to that one item. Hover reveals the submenu indicator and
// click opens it, same as before — view-based items don't lose those
// interactions.

final class LiveRowView: NSView {
    private let stack = NSStackView()

    /// Maps each label to the palette token it draws its primary color from.
    /// Populated as labels are added via addLine(_:token:). Used by:
    ///   - hover detection: mouseEntered → look up token → fire onHoverToken
    ///   - reverse highlight: when `highlightedToken` is set, the matching
    ///     label gets a translucent accent-tinted background.
    private var tokenForLabel: [NSTextField: PaletteToken] = [:]

    /// Fired when the mouse enters/exits a token-tagged label. Receives the
    /// token under the cursor, or nil when the cursor leaves all tagged
    /// regions. Set externally (e.g. by the Settings preview).
    var onHoverToken: ((PaletteToken?) -> Void)?

    /// When set, the label corresponding to this token paints a translucent
    /// accent background — used by the Settings UI to telegraph "this row
    /// → this part of the row". Set via setHighlightedToken below.
    private var highlightedToken: PaletteToken?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    private func setupUI() {
        stack.orientation = .vertical
        stack.spacing = 2
        stack.alignment = .leading
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            // 20pt leading: matches the leading inset AppKit uses for
            // standard NSMenuItems (which start their title ~20pt in from
            // the cell edge, after the icon/checkmark column). Pre-pad
            // here so per-label whitespace prefixes aren't needed.
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -22),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 340),
        ])
    }

    /// Critical for view-based menu items: AppKit asks the view for its
    /// preferred size to lay out the NSMenuItem. Without this override
    /// the menu uses our init frame (360×80) and clips rows that would
    /// have rendered below 80px — which is most of them.
    override var intrinsicContentSize: NSSize {
        let s = stack.fittingSize
        return NSSize(width: max(s.width + 42, 340),
                      height: s.height + 8)
    }

    /// Replace rendered content with attributed strings derived from the
    /// current `LiveInstance`. Called both at first render (in menuNeedsUpdate)
    /// and on every scan tick while the menu is held open.
    func update(with inst: LiveInstance,
                leaf: String,
                fullPath: String?,
                stateIcon: String,
                stateStr: String,
                stateDetail: String,
                home: String) {
        // Tear down old labels.
        for v in stack.arrangedSubviews {
            stack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }

        // Indent is now controlled entirely by the stack's leading-edge
        // constraint (configured once in setupUI). Per-label whitespace
        // prefixes have been removed — they caused the "different left
        // padding on each line" inconsistency you saw.
        //
        // Font size scheme (3 sizes, was 4):
        //   13pt — header (model + leaf + elapsed)
        //   12pt — metrics row (data values)
        //   11pt — everything else (path, prompt, warnings)
        // Bold only on the model badge. All other rows use regular weight.
        //
        // Color scheme:
        //   badge color : per-model (orange/blue/teal)
        //   leaf        : labelColor (white in dark mode)
        //   elapsed     : tertiaryLabelColor (dim, was loud coral)
        //   ↳ subagent  : subagentColor (mint-cyan — replaces garish purple)
        //   ⎇ branch    : menuTeal (subtle, distinguishes from subagent)
        //   * modified  : menuRed if ≥20 else menuYellow (was pure red)
        //   ctx %       : menuRed <30 / yellow <60 / green ≥60
        //   turns       : tertiaryLabel (ambient count, gray)
        //   🔧 tools    : tertiaryLabel (was orange — too loud)
        //   ↑ tokens    : tokensColor (green, always)
        //   $ cost      : costColor (amber, always — was value-stepped)
        //   MB memory   : memColor (sky blue, always — was value-stepped)
        //   t/s speed   : tertiaryLabel
        //   warnings    : menuRed (softer than systemRed)
        //   state       : menuTeal

        // Reset token mapping at the start of each update — labels are
        // re-created from scratch below.
        tokenForLabel.removeAll()

        // Header line: badge + (state icon) + leaf + elapsed + ↳ + ⎇ + *N
        let m = modelDisplay(inst.model)
        let elapsed = inst.elapsed?.trimmingCharacters(in: .whitespaces) ?? "?"
        let modelToken: PaletteToken? = {
            switch inst.model {
            case "opus":   return .modelOpus
            case "sonnet": return .modelSonnet
            case "haiku":  return .modelHaiku
            default:       return nil
            }
        }()
        let header = NSMutableAttributedString()
        header.append(NSAttributedString(string: "\(m.badge) ", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .bold),
            .foregroundColor: m.color,
        ]))
        if !stateIcon.isEmpty {
            let blink = (Int(Date().timeIntervalSince1970) % 2 == 0) ? "\(stateIcon) " : "  "
            header.append(NSAttributedString(string: blink, attributes: [.font: NSFont.systemFont(ofSize: 13)]))
        }
        header.append(NSAttributedString(string: leaf, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.labelColor,
        ]))
        header.append(NSAttributedString(string: "  \(elapsed)", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]))
        if let subs = inst.subagentCount, subs > 0 {
            header.append(NSAttributedString(string: "  ↳\(subs)", attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
                .foregroundColor: subagentColor,
            ]))
        }
        if let br = inst.gitBranch, !br.isEmpty {
            header.append(NSAttributedString(string: "  ⎇\(br)", attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
                .foregroundColor: menuTeal,
            ]))
            if let mod = inst.gitModified, mod > 0 {
                let mc: NSColor = mod >= 20 ? menuRed : menuYellow
                header.append(NSAttributedString(string: " *\(mod)", attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
                    .foregroundColor: mc,
                ]))
            }
        }
        addLine(header, token: modelToken)

        // Tab title (when distinct from leaf)
        if let tab = inst.tabTitle, !tab.isEmpty, tab != leaf {
            addLine(NSAttributedString(string: "⌥ \(tab)", attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]))
        }

        // Full cwd path (wraps; truncation forbidden by spec). Char-wrap
        // since paths have no spaces — word-wrap lets them overflow.
        if let path = fullPath, path != leaf {
            addLine(NSAttributedString(string: path, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: NSColor.tertiaryLabelColor,
            ]), wrapMode: .byCharWrapping)
        }

        // State detail (only when not idle)
        if stateStr != "idle" && !stateDetail.isEmpty {
            addLine(NSAttributedString(string: "\(stateIcon) \(stateStr): \(stateDetail)", attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: menuTeal,
            ]), token: .stateActive)
        }

        // Last user prompt
        if let lp = inst.lastPrompt, !lp.isEmpty {
            addLine(NSAttributedString(string: "❯ \(lp)", attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]))
        }

        // Metrics row — per-field colors (not value-stepped, except ctx %).
        let metrics = NSMutableAttributedString()
        if let ctx = inst.statusline?.ctxRemaining, !ctx.isEmpty, ctx != "0" {
            let n = Int(ctx) ?? 0
            let c: NSColor = n < 30 ? menuRed : (n < 60 ? menuYellow : menuGreen)
            metrics.append(NSAttributedString(string: "ctx \(ctx)%  ", attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium),
                .foregroundColor: c,
            ]))
        }
        var parts: [(String, NSColor)] = []
        if let t = inst.turns, t > 0 { parts.append(("\(t)t", .tertiaryLabelColor)) }
        if let tc = inst.toolCalls, tc > 0 { parts.append(("🔧\(tc)", .tertiaryLabelColor)) }
        if let o = inst.outputTokens, o > 0 { parts.append(("↑\(fmtTokens(o))", tokensColor)) }
        if let c = inst.costUsd, c > 0 { parts.append((fmtCost(c), costColor)) }
        if let rss = inst.statusline?.rssMb, rss != "0", !rss.isEmpty {
            parts.append(("\(rss)MB", memColor))
        }
        if let ts = inst.statusline?.tokSpeed, !ts.isEmpty, ts != "0" {
            parts.append(("\(ts)t/s", .tertiaryLabelColor))
        }
        let metFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        for (i, p) in parts.enumerated() {
            if i > 0 {
                metrics.append(NSAttributedString(string: " · ", attributes: [
                    .font: metFont, .foregroundColor: NSColor.quaternaryLabelColor,
                ]))
            }
            metrics.append(NSAttributedString(string: p.0, attributes: [.font: metFont, .foregroundColor: p.1]))
        }
        addLine(metrics)

        // Compaction-soon warning (soft red)
        if let ctxStr = inst.statusline?.ctxRemaining,
           let n = Int(ctxStr), n > 0 && n < 15 {
            addLine(NSAttributedString(string: "⚠ Context low (\(n)%) — compaction imminent", attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: menuRed,
            ]), token: .warnHigh)
        }

        // Focus file (wraps, no truncation; char-wrap for long paths)
        if let focus = inst.statusline?.focusFile, !focus.isEmpty {
            var disp = focus
            if let cwd = inst.cwd, !cwd.isEmpty { disp = disp.replacingOccurrences(of: cwd, with: ".") }
            disp = disp.replacingOccurrences(of: home, with: "~")
            addLine(NSAttributedString(string: "📄 \(disp)", attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: NSColor.tertiaryLabelColor,
            ]), wrapMode: .byCharWrapping)
        }

        // MCP-down warning (soft red)
        if let mcp = inst.statusline?.mcpDown, !mcp.isEmpty {
            addLine(NSAttributedString(string: "⚠ MCP down: \(mcp)", attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: menuRed,
            ]), token: .warnHigh)
        }

        // CRITICAL: NSMenuItem.view uses self.frame.size to lay out the
        // menu row. It IGNORES intrinsicContentSize. So we must explicitly
        // resize self after the labels are laid out — otherwise the init
        // frame (360×80) wins, Auto Layout squeezes the inner stack to fit
        // 80px, and the bottom labels get clipped. With many rows that
        // looks like "header is missing" because the header is at the top
        // of the squeezed-into-80px stack, but rendered ABOVE the visible
        // 80px bound (negative y inside the menu cell).
        stack.layoutSubtreeIfNeeded()
        let needed = stack.fittingSize
        // Padding totals = 20 leading + 22 trailing + 4 top + 4 bottom.
        let h = max(needed.height + 8,  22)
        let w = max(needed.width + 42, 340)
        if frame.size.width != w || frame.size.height != h {
            setFrameSize(NSSize(width: w, height: h))
            invalidateIntrinsicContentSize()
        }

        // Re-apply the reverse-highlight (in case update() rebuilt labels
        // while a row was hovered in the Settings palette table).
        applyHighlightedToken()
    }

    /// Called by the Settings UI to highlight the label whose token matches.
    /// Sets a translucent accent background on the matching label(s). Nil to
    /// clear. Used to telegraph "this palette row → this part of the row."
    func setHighlightedToken(_ token: PaletteToken?) {
        guard highlightedToken != token else { return }
        highlightedToken = token
        applyHighlightedToken()
    }

    private func applyHighlightedToken() {
        let highlight = highlightedToken
        for (label, tok) in tokenForLabel {
            let isHit = (tok == highlight)
            label.drawsBackground = isHit
            if isHit {
                // Subtle accent-tinted bg. NSColor.controlAccentColor adapts
                // to user accent + dark/light mode automatically.
                label.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.20)
                // Slight padding effect via the cell's bezel? NSTextField
                // doesn't expose internal padding cleanly; the bg fill
                // alone is enough signal.
            } else {
                label.backgroundColor = .clear
            }
            label.needsDisplay = true
        }
    }

    // ── Hover tracking ───────────────────────────────────────────────────
    //
    // One tracking area covering the whole view; on mouseMoved, hit-test
    // against each tagged label's frame (in our coordinate space) and fire
    // onHoverToken when the token under the cursor changes. Avoids the
    // overhead of N tracking areas (one per label) — single area, fast
    // lookup, debounced by tracking the last reported token.

    private var lastHoverToken: PaletteToken?
    private var rootTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let prev = rootTrackingArea { removeTrackingArea(prev) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect],
            owner: self, userInfo: nil
        )
        addTrackingArea(area)
        rootTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { handleHover(event) }
    override func mouseMoved(with event: NSEvent)   { handleHover(event) }
    override func mouseExited(with event: NSEvent) {
        if lastHoverToken != nil {
            lastHoverToken = nil
            onHoverToken?(nil)
        }
    }

    private func handleHover(_ event: NSEvent) {
        guard onHoverToken != nil else { return }
        let pt = convert(event.locationInWindow, from: nil)
        var hit: PaletteToken?
        for (label, tok) in tokenForLabel {
            // Convert label's frame (in stack's coords) to ours.
            let f = label.convert(label.bounds, to: self)
            if f.contains(pt) { hit = tok; break }
        }
        if hit != lastHoverToken {
            lastHoverToken = hit
            onHoverToken?(hit)
        }
    }

    private func addLine(_ attr: NSAttributedString,
                         wrapMode: NSLineBreakMode = .byWordWrapping,
                         token: PaletteToken? = nil) {
        let label = NSTextField(labelWithAttributedString: attr)
        if let t = token { tokenForLabel[label] = t }
        label.usesSingleLineMode = false
        label.maximumNumberOfLines = 0
        label.lineBreakMode = wrapMode
        label.preferredMaxLayoutWidth = 320
        label.isBezeled = false
        label.isEditable = false
        label.drawsBackground = false
        label.translatesAutoresizingMaskIntoConstraints = false
        // Set vertical content hugging high so empty/short labels don't
        // expand to swallow vertical space the stack reserves for siblings.
        label.setContentHuggingPriority(.required, for: .vertical)
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        stack.addArrangedSubview(label)
    }
}

// ─── SwiftUI bridge for LiveRowView ──────────────────────────────────────────
//
// Wraps the existing `LiveRowView` NSView so SwiftUI views (e.g. the
// Settings tab's palette-preview pane) can render exactly the same DOM as
// the live menu. Single renderer, zero drift — the preview IS what the
// menu shows.
//
// Re-renders whenever `inst` or `paletteVersion` changes (the latter lets
// the parent force a re-paint when palette tokens change via UserDefaults).

struct LiveRowViewRepresentable: NSViewRepresentable {
    let inst: LiveInstance
    let home: String
    var paletteVersion: Int = 0  // bumped to force updateNSView
    var highlightedToken: PaletteToken? = nil  // reverse: row hover → preview highlight
    var onHoverToken: ((PaletteToken?) -> Void)? = nil  // forward: preview hover → row highlight

    func makeNSView(context: Context) -> LiveRowView {
        let v = LiveRowView(frame: NSRect(x: 0, y: 0, width: 360, height: 200))
        v.onHoverToken = onHoverToken
        applyUpdate(to: v)
        return v
    }

    func updateNSView(_ v: LiveRowView, context: Context) {
        v.onHoverToken = onHoverToken
        applyUpdate(to: v)
        v.setHighlightedToken(highlightedToken)
    }

    private func applyUpdate(to v: LiveRowView) {
        let leaf: String = {
            if let tt = inst.tabTitle, !tt.isEmpty { return tt }
            if let cwd = inst.cwd, !cwd.isEmpty { return (cwd as NSString).lastPathComponent }
            return inst.cwdShort ?? "(unknown)"
        }()
        let fullPath: String? = {
            guard let cwd = inst.cwd, !cwd.isEmpty else { return nil }
            return cwd.replacingOccurrences(of: home, with: "~")
        }()
        let stateStr = inst.sessionState?.state ?? "idle"
        let stateDetail = inst.sessionState?.detail ?? ""
        let stateIcons: [String: String] = [
            "thinking": "💭", "responding": "✍️", "tool_use": "🔧",
            "tool_result": "⚙️", "idle": "",
        ]
        v.update(with: inst,
                 leaf: leaf,
                 fullPath: fullPath,
                 stateIcon: stateIcons[stateStr] ?? "",
                 stateStr: stateStr,
                 stateDetail: stateDetail,
                 home: home)
    }
}

// ─── Bar Delegate ────────────────────────────────────────────────────────────

final class BarDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var scanTimer: Timer?

    // Public so DashboardController can read cached data
    private(set) var cachedData: ScanResult?
    private var lastScanError = false
    private var theMenu: NSMenu!
    private var dashboardController: DashboardController?

    /// Tick counter for quick/full scan alternation.
    /// Quick scan (~90ms) runs every 5s. Full scan (~185ms) runs every 6th tick (30s).
    private var scanTick: Int = 0
    private let fullScanInterval: Int = 6

    /// Warning threshold for rate limit indicators (persisted via UserDefaults).
    private let thresholdKey = "rateLimitWarningThreshold"
    private var warningThreshold: Int {
        get { UserDefaults.standard.integer(forKey: thresholdKey) }
        set { UserDefaults.standard.set(newValue, forKey: thresholdKey) }
    }

    /// Refresh cadence — interval (seconds) at which the scan timer fires.
    /// 0 means "paused"; UI exposes presets via the Refresh submenu.
    /// Persisted via UserDefaults so it survives restarts.
    private let refreshIntervalKey = "scanRefreshInterval"
    private static let refreshPresets: [Double] = [1, 2, 5, 10, 30, 60]
    private var refreshInterval: Double {
        get {
            let v = UserDefaults.standard.double(forKey: refreshIntervalKey)
            return v > 0 ? v : 5.0
        }
        set { UserDefaults.standard.set(newValue, forKey: refreshIntervalKey) }
    }
    private var refreshPaused: Bool {
        get { UserDefaults.standard.bool(forKey: refreshIntervalKey + ".paused") }
        set { UserDefaults.standard.set(newValue, forKey: refreshIntervalKey + ".paused") }
    }
    private var lastScanAt: Date?

    // Live-updating menu rows. Keyed by pid so refreshData() can find them
    // and call update() when the menu is open. Cleared on menuDidClose
    // because the menu rebuilds from scratch on next open.
    private var runningRows: [Int: (NSMenuItem, LiveRowView)] = [:]
    private var menuIsOpen = false

    // ── App lifecycle ────────────────────────────────────────────────────────

    func applicationDidFinishLaunching(_ note: Notification) {
        let myPID = ProcessInfo.processInfo.processIdentifier
        let osVer = ProcessInfo.processInfo.operatingSystemVersionString
        dlog("─── claude-instances-bar starting ───")
        dlog("pid=\(myPID) macOS=\(osVer) log=\(debugLog)")

        // Register UserDefaults defaults (doesn't write — just provides fallbacks)
        UserDefaults.standard.register(defaults: [thresholdKey: 80])

        // Apply persisted appearance preference (System / Light / Dark).
        // Affects the dashboard window's chrome. Menu material adapts via OS.
        applyAppearancePref(loadAppearancePref())

        // Kill any other instances of ourselves (dedupe on launch)
        killOtherInstances(myPID: myPID)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        theMenu                  = NSMenu()
        theMenu.autoenablesItems = false
        theMenu.delegate         = self
        statusItem.menu          = theMenu

        // Initial scan
        refreshData()

        // Background timer — scan at user-selected cadence (or paused)
        restartScanTimer()

        // When the Settings tab mutates a palette token, immediately refresh
        // open menu rows + the bar button (in case it cared about a color).
        NotificationCenter.default.addObserver(
            forName: PaletteStore.didChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.refreshLiveRows()
            self?.updateButton()
        }
    }

    /// (Re)start the periodic scan timer using the current `refreshInterval`.
    /// Call after the user changes cadence via the Refresh submenu.
    private func restartScanTimer() {
        scanTimer?.invalidate()
        scanTimer = nil

        if refreshPaused {
            dlog("scan timer paused (no auto-refresh)")
            return
        }

        let interval = refreshInterval
        let t = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.refreshData()
        }
        RunLoop.current.add(t, forMode: .common)
        scanTimer = t
        dlog("scan timer started — interval=\(interval)s (full every \(fullScanInterval) ticks)")
    }

    func applicationWillTerminate(_ note: Notification) {
        scanTimer?.invalidate()
        dlog("terminating")
    }

    // ── Dedupe: kill older instances ─────────────────────────────────────────

    private func killOtherInstances(myPID: Int32) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        proc.arguments = ["-x", "claude-instances-bar"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
        proc.waitUntilExit()

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let pids = output.split(separator: "\n").compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }

        var killed = 0
        for pid in pids where pid != myPID {
            kill(pid, SIGTERM)
            killed += 1
        }
        if killed > 0 {
            dlog("dedupe: killed \(killed) stale instance(s)")
            // Brief pause to let stale NSStatusItems clean up
            Thread.sleep(forTimeInterval: 0.3)
        }
    }

    // ── Data refresh ─────────────────────────────────────────────────────────

    private func refreshData() {
        scanTick += 1
        let isFullScan = (scanTick % fullScanInterval == 0) || cachedData == nil
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = runScanner(quick: !isFullScan)
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let r = result {
                    if isFullScan {
                        // Full scan — replace everything
                        self.cachedData = r
                    } else if let existing = self.cachedData {
                        // Quick scan — merge live data + fresh limits into existing cached result.
                        // CRITICAL: also merge per-instance enrichment fields
                        // (git_branch / git_modified / last_prompt) from the
                        // previous full scan, since --quick mode emits empty
                        // values for those. Without this merge, every quick
                        // tick wipes branch/modified/prompt off the screen.
                        let prevByPid = Dictionary(uniqueKeysWithValues:
                            existing.live.map { ($0.pid, $0) })
                        let mergedLive = r.live.map { (newInst: LiveInstance) -> LiveInstance in
                            guard let prev = prevByPid[newInst.pid] else { return newInst }
                            return newInst.preservingEnrichment(from: prev)
                        }
                        self.cachedData = ScanResult(
                            live: mergedLive,
                            history: existing.history,
                            recentEvents: existing.recentEvents,
                            deepEvents: existing.deepEvents,
                            limits: r.limits ?? existing.limits,
                            aggregates: existing.aggregates,
                            liveCount: r.liveCount
                        )
                    } else {
                        self.cachedData = r
                    }
                    self.lastScanError = false
                    self.lastScanAt    = Date()
                } else {
                    self.lastScanError = true
                }
                self.updateButton()
                // Push fresh data to dashboard if open
                self.dashboardController?.updateData(self.cachedData)
                // Live-update the open menu's per-instance rows. Only does
                // work when menuIsOpen=true; cheap no-op otherwise.
                self.refreshLiveRows()
            }
        }
    }

    // ── Menu bar button ──────────────────────────────────────────────────────

    private func updateButton() {
        guard let btn = statusItem.button else { return }

        let liveCount = cachedData?.liveCount ?? 0

        // Static Claude logo from PNG
        if btn.image == nil || btn.image?.name() != "claude-bar-icon" {
            if let img = NSImage(contentsOfFile: iconPath) {
                img.size = NSSize(width: 18, height: 18)
                img.isTemplate = false
                img.setName("claude-bar-icon")
                btn.image = img
                btn.imagePosition = .imageLeft
            }
        }

        // Dim when idle, full opacity when active
        btn.image?.isTemplate = false
        btn.alphaValue = liveCount == 0 ? 0.5 : 1.0

        // Count label
        let hasPerm = cachedData?.recentEvents?.suffix(3).contains { $0.event == "PermissionRequest" } ?? false
        let countText = hasPerm ? "⚠ \(liveCount)" : (liveCount > 0 ? "\(liveCount)" : "–")

        // Text color: standard label (white on dark bar, black on light bar)
        var textColor: NSColor = .labelColor
        if liveCount == 0 { textColor = .tertiaryLabelColor }

        // Build attributed string with count + optional rate limit warnings
        let title = NSMutableAttributedString()
        title.append(NSAttributedString(string: " \(countText)", attributes: [
            .foregroundColor: textColor,
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
        ]))

        // Rate limit warnings: yellow ⚠ for hourly, red ⚠ for weekly (threshold configurable via slider)
        let threshold = warningThreshold
        if let limits = cachedData?.limits {
            let r5 = Int(limits.fiveH?.pct ?? 0)
            let r7 = Int(limits.week?.pct ?? 0)
            if r5 > threshold {
                title.append(NSAttributedString(string: " ⚠\(r5)%", attributes: [
                    .foregroundColor: NSColor.systemYellow,
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .bold),
                ]))
            }
            if r7 > threshold {
                title.append(NSAttributedString(string: " ⚠\(r7)%", attributes: [
                    .foregroundColor: NSColor.systemRed,
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .bold),
                ]))
            }
        }

        btn.attributedTitle = title
    }

    // ── NSMenuDelegate ───────────────────────────────────────────────────────

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        runningRows.removeAll()  // start fresh; populateMenuItems re-stores
        populateMenuItems(menu)
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
        // First scan tick after open is the next scheduled fire — kick one
        // off immediately so the user sees freshest possible data without
        // waiting up to `refreshInterval` seconds.
        if !refreshPaused { refreshData() }
    }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
        // The view-based items hold strong refs we can release; the menu is
        // about to be torn down anyway, but eager cleanup keeps things tidy.
        runningRows.removeAll()
    }

    /// Iterate the live-row views and re-render each from current cachedData.
    /// Called by refreshData() when `menuIsOpen` is true so users see metrics
    /// tick (elapsed, ctx %, tokens, cost, mem) without closing the menu.
    private func refreshLiveRows() {
        guard menuIsOpen, let live = cachedData?.live else { return }
        // Build a quick lookup so we don't re-iterate per row.
        let byPid = Dictionary(uniqueKeysWithValues: live.map { ($0.pid, $0) })
        for (pid, pair) in runningRows {
            guard let inst = byPid[pid] else { continue }
            let leaf = liveRowLeaf(inst)
            let fullPath = liveRowFullPath(inst)
            let stateStr = inst.sessionState?.state ?? "idle"
            let stateDetail = inst.sessionState?.detail ?? ""
            let stateIcon = liveRowStateIcons[stateStr] ?? ""
            pair.1.update(with: inst,
                          leaf: leaf,
                          fullPath: fullPath,
                          stateIcon: stateIcon,
                          stateStr: stateStr,
                          stateDetail: stateDetail,
                          home: home)
        }
    }

    // Helpers shared by the live-section builder and refreshLiveRows.
    private let liveRowStateIcons: [String: String] = [
        "thinking": "💭", "responding": "✍️", "tool_use": "🔧",
        "tool_result": "⚙️", "idle": "",
    ]
    private func liveRowLeaf(_ inst: LiveInstance) -> String {
        if let tt = inst.tabTitle, !tt.isEmpty { return tt }
        if let cwd = inst.cwd, !cwd.isEmpty {
            return (cwd as NSString).lastPathComponent
        }
        return inst.cwdShort ?? "(unknown)"
    }
    private func liveRowFullPath(_ inst: LiveInstance) -> String? {
        guard let cwd = inst.cwd, !cwd.isEmpty else { return nil }
        return cwd.replacingOccurrences(of: home, with: "~")
    }

    // ── Menu construction ────────────────────────────────────────────────────

    private func populateMenuItems(_ menu: NSMenu) {
        menu.minimumWidth = 340

        guard let data = cachedData else {
            addDim(menu, "Scanning…")
            menu.addItem(.separator())
            addAction(menu, "Quit", #selector(NSApplication.terminate(_:)), icon: "power")
            return
        }

        // ── Stale data warning ───────────────────────────────────────────────
        if lastScanError {
            addColored(menu, "  ⚠  Scanner error — showing stale data", color: .systemRed, size: 12)
            menu.addItem(.separator())
        }

        // ── Rate limits (top — most urgent info) ────────────────────────────
        addRateLimitsSection(menu, data)

        // ── Usage stats (today/week aggregates) ─────────────────────────────
        addUsageStatsSection(menu, data)

        // ── Live instances ───────────────────────────────────────────────────
        addLiveInstancesSection(menu, data)

        // ── Events ───────────────────────────────────────────────────────────
        addEventsSection(menu, data)

        // ── History ──────────────────────────────────────────────────────────
        addHistorySection(menu, data)

        // ── Actions ──────────────────────────────────────────────────────────
        addActionsSection(menu, data)
    }

    // ── Section: Rate Limits ─────────────────────────────────────────────────

    private func addRateLimitsSection(_ menu: NSMenu, _ data: ScanResult) {
        guard let limits = data.limits else { return }
        guard limits.fiveH != nil || limits.week != nil else { return }

        // Helper: build a bar menu item with label, percentage, color, and optional countdown
        func addBarItem(_ label: String, pct: Int, barChar: String, emptyChar: String,
                        color: NSColor, countdown: String?) {
            let filled = pct * 10 / 100
            let empty = 10 - filled
            let bar = String(repeating: barChar, count: filled) + String(repeating: emptyChar, count: empty)
            var text = " \(label) [\(bar)] \(pct)%"
            if let cd = countdown { text += "  ~\(cd)" }

            let item = NSMenuItem()
            item.attributedTitle = NSAttributedString(string: text, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium),
                .foregroundColor: color,
            ])
            item.isEnabled = false
            menu.addItem(item)
        }

        // 5-hour limit (warm colors: green → yellow → orange → red)
        let safeGreen: NSColor  = menuGreen
        let safeYellow: NSColor = menuYellow
        let safeCyan: NSColor   = menuCyan

        if let fiveH = limits.fiveH {
            let r5 = Int(fiveH.pct)
            var color5: NSColor = safeGreen
            if r5 > 90      { color5 = .systemRed }
            else if r5 > 75 { color5 = .systemOrange }
            else if r5 > 50 { color5 = safeYellow }
            let countdown = rateLimitCountdown(limits.resetsAt)
            addBarItem("⏱ 5h", pct: r5, barChar: "█", emptyChar: "░",
                       color: color5, countdown: countdown)
        }

        // Weekly limit (cool colors: cyan → indigo → purple → red)
        if let week = limits.week {
            let r7 = Int(week.pct)
            var color7: NSColor = safeCyan
            if r7 > 90      { color7 = .systemRed }
            else if r7 > 75 { color7 = .systemPurple }
            else if r7 > 50 { color7 = .systemIndigo }
            let countdown7 = rateLimitCountdown(limits.resetsAtWeekly)
            addBarItem("📅 7d", pct: r7, barChar: "▓", emptyChar: "░",
                       color: color7, countdown: countdown7)
        }

        // Threshold setting — submenu with slider
        let thresholdItem = NSMenuItem()
        thresholdItem.attributedTitle = NSAttributedString(
            string: " ⚙ Warning at \(warningThreshold)%",
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: NSColor.secondaryLabelColor,
            ])

        let subMenu = NSMenu()
        let sliderItem = NSMenuItem()

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 34))

        let label = NSTextField(labelWithString: "Warn at: \(warningThreshold)%")
        label.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.frame = NSRect(x: 14, y: 7, width: 100, height: 20)
        label.tag = 100  // tag for lookup in slider action

        let slider = NSSlider(value: Double(warningThreshold), minValue: 50, maxValue: 100,
                              target: self, action: #selector(thresholdSliderChanged(_:)))
        slider.frame = NSRect(x: 114, y: 7, width: 110, height: 20)
        slider.isContinuous = true
        slider.numberOfTickMarks = 11  // marks every 5%
        slider.allowsTickMarkValuesOnly = true

        container.addSubview(label)
        container.addSubview(slider)
        sliderItem.view = container
        subMenu.addItem(sliderItem)

        thresholdItem.submenu = subMenu
        menu.addItem(thresholdItem)

        menu.addItem(.separator())
    }

    // ── Section: Usage Stats (inline today/week aggregates) ────────────────

    private func addUsageStatsSection(_ menu: NSMenu, _ data: ScanResult) {
        guard let agg = data.aggregates else { return }
        let today = agg.today
        let week = agg.week

        // Only show if we have data
        let todaySessions = today?.sessions ?? 0
        let weekSessions = week?.sessions ?? 0
        guard todaySessions > 0 || weekSessions > 0 else { return }

        // Helper to build a usage row with model badges appended
        func buildUsageRow(label: String, icon: String, period: AggregatesPeriod?, showModels: Bool) -> NSMenuItem {
            let item = NSMenuItem()
            let attr = NSMutableAttributedString()
            attr.append(NSAttributedString(string: " \(icon) \(label) ", attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                .foregroundColor: NSColor.labelColor,
            ]))
            if let p = period {
                var stats: [String] = []
                if let s = p.sessions, s > 0 { stats.append("\(s) sess") }
                if let t = p.turns, t > 0 { stats.append("\(fmtTokens(t)) turns") }
                if let c = p.costUsd, c > 0 { stats.append(fmtCost(c)) }
                attr.append(NSAttributedString(string: stats.joined(separator: " · "), attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]))
            }
            // Append model badges inline on the Today row
            if showModels, let breakdown = agg.modelBreakdown, !breakdown.isEmpty {
                attr.append(NSAttributedString(string: "  ", attributes: [
                    .font: NSFont.systemFont(ofSize: 12),
                ]))
                let sorted = breakdown.sorted { $0.value > $1.value }
                var added = 0
                for entry in sorted {
                    let m = modelDisplay(entry.key)
                    guard m.label != "?" else { continue }
                    if added > 0 {
                        attr.append(NSAttributedString(string: " ", attributes: [
                            .font: NSFont.systemFont(ofSize: 11),
                        ]))
                    }
                    attr.append(NSAttributedString(string: "\(m.badge)\(entry.value)", attributes: [
                        .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
                        .foregroundColor: m.color,
                    ]))
                    added += 1
                }
            }
            item.attributedTitle = attr
            item.isEnabled = false
            return item
        }

        if todaySessions > 0 {
            menu.addItem(buildUsageRow(label: "Today", icon: "📊", period: today, showModels: true))
        }
        if weekSessions > 0 && weekSessions != todaySessions {
            menu.addItem(buildUsageRow(label: "Week", icon: "📈", period: week, showModels: false))
        }

        menu.addItem(.separator())
    }

    // ── Section: Live Instances ──────────────────────────────────────────────

    private func addLiveInstancesSection(_ menu: NSMenu, _ data: ScanResult) {
        let live = data.live

        if live.isEmpty {
            let item = NSMenuItem()
            let attr = NSMutableAttributedString()
            attr.append(NSAttributedString(string: "  No live instances", attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.tertiaryLabelColor,
            ]))
            item.attributedTitle = attr
            item.isEnabled = false
            menu.addItem(item)
            menu.addItem(.separator())
            return
        }

        // Section header with aggregate stats — cumulative cost included
        // so the user has burn-rate awareness without expanding any session.
        let totalRss  = live.compactMap { Int($0.statusline?.rssMb ?? "0") }.reduce(0, +)
        let totalOut  = live.compactMap { $0.outputTokens }.reduce(0, +)
        let totalCost = live.compactMap { $0.costUsd }.reduce(0.0, +)
        var headerParts = ["\(live.count) live"]
        if totalRss  > 0  { headerParts.append("\(totalRss) MB") }
        if totalOut  > 0  { headerParts.append("↑\(fmtTokens(totalOut))") }
        if totalCost > 0  { headerParts.append(fmtCost(totalCost)) }
        addSectionHeader(menu, headerParts.joined(separator: "  ·  "), icon: "sparkles")

        for (idx, inst) in live.enumerated() {
            // Build the live-updating row view. All visual content
            // (header / tab title / full path / state detail / last prompt /
            // metrics / compaction warn / focus file / mcp-down) lives inside
            // ONE NSMenuItem.view so the labels can mutate in place while the
            // menu is open. AppKit doesn't redraw attributedTitle of an open
            // standard menu item — the view-based approach is the workaround.
            let leaf = liveRowLeaf(inst)
            let fullPath = liveRowFullPath(inst)
            let stateStr = inst.sessionState?.state ?? "idle"
            let stateDetail = inst.sessionState?.detail ?? ""
            let stateIcon = liveRowStateIcons[stateStr] ?? ""

            // Generous initial height so the first render isn't clipped
            // even if our setFrameSize() in update() lands a frame too late.
            // update() resizes to actual content immediately after.
            let rowView = LiveRowView(frame: NSRect(x: 0, y: 0, width: 360, height: 200))
            rowView.update(with: inst,
                           leaf: leaf,
                           fullPath: fullPath,
                           stateIcon: stateIcon,
                           stateStr: stateStr,
                           stateDetail: stateDetail,
                           home: home)

            let row = NSMenuItem()
            row.view = rowView
            row.representedObject = inst.cwd
            row.target = self
            row.isEnabled = true
            menu.addItem(row)

            // Track this view so refreshLiveRows() can find it on the next
            // scan tick and call update() on it.
            runningRows[inst.pid] = (row, rowView)

            // Submenu — attached to the single view-based item.
            // Order matches user mental model: "where do I want to go look at
            // this work?" — Finder, Terminal, VSCode are the primary trio,
            // followed by inspect actions (transcript, copy PID), and the
            // destructive Terminate is isolated by a separator.
            let submenu = NSMenu()

            // 1. Open in Finder
            if let cwdPath = inst.cwd, !cwdPath.isEmpty {
                let finderItem = NSMenuItem(title: "Open in Finder", action: #selector(openInFinder(_:)), keyEquivalent: "")
                finderItem.target = self
                finderItem.representedObject = cwdPath
                setIcon(finderItem, "folder")
                submenu.addItem(finderItem)
            }

            // 2. Open in Terminal (Ghostty — focuses existing tab if found,
            //    otherwise spawns a new one. Same handler as the previous
            //    "Focus Terminal" entry; renamed to match the verb pattern.)
            let terminalItem = NSMenuItem(title: "Open in Terminal (Ghostty)",
                                          action: #selector(focusInstance(_:)),
                                          keyEquivalent: "")
            terminalItem.target = self
            terminalItem.representedObject = inst.cwd
            setIcon(terminalItem, "terminal")
            submenu.addItem(terminalItem)

            // 3. Open in VSCode
            if let cwdPath = inst.cwd, !cwdPath.isEmpty {
                let vscodeItem = NSMenuItem(title: "Open in VSCode",
                                            action: #selector(openInVSCode(_:)),
                                            keyEquivalent: "")
                vscodeItem.target = self
                vscodeItem.representedObject = cwdPath
                setIcon(vscodeItem, "chevron.left.forwardslash.chevron.right")
                submenu.addItem(vscodeItem)
            }

            submenu.addItem(.separator())

            if let sid = inst.sessionId, !sid.isEmpty {
                let detailItem = NSMenuItem(title: "View Transcript", action: #selector(openDetail(_:)), keyEquivalent: "")
                detailItem.target = self
                detailItem.representedObject = ["pid": inst.pid, "sessionId": sid] as [String: Any]
                setIcon(detailItem, "doc.text.magnifyingglass")
                submenu.addItem(detailItem)
            }

            let copyItem = NSMenuItem(title: "Copy PID (\(inst.pid))", action: #selector(copyPID(_:)), keyEquivalent: "")
            copyItem.target = self
            copyItem.representedObject = inst.pid
            setIcon(copyItem, "doc.on.clipboard")
            submenu.addItem(copyItem)

            submenu.addItem(.separator())

            let termItem = NSMenuItem(title: "Terminate", action: #selector(terminateInstance(_:)), keyEquivalent: "")
            termItem.target = self
            termItem.representedObject = inst.pid
            termItem.attributedTitle = NSAttributedString(string: "Terminate", attributes: [
                .foregroundColor: NSColor.systemRed,
                .font: NSFont.systemFont(ofSize: 13),
            ])
            setIcon(termItem, "xmark.circle")
            submenu.addItem(termItem)

            row.submenu = submenu

            if idx < live.count - 1 {
                menu.addItem(.separator())
            }
        }
        menu.addItem(.separator())
    }

    // ── Section: Events ──────────────────────────────────────────────────────

    private let eventIcons: [String: String] = [
        "SessionStart": "▶", "Stop": "■", "PermissionRequest": "⚠",
        "PostCompact": "⟳", "PreCompact": "⟲", "SubagentStart": "↳",
        "SubagentStop": "↲", "Notification": "🔔", "PostToolUse": "🔧",
    ]
    private let eventColors: [String: NSColor] = [
        "SessionStart": menuGreen, "Stop": .systemRed,
        "PermissionRequest": .systemOrange, "PostCompact": .systemBlue,
        "PreCompact": .systemBlue, "SubagentStart": .systemPurple,
        "SubagentStop": .systemPurple, "Notification": menuYellow,
        "PostToolUse": menuTeal,
    ]

    private func formatEventItem(_ evt: Event) -> NSAttributedString {
        let icon = eventIcons[evt.event] ?? "·"
        let color = eventColors[evt.event] ?? .secondaryLabelColor
        var ts = evt.ts
        if ts.contains("T") {
            ts = String(ts.split(separator: "T").last?.prefix(5) ?? "?")
        }

        // Model badge
        let m = modelDisplay(evt.model)
        let modelBadge = evt.model != nil ? "\(m.badge) " : ""

        // Event name + tool detail
        var evtName = evt.event
        if evt.event == "PostToolUse", let tool = evt.tool, !tool.isEmpty {
            evtName = tool
        }
        if evtName.count > 14 { evtName = String(evtName.prefix(14)) }

        // Title or project
        var context = ""
        if let tt = evt.tabTitle, !tt.isEmpty {
            context = tt.count > 16 ? "…" + tt.suffix(15) : tt
        } else if let proj = evt.project, !proj.isEmpty {
            context = proj.count > 16 ? "…" + proj.suffix(15) : proj
        }

        let attr = NSMutableAttributedString()
        attr.append(NSAttributedString(string: "  \(icon) ", attributes: [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: color,
        ]))
        if !modelBadge.isEmpty {
            attr.append(NSAttributedString(string: modelBadge, attributes: [
                .font: NSFont.systemFont(ofSize: 11), .foregroundColor: m.color,
            ]))
        }
        attr.append(NSAttributedString(string: "\(ts) ", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]))
        attr.append(NSAttributedString(string: evtName.padding(toLength: 14, withPad: " ", startingAt: 0), attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: color,
        ]))
        if !context.isEmpty {
            attr.append(NSAttributedString(string: " \(context)", attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]))
        }
        return attr
    }

    private func addEventsSection(_ menu: NSMenu, _ data: ScanResult) {
        guard let events = data.recentEvents, !events.isEmpty else { return }

        addSectionHeader(menu, "Recent Events", icon: "list.bullet")

        for evt in events.suffix(7).reversed() {
            let item = NSMenuItem()
            item.attributedTitle = formatEventItem(evt)
            item.isEnabled = false
            menu.addItem(item)
        }

        // Deep history submenu
        if let deepEvents = data.deepEvents, deepEvents.count > 0 {
            let deepItem = NSMenuItem()
            deepItem.attributedTitle = NSAttributedString(string: "  📜 Event History (\(deepEvents.count))…", attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.secondaryLabelColor,
            ])
            deepItem.isEnabled = true

            let deepSubmenu = NSMenu()
            for evt in deepEvents.suffix(30).reversed() {
                let subItem = NSMenuItem()
                subItem.attributedTitle = formatEventItem(evt)
                subItem.isEnabled = false
                deepSubmenu.addItem(subItem)
            }
            deepItem.submenu = deepSubmenu
            menu.addItem(deepItem)
        }

        menu.addItem(.separator())
    }

    // ── Section: History ─────────────────────────────────────────────────────

    private func addHistorySection(_ menu: NSMenu, _ data: ScanResult) {
        let history = data.history
        if history.isEmpty { return }

        addSectionHeader(menu, "History (\(history.count))", icon: "clock.arrow.circlepath")

        for sess in history.prefix(6) {
            let m = modelDisplay(sess.model)
            let rel = relativeTime(sess.modified)
            let label = sess.sessionId.hasPrefix("agent-") ? "↳ agent" : sess.project
            let sz = fmtSize(sess.sizeKb)

            let item = NSMenuItem()
            let attr = NSMutableAttributedString()
            attr.append(NSAttributedString(string: "  \(m.badge) ", attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: m.color,
            ]))
            attr.append(NSAttributedString(string: shortenPath(label, maxLen: 18).padding(toLength: 18, withPad: " ", startingAt: 0), attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor.labelColor,
            ]))
            let costStr = sess.costUsd.map { fmtCost($0) } ?? "–"
            attr.append(NSAttributedString(string: "  \(String(sess.turns).leftPad(4))t  \(sz.leftPad(5))  \(costStr.leftPad(6))  \(rel.leftPad(4))", attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]))
            item.attributedTitle = attr

            // Make history rows clickable — resume session
            item.action = #selector(resumeHistorySession(_:))
            item.target = self
            item.representedObject = [
                "sessionId": sess.sessionId,
                "project": sess.project,
            ] as [String: String]
            item.isEnabled = true
            menu.addItem(item)
        }

        if history.count > 6 {
            addDim(menu, "  … and \(history.count - 6) more (open Dashboard)")
        }
        menu.addItem(.separator())
    }

    // ── Section: Actions ─────────────────────────────────────────────────────

    private func addActionsSection(_ menu: NSMenu, _ data: ScanResult) {
        addAction(menu, "New Session", #selector(newSession), icon: "plus.circle", key: "n")
        addAction(menu, "Dashboard", #selector(openDashboard), icon: "rectangle.3.group", key: "d")
        addRefreshMenu(menu)

        if data.live.count > 0 {
            menu.addItem(.separator())
            let termAll = NSMenuItem(title: "Terminate All (\(data.live.count))",
                                     action: #selector(terminateAll), keyEquivalent: "")
            termAll.target = self
            termAll.attributedTitle = NSAttributedString(
                string: "  Terminate All (\(data.live.count))",
                attributes: [
                    .foregroundColor: NSColor.systemRed,
                    .font: NSFont.systemFont(ofSize: 13),
                ])
            setIcon(termAll, "xmark.circle")
            menu.addItem(termAll)
        }

        menu.addItem(.separator())
        addAction(menu, "Quit Widget", #selector(NSApplication.terminate(_:)), icon: "power")

        // Footer: data freshness — surfaces staleness when cadence is long
        // or paused. Without this, paused refresh has no visible indicator.
        let ageStr: String = {
            guard let t = lastScanAt else { return "never" }
            let s = Int(Date().timeIntervalSince(t))
            if s < 60 { return "\(s)s ago" }
            if s < 3600 { return "\(s/60)m ago" }
            return "\(s/3600)h ago"
        }()
        let cadenceTag = refreshPaused ? "paused" :
                         (refreshInterval < 1 ? String(format: "%.1fs", refreshInterval)
                                              : "\(Int(refreshInterval))s")
        let footer = "  Updated \(ageStr) · refresh: \(cadenceTag)"
        let footerColor: NSColor = refreshPaused ? .systemOrange : .tertiaryLabelColor
        addColored(menu, footer, color: footerColor, size: 10)
    }

    // ── Refresh submenu (manual + cadence picker) ────────────────────────────

    private func addRefreshMenu(_ menu: NSMenu) {
        let parent = NSMenuItem(title: "Refresh", action: nil, keyEquivalent: "")
        setIcon(parent, "arrow.clockwise")

        // Subtitle showing current cadence + last-scan age
        let cadenceLabel: String
        if refreshPaused {
            cadenceLabel = "paused"
        } else {
            let i = refreshInterval
            cadenceLabel = i < 1 ? String(format: "%.1fs", i) : "\(Int(i))s"
        }
        let agePart: String
        if let t = lastScanAt {
            let s = Int(Date().timeIntervalSince(t))
            agePart = "  ·  \(s)s ago"
        } else {
            agePart = ""
        }
        parent.attributedTitle = NSAttributedString(
            string: "  Refresh  (\(cadenceLabel))\(agePart)",
            attributes: [.font: NSFont.systemFont(ofSize: 13)]
        )

        let sub = NSMenu()

        // Manual refresh now
        let now = NSMenuItem(title: "Refresh Now", action: #selector(refreshAction), keyEquivalent: "r")
        now.target = self
        setIcon(now, "arrow.clockwise.circle")
        sub.addItem(now)

        sub.addItem(.separator())

        let header = NSMenuItem()
        header.attributedTitle = NSAttributedString(
            string: "Auto-refresh interval",
            attributes: [
                .foregroundColor: NSColor.tertiaryLabelColor,
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            ])
        header.isEnabled = false
        sub.addItem(header)

        // Cadence presets — radio-style (✓ next to current selection)
        for preset in Self.refreshPresets {
            let label = preset < 1 ? String(format: "%.1f seconds", preset) :
                        preset == 1 ? "1 second" :
                                      "\(Int(preset)) seconds"
            let mi = NSMenuItem(title: label,
                                action: #selector(setRefreshInterval(_:)),
                                keyEquivalent: "")
            mi.target = self
            mi.representedObject = preset
            mi.state = (!refreshPaused && abs(refreshInterval - preset) < 0.01) ? .on : .off
            sub.addItem(mi)
        }

        sub.addItem(.separator())

        // Pause toggle
        let pause = NSMenuItem(title: "Paused",
                               action: #selector(togglePause(_:)),
                               keyEquivalent: "")
        pause.target = self
        pause.state = refreshPaused ? .on : .off
        sub.addItem(pause)

        parent.submenu = sub
        menu.addItem(parent)
    }

    @objc private func setRefreshInterval(_ sender: NSMenuItem) {
        guard let interval = sender.representedObject as? Double else { return }
        refreshInterval = interval
        refreshPaused = false
        dlog("user set refresh interval to \(interval)s")
        restartScanTimer()
        refreshData()
    }

    @objc private func togglePause(_ sender: NSMenuItem) {
        refreshPaused.toggle()
        dlog("refresh \(refreshPaused ? "paused" : "resumed")")
        restartScanTimer()
        if !refreshPaused { refreshData() }
    }

    // ── Action handlers ──────────────────────────────────────────────────────

    @objc private func focusInstance(_ sender: NSMenuItem) {
        guard let cwd = sender.representedObject as? String, !cwd.isEmpty else {
            activateGhostty()
            return
        }
        dlog("focus: cwd=\(cwd)")
        focusGhosttyTab(forCwd: cwd)
    }

    @objc private func terminateInstance(_ sender: NSMenuItem) {
        guard let pid = sender.representedObject as? Int else { return }
        dlog("terminate: pid=\(pid)")
        kill(Int32(pid), SIGTERM)

        // After 3 seconds, force-kill if still alive
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            if kill(Int32(pid), 0) == 0 {
                dlog("force-killing pid=\(pid)")
                kill(Int32(pid), SIGKILL)
            }
        }
    }

    @objc private func copyPID(_ sender: NSMenuItem) {
        guard let pid = sender.representedObject as? Int else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("\(pid)", forType: .string)
        dlog("copied PID \(pid)")
    }

    @objc private func openInFinder(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        dlog("open in Finder: \(path)")
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }

    @objc private func openInVSCode(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String, !path.isEmpty else { return }
        dlog("open in VSCode: \(path)")
        // Try the `code` CLI first (works when "Shell Command: Install 'code'
        // command in PATH" was run from VSCode). Fall back to opening with
        // the .app bundle, which works as long as VSCode is installed.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = ["code", path]
        task.standardOutput = FileHandle.nullDevice
        task.standardError  = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            if task.terminationStatus == 0 { return }
        } catch {
            dwarn("`code` CLI not on PATH (\(fmtErr(error))); falling back to NSWorkspace")
        }
        let url = URL(fileURLWithPath: path)
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        let vscodeBundleURL = URL(fileURLWithPath: "/Applications/Visual Studio Code.app")
        NSWorkspace.shared.open([url], withApplicationAt: vscodeBundleURL,
                                configuration: cfg) { _, err in
            if let err = err { derr("VSCode open failed: \(fmtErr(err))") }
        }
    }

    @objc private func openDetail(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: Any],
              let pid = info["pid"] as? Int,
              let sid = info["sessionId"] as? String else { return }
        dlog("detail: pid=\(pid) sid=\(sid)")

        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/bash")
            task.arguments = [detailScript, "\(pid)", sid]
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            try? task.run()
            task.waitUntilExit()
        }
    }

    @objc private func openDashboard() {
        dlog("opening native dashboard")
        if dashboardController == nil {
            dashboardController = DashboardController()
        }
        dashboardController?.showOrFront(data: cachedData, barDelegate: self)
    }

    @objc private func newSession() {
        dlog("new session — activating Ghostty")
        activateGhostty()
    }

    @objc private func terminateAll() {
        dlog("terminate all")
        guard let data = cachedData else { return }
        for inst in data.live {
            kill(Int32(inst.pid), SIGTERM)
        }
        // Force-kill survivors after 3s
        let pids = data.live.map { $0.pid }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            for pid in pids {
                if kill(Int32(pid), 0) == 0 {
                    kill(Int32(pid), SIGKILL)
                }
            }
        }
    }

    @objc private func refreshAction() {
        dlog("manual refresh (forced full)")
        scanTick = fullScanInterval - 1  // Next tick will be a full scan
        refreshData()
    }

    @objc private func thresholdSliderChanged(_ sender: NSSlider) {
        let newVal = Int(sender.doubleValue)
        warningThreshold = newVal
        dlog("threshold changed to \(newVal)%")
        // Update the label in the same container view
        if let container = sender.superview,
           let label = container.subviews.first(where: { $0.tag == 100 }) as? NSTextField {
            label.stringValue = "Warn at: \(newVal)%"
        }
        // Immediately refresh the menu bar icon to reflect the new threshold
        updateButton()
    }

    @objc private func resumeHistorySession(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: String],
              let sid = info["sessionId"] else { return }
        dlog("resume history: \(sid)")
        resumeSession(sessionId: sid, cwd: nil)
    }

    // ── Menu item helpers ────────────────────────────────────────────────────

    private func addDim(_ menu: NSMenu, _ title: String) {
        let i = NSMenuItem()
        i.attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: NSColor.tertiaryLabelColor,
            .font: NSFont.systemFont(ofSize: 12),
        ])
        i.isEnabled = false
        menu.addItem(i)
    }

    /// Add a multi-line, character-wrapping dim row to the menu.
    /// Uses a view-based NSMenuItem (NSTextField with usesSingleLineMode=false)
    /// because NSMenuItem.attributedTitle does not honor lineBreakMode for
    /// width-based wrapping — it just lets the menu grow horizontally instead.
    /// Used for the full-cwd row under each instance and the focus-file row,
    /// where path length should never trigger an ellipsis.
    private func addWrappingDim(_ menu: NSMenu, _ text: String,
                                color: NSColor = .tertiaryLabelColor,
                                size: CGFloat = 11) {
        let item = NSMenuItem()
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        label.textColor = color
        label.usesSingleLineMode = false
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byCharWrapping
        label.preferredMaxLayoutWidth = 320
        label.translatesAutoresizingMaskIntoConstraints = false
        label.isBezeled = false
        label.isEditable = false
        label.drawsBackground = false

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 1),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -1),
            container.widthAnchor.constraint(greaterThanOrEqualToConstant: 340),
        ])
        item.view = container
        item.isEnabled = false
        menu.addItem(item)
    }

    private func addDimMono(_ menu: NSMenu, _ title: String, size: CGFloat = 12) {
        let i = NSMenuItem()
        i.attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: NSColor.tertiaryLabelColor,
            .font: NSFont.monospacedSystemFont(ofSize: size, weight: .regular),
        ])
        i.isEnabled = false
        menu.addItem(i)
    }

    private func addColored(_ menu: NSMenu, _ title: String, color: NSColor, size: CGFloat = 13) {
        let i = NSMenuItem()
        i.attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: color,
            .font: NSFont.systemFont(ofSize: size),
        ])
        i.isEnabled = false
        menu.addItem(i)
    }

    private func addSectionHeader(_ menu: NSMenu, _ title: String, icon: String) {
        let i = NSMenuItem()
        i.attributedTitle = NSAttributedString(string: "  \(title)", attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .bold),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        setIcon(i, icon)
        i.isEnabled = false
        menu.addItem(i)
    }

    @discardableResult
    private func addAction(_ menu: NSMenu, _ title: String, _ sel: Selector,
                           icon: String? = nil, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        i.attributedTitle = NSAttributedString(string: "  \(title)", attributes: [
            .font: NSFont.systemFont(ofSize: 13),
        ])
        i.target = self
        i.isEnabled = true
        if let icon = icon { setIcon(i, icon) }
        menu.addItem(i)
        return i
    }

    private func setIcon(_ item: NSMenuItem, _ symbol: String) {
        if var img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            img = img.withSymbolConfiguration(cfg) ?? img
            img.isTemplate = true
            item.image = img
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - Native Dashboard (SwiftUI + NSPanel)
// ═══════════════════════════════════════════════════════════════════════════════

// ─── Observable data source (bridges cached scan data → SwiftUI) ─────────────

final class DashboardData: ObservableObject {
    @Published var data: ScanResult?
    @Published var allSessions: [FullSession]?
    @Published var isLoadingAllSessions = false

    func update(_ newData: ScanResult?) {
        DispatchQueue.main.async { self.data = newData }
    }

    func loadAllSessions() {
        guard !isLoadingAllSessions else { return }
        isLoadingAllSessions = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let sessions = scanAllSessions()
            DispatchQueue.main.async {
                self?.allSessions = sessions
                self?.isLoadingAllSessions = false
            }
        }
    }
}

// ─── Dashboard Controller (manages the floating NSPanel) ─────────────────────

final class DashboardController {
    private var panel: NSPanel?
    private let dataSource = DashboardData()
    private var refreshTimer: Timer?

    /// Weak ref back to BarDelegate for action callbacks
    weak var barDelegate: BarDelegate?

    func showOrFront(data: ScanResult?, barDelegate: BarDelegate) {
        self.barDelegate = barDelegate
        dataSource.update(data)

        if let p = panel, p.isVisible {
            p.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        buildAndShow()
        startRefreshTimer()
    }

    func updateData(_ data: ScanResult?) {
        dataSource.update(data)
    }

    private func startRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            guard let self = self, let bd = self.barDelegate else { return }
            self.dataSource.update(bd.cachedData)
        }
    }

    private func buildAndShow() {
        panel?.close()

        let panW: CGFloat = 960, panH: CGFloat = 680

        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: panW, height: panH),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .nonactivatingPanel],
            backing: .buffered, defer: false)
        p.title                = "Claude Instances — Dashboard"
        p.isReleasedWhenClosed = false
        p.level                = .floating
        p.minSize              = NSSize(width: 720, height: 480)
        p.center()

        let rootView = DashboardRootView(dataSource: dataSource, onFocus: { cwd in
            focusGhosttyTab(forCwd: cwd)
        }, onTerminate: { pid in
            kill(Int32(pid), SIGTERM)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                if kill(Int32(pid), 0) == 0 { kill(Int32(pid), SIGKILL) }
            }
        }, onCopyPID: { pid in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("\(pid)", forType: .string)
        }, onResume: { sessionId, cwd in
            resumeSession(sessionId: sessionId, cwd: cwd)
        }, onOpenTranscript: { pid, sessionId in
            // Use detail.sh for live sessions
            DispatchQueue.global(qos: .userInitiated).async {
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/bin/bash")
                task.arguments = [detailScript, "\(pid)", sessionId]
                task.standardOutput = FileHandle.nullDevice
                task.standardError = FileHandle.nullDevice
                try? task.run()
                task.waitUntilExit()
            }
        }, onOpenFile: { path in
            openFile(path)
        })

        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = p.contentView!.bounds
        hostingView.autoresizingMask = [.width, .height]
        p.contentView!.addSubview(hostingView)

        self.panel = p

        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
    }
}

// ─── SwiftUI: Root View with Sidebar Navigation ─────────────────────────────

enum DashboardTab: String, CaseIterable, Identifiable {
    case overview    = "Overview"
    case live        = "Live"
    case history     = "History"
    case events      = "Events"
    case allSessions = "All Sessions"
    case settings    = "Settings"
    case about       = "About"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .overview:    return "square.grid.2x2.fill"
        case .live:        return "sparkles"
        case .history:     return "clock.arrow.circlepath"
        case .events:      return "list.bullet"
        case .allSessions: return "tray.full.fill"
        case .settings:    return "slider.horizontal.3"
        case .about:       return "info.circle"
        }
    }

    var section: String {
        switch self {
        case .overview, .live:          return "Dashboard"
        case .history, .events:         return "Details"
        case .allSessions:              return "Details"
        case .settings, .about:         return "Help"
        }
    }
}

struct SidebarButton: View {
    let tab: DashboardTab
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: tab.symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(isSelected ? .white : iconColor(tab))
                    .frame(width: 24, height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(isSelected ? iconColor(tab) : iconColor(tab).opacity(0.12))
                    )

                Text(tab.rawValue)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? .primary : .secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }

    private func iconColor(_ tab: DashboardTab) -> Color {
        switch tab {
        case .overview:    return .blue
        case .live:        return .green
        case .history:     return .purple
        case .events:      return .orange
        case .allSessions: return .indigo
        case .settings:    return .gray
        case .about:       return .secondary
        }
    }
}

struct DashboardRootView: View {
    @ObservedObject var dataSource: DashboardData
    @State private var selectedTab: DashboardTab = .overview

    let onFocus: (String) -> Void
    let onTerminate: (Int) -> Void
    let onCopyPID: (Int) -> Void
    let onResume: (String, String?) -> Void       // sessionId, cwd
    let onOpenTranscript: (Int, String) -> Void   // pid, sessionId
    let onOpenFile: (String) -> Void              // path

    private var sidebarSections: [(String, [DashboardTab])] {
        let grouped = Dictionary(grouping: DashboardTab.allCases) { $0.section }
        return [
            ("Dashboard", grouped["Dashboard"] ?? []),
            ("Details",   grouped["Details"] ?? []),
            ("Help",      grouped["Help"] ?? [])
        ]
    }

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 0) {
                // App title in sidebar header
                HStack(spacing: 8) {
                    Image(systemName: "cpu")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.accentColor)
                    Text("Claude Instances")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.primary)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 16)

                // Sections
                ForEach(sidebarSections, id: \.0) { section, tabs in
                    Text(section.uppercased())
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.secondary.opacity(0.7))
                        .tracking(0.8)
                        .padding(.horizontal, 16)
                        .padding(.top, section == "Dashboard" ? 0 : 16)
                        .padding(.bottom, 6)

                    ForEach(tabs) { tab in
                        SidebarButton(tab: tab, isSelected: selectedTab == tab) {
                            selectedTab = tab
                            if tab == .allSessions {
                                dataSource.loadAllSessions()
                            }
                        }
                        .padding(.horizontal, 6)
                    }
                }

                Spacer()

                // Live count badge at bottom
                if let d = dataSource.data, d.liveCount > 0 {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(.green)
                            .frame(width: 7, height: 7)
                        Text("\(d.liveCount) running")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                }
            }
            .frame(minWidth: 180, idealWidth: 200, maxWidth: 220)
            .background(.ultraThinMaterial)
        } detail: {
            Group {
                switch selectedTab {
                case .overview:
                    OverviewTabView(data: dataSource.data)
                case .live:
                    LiveTabView(data: dataSource.data, onFocus: onFocus, onTerminate: onTerminate,
                                onCopyPID: onCopyPID, onOpenTranscript: onOpenTranscript)
                case .history:
                    HistoryTabView(data: dataSource.data, onResume: onResume, onOpenFile: onOpenFile)
                case .events:
                    EventsTabView(data: dataSource.data)
                case .allSessions:
                    AllSessionsTabView(dataSource: dataSource, onResume: onResume,
                                       onOpenFile: onOpenFile)
                case .settings:
                    SettingsTabView()
                case .about:
                    AboutTabView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationSplitViewStyle(.balanced)
    }
}

// ─── SwiftUI: Overview Tab ──────────────────────────────────────────────────

struct StatCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(color)
                    .frame(width: 22, height: 22)
                    .background(color.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                Spacer()
            }
            Text(value)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundColor(.primary)
            if let sub = subtitle {
                Text(sub)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary.opacity(0.7))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
        )
    }
}

struct OverviewTabView: View {
    let data: ScanResult?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // Header
                HStack(alignment: .firstTextBaseline) {
                    Text("Overview")
                        .font(.system(size: 22, weight: .bold))
                    Spacer()
                    if let d = data {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(d.liveCount > 0 ? .green : .secondary.opacity(0.4))
                                .frame(width: 7, height: 7)
                            Text("\(d.liveCount) live")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.secondary)
                        }
                    }
                }

                if let d = data {
                    let liveTurns = d.live.compactMap { $0.turns }.reduce(0, +)
                    let liveOut = d.live.compactMap { $0.outputTokens }.reduce(0, +)
                    let liveRss = d.live.compactMap { Int($0.statusline?.rssMb ?? "0") }.reduce(0, +)
                    let histTurns = d.history.reduce(0) { $0 + $1.turns }
                    let histSize = d.history.reduce(0.0) { $0 + $1.sizeKb }
                    let histTokensIn = d.history.reduce(0) { $0 + ($1.tokensIn ?? 0) }
                    let histTokensOut = d.history.reduce(0) { $0 + ($1.tokensOut ?? 0) }
                    let histCost = d.history.reduce(0.0) { $0 + ($1.costUsd ?? 0) }
                    let avgTurns = d.history.isEmpty ? 0 : histTurns / d.history.count

                    // Model breakdown
                    let modelCounts = Dictionary(grouping: d.history) { $0.model ?? "unknown" }
                        .mapValues { $0.count }

                    // ── Today / This Week aggregates (from scan.sh) ──
                    if let agg = d.aggregates, (agg.today != nil || agg.week != nil) {
                        HStack(alignment: .top, spacing: 10) {
                            if let today = agg.today {
                                OverviewSection(title: "Today", icon: "sun.max.fill", iconColor: .yellow) {
                                    VStack(spacing: 8) {
                                        HStack(spacing: 0) {
                                            AggregateMetric(label: "Sessions", value: "\(today.sessions ?? 0)", color: .blue)
                                            Divider().frame(height: 28)
                                            AggregateMetric(label: "Turns", value: fmtTokens(today.turns ?? 0), color: .purple)
                                            Spacer()
                                        }
                                        HStack(spacing: 0) {
                                            AggregateMetric(label: "Tokens In", value: fmtTokens(today.tokensIn ?? 0), color: .cyan)
                                            Divider().frame(height: 28)
                                            AggregateMetric(label: "Tokens Out", value: fmtTokens(today.tokensOut ?? 0), color: .indigo)
                                            Divider().frame(height: 28)
                                            AggregateMetric(label: "Cost", value: fmtCost(today.costUsd ?? 0), color: .mint)
                                            Spacer()
                                        }
                                    }
                                }
                            }
                            if let week = agg.week {
                                OverviewSection(title: "This Week", icon: "calendar", iconColor: .blue) {
                                    VStack(spacing: 8) {
                                        HStack(spacing: 0) {
                                            AggregateMetric(label: "Sessions", value: "\(week.sessions ?? 0)", color: .blue)
                                            Divider().frame(height: 28)
                                            AggregateMetric(label: "Turns", value: fmtTokens(week.turns ?? 0), color: .purple)
                                            Spacer()
                                        }
                                        HStack(spacing: 0) {
                                            AggregateMetric(label: "Tokens In", value: fmtTokens(week.tokensIn ?? 0), color: .cyan)
                                            Divider().frame(height: 28)
                                            AggregateMetric(label: "Tokens Out", value: fmtTokens(week.tokensOut ?? 0), color: .indigo)
                                            Divider().frame(height: 28)
                                            AggregateMetric(label: "Cost", value: fmtCost(week.costUsd ?? 0), color: .mint)
                                            Spacer()
                                        }
                                    }
                                }
                            }
                        }

                        // Model breakdown badges (from aggregates)
                        if let mb = agg.modelBreakdown, !mb.isEmpty {
                            OverviewSection(title: "Model Usage", icon: "cpu.fill", iconColor: .pink) {
                                HStack(spacing: 8) {
                                    ForEach(mb.sorted(by: { $0.value > $1.value }), id: \.key) { model, count in
                                        let m = modelDisplay(model)
                                        HStack(spacing: 4) {
                                            Text(m.badge)
                                            Text(m.label)
                                                .font(.system(size: 12, weight: .bold))
                                            Text("×\(count)")
                                                .font(.system(size: 12))
                                                .foregroundColor(.secondary)
                                        }
                                        .foregroundColor(Color(nsColor: m.color))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(
                                            Capsule().fill(Color(nsColor: m.color).opacity(0.1))
                                        )
                                    }
                                    Spacer()
                                }
                            }
                        }
                    }

                    // ── Top stat cards (2 rows of 4) ──
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                        StatCard(title: "Live", value: "\(d.liveCount)", icon: "bolt.fill", color: .green,
                                 subtitle: liveRss > 0 ? "\(liveRss) MB RAM" : nil)
                        StatCard(title: "Sessions", value: "\(d.history.count)", icon: "tray.full.fill", color: .blue,
                                 subtitle: "avg \(avgTurns) turns")
                        StatCard(title: "Turns", value: fmtTokens(histTurns), icon: "arrow.triangle.2.circlepath", color: .purple,
                                 subtitle: "\(fmtTokens(liveTurns)) active")
                        StatCard(title: "Size", value: fmtSize(histSize), icon: "internaldrive.fill", color: .orange)
                        StatCard(title: "Tokens In", value: fmtTokens(histTokensIn), icon: "arrow.down.circle.fill", color: .cyan)
                        StatCard(title: "Tokens Out", value: fmtTokens(histTokensOut), icon: "arrow.up.circle.fill", color: .indigo,
                                 subtitle: liveOut > 0 ? "\(fmtTokens(liveOut)) active" : nil)
                        StatCard(title: "Est. Cost", value: fmtCost(histCost), icon: "dollarsign.circle.fill", color: .mint)
                        StatCard(title: "Models", value: "\(modelCounts.count)", icon: "cpu.fill", color: .pink,
                                 subtitle: modelCounts.sorted(by: { $0.value > $1.value }).prefix(2)
                                     .map { "\($0.key) ×\($0.value)" }.joined(separator: ", "))
                    }

                    // ── Two-column middle: Rate limits + Live aggregate ──
                    HStack(alignment: .top, spacing: 10) {
                        // Rate limits
                        if let limits = d.limits {
                            OverviewSection(title: "Usage Limits", icon: "gauge.with.dots.needle.33percent", iconColor: .cyan) {
                                VStack(spacing: 10) {
                                    if let fiveH = limits.fiveH {
                                        RateLimitRow(label: "5 Hour", entry: fiveH)
                                    }
                                    if let week = limits.week {
                                        RateLimitRow(label: "Weekly", entry: week)
                                    }
                                    if let countdown = rateLimitCountdown(limits.resetsAt) {
                                        HStack(spacing: 4) {
                                            Image(systemName: "clock.arrow.circlepath")
                                                .font(.system(size: 11))
                                                .foregroundColor(.secondary)
                                            Text("Resets in \(countdown)")
                                                .font(.system(size: 12, weight: .medium))
                                                .foregroundColor(.secondary)
                                        }
                                        .padding(.top, 2)
                                    }
                                }
                            }
                        }

                        // Live aggregate (only when running)
                        if d.liveCount > 0 {
                            OverviewSection(title: "Active Totals", icon: "bolt.fill", iconColor: .yellow) {
                                HStack(spacing: 0) {
                                    AggregateMetric(label: "Turns", value: "\(liveTurns)", color: .blue)
                                    Divider().frame(height: 28)
                                    AggregateMetric(label: "Output", value: fmtTokens(liveOut), color: .purple)
                                    Divider().frame(height: 28)
                                    AggregateMetric(label: "Memory", value: "\(liveRss) MB", color: .orange)
                                    Spacer()
                                }
                            }
                        }
                    }

                    // ── Recent events ──
                    if let events = d.recentEvents, !events.isEmpty {
                        OverviewSection(title: "Recent Events", icon: "clock", iconColor: .blue) {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(events.suffix(5).reversed().enumerated()), id: \.offset) { idx, evt in
                                    HStack(spacing: 10) {
                                        VStack(spacing: 0) {
                                            if idx > 0 {
                                                Rectangle()
                                                    .fill(Color.secondary.opacity(0.2))
                                                    .frame(width: 1, height: 4)
                                            }
                                            Circle()
                                                .fill(eventColor(evt.event))
                                                .frame(width: 7, height: 7)
                                            if idx < min(4, events.count - 1) {
                                                Rectangle()
                                                    .fill(Color.secondary.opacity(0.2))
                                                    .frame(width: 1, height: 4)
                                            }
                                        }
                                        .frame(width: 7)

                                        Text(eventTime(evt.ts))
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundColor(.secondary)
                                            .frame(width: 42, alignment: .leading)

                                        EventBadge(event: evt.event)

                                        // Model badge inline
                                        if let model = evt.model, !model.isEmpty {
                                            let em = modelDisplay(model)
                                            Text(em.badge)
                                                .font(.system(size: 10))
                                                .foregroundColor(Color(nsColor: em.color))
                                        }

                                        Text(evt.tabTitle ?? evt.project ?? "")
                                            .font(.system(size: 11))
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                        Spacer()
                                    }
                                }
                            }
                        }
                    }
                } else {
                    VStack(spacing: 12) {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text("Scanning…")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 200)
                }
            }
            .padding(20)
        }
    }
}

/// Reusable section container for overview cards
struct OverviewSection<Content: View>: View {
    let title: String
    let icon: String
    let iconColor: Color
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(iconColor)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
        )
    }
}

struct AggregateMetric: View {
    let label: String
    let value: String
    let color: Color

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundColor(color)
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .frame(minWidth: 80)
        .padding(.horizontal, 12)
    }
}

struct EventBadge: View {
    let event: String

    var body: some View {
        Text(eventLabel(event))
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(eventColor(event))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(eventColor(event).opacity(0.12))
            )
    }
}

struct RateLimitRow: View {
    let label: String
    let entry: RateLimitEntry

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                Text("\(Int(entry.pct))%")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundColor(barColor)
                if entry.used > 0 || entry.cap > 0 {
                    Text("(\(fmtTokens(entry.used))/\(fmtTokens(entry.cap)))")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.secondary.opacity(0.15))
                    RoundedRectangle(cornerRadius: 4)
                        .fill(barColor)
                        .frame(width: geo.size.width * CGFloat(entry.pct / 100.0))
                }
            }
            .frame(height: 6)
        }
    }

    private var barColor: Color {
        if entry.pct > 90 { return .red }
        if entry.pct > 75 { return .orange }
        return .green
    }
}

// ─── SwiftUI: Live Instances Tab ────────────────────────────────────────────

struct LiveTabView: View {
    let data: ScanResult?
    let onFocus: (String) -> Void
    let onTerminate: (Int) -> Void
    let onCopyPID: (Int) -> Void
    let onOpenTranscript: (Int, String) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Live Instances")
                        .font(.system(size: 22, weight: .bold))
                    Spacer()
                    if let d = data {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(d.liveCount > 0 ? .green : .secondary.opacity(0.4))
                                .frame(width: 7, height: 7)
                            Text("\(d.liveCount) running")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.secondary)
                        }
                    }
                }

                if let d = data, !d.live.isEmpty {
                    ForEach(Array(d.live.enumerated()), id: \.element.pid) { _, inst in
                        InstanceCard(inst: inst, onFocus: onFocus, onTerminate: onTerminate,
                                     onCopyPID: onCopyPID, onOpenTranscript: onOpenTranscript)
                    }
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 40))
                            .foregroundColor(.secondary.opacity(0.3))
                        Text("No live Claude instances")
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                        Text("Start a Claude session to see it here")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary.opacity(0.6))
                    }
                    .frame(maxWidth: .infinity, minHeight: 240)
                }
            }
            .padding(24)
        }
    }
}

struct InstanceCard: View {
    let inst: LiveInstance
    let onFocus: (String) -> Void
    let onTerminate: (Int) -> Void
    let onCopyPID: (Int) -> Void
    let onOpenTranscript: (Int, String) -> Void

    @State private var isHovered = false

    @State private var blinkOn = true

    var body: some View {
        let m = modelDisplay(inst.model)
        let stateStr = inst.sessionState?.state ?? "idle"
        let isActive = stateStr != "idle"

        VStack(alignment: .leading, spacing: 12) {
            // Header row: model pill + state + title/path + elapsed
            HStack(spacing: 10) {
                // Model pill
                HStack(spacing: 5) {
                    Text(m.badge)
                    Text(m.label)
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                }
                .foregroundColor(Color(nsColor: m.color))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(Color(nsColor: m.color).opacity(0.12))
                )

                // Session state pill (blinking when active)
                if isActive {
                    let stateLabels: [String: String] = [
                        "thinking": "Thinking", "responding": "Writing",
                        "tool_use": "Tool", "tool_result": "Processing",
                    ]
                    let stateColors: [String: Color] = [
                        "thinking": .yellow, "responding": .green,
                        "tool_use": .teal, "tool_result": .blue,
                    ]
                    let label = stateLabels[stateStr] ?? stateStr
                    let stColor = stateColors[stateStr] ?? .secondary

                    Text(label)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(stColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule().fill(stColor.opacity(blinkOn ? 0.15 : 0.05))
                        )
                        .opacity(blinkOn ? 1.0 : 0.5)
                        .onAppear {
                            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                                blinkOn.toggle()
                            }
                        }
                }

                // Subagent badge
                if let subs = inst.subagentCount, subs > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 10))
                        Text("\(subs)")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(.purple)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.purple.opacity(0.12)))
                }

                Spacer()

                Text(inst.elapsed?.trimmingCharacters(in: .whitespaces) ?? "?")
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundColor(.orange)
            }

            // Tab title / path row
            HStack(spacing: 6) {
                if let tabTitle = inst.tabTitle, !tabTitle.isEmpty {
                    Text(tabTitle)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    Text("·")
                        .foregroundColor(.secondary.opacity(0.4))
                    Text(inst.cwdShort ?? inst.cwd ?? "?")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                } else {
                    Text(inst.cwdShort ?? inst.cwd ?? "?")
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(1)
                }
            }

            // Primary metadata row
            HStack(spacing: 0) {
                MetadataItem(icon: "number", text: "PID \(inst.pid)")

                if let cpu = inst.statusline?.cpu, !cpu.isEmpty, cpu != "0" {
                    MetadataItem(icon: "cpu", text: "\(cpu)%")
                }

                if let rss = inst.statusline?.rssMb, !rss.isEmpty, rss != "0" {
                    MetadataItem(icon: "memorychip", text: "\(rss) MB")
                }

                if let t = inst.turns, t > 0 {
                    MetadataItem(icon: "arrow.triangle.2.circlepath", text: "\(t) turns")
                }

                if let tc = inst.toolCalls, tc > 0 {
                    MetadataItem(icon: "wrench.fill", text: "\(tc) tools")
                }

                if let o = inst.outputTokens, o > 0 {
                    MetadataItem(icon: "arrow.up", text: fmtTokens(o) + " tok")
                }

                if let c = inst.costUsd, c > 0 {
                    MetadataItem(icon: "dollarsign.circle", text: fmtCost(c))
                }

                Spacer()
            }

            // Context remaining + secondary metrics row
            HStack(spacing: 0) {
                if let ctx = inst.statusline?.ctxRemaining, !ctx.isEmpty, ctx != "0" {
                    let ctxInt = Int(ctx) ?? 100
                    let ctxColor: Color = ctxInt < 30 ? .red : (ctxInt < 60 ? .orange : .green)
                    HStack(spacing: 4) {
                        Image(systemName: "circle.lefthalf.filled")
                            .font(.system(size: 10))
                            .foregroundColor(ctxColor)
                        Text("ctx \(ctx)%")
                            .font(.system(size: 12))
                            .foregroundColor(ctxColor)
                    }
                    .padding(.trailing, 16)
                }

                if let ts = inst.statusline?.tokSpeed, !ts.isEmpty, ts != "0" {
                    MetadataItem(icon: "bolt.fill", text: "\(ts) tok/s")
                }
                if let cv = inst.statusline?.costVel, !cv.isEmpty, cv != "0" {
                    MetadataItem(icon: "dollarsign.circle", text: "\(cv) cpm")
                }
                if let wal = inst.statusline?.walSinceCp, !wal.isEmpty, wal != "0" {
                    MetadataItem(icon: "arrow.clockwise", text: "\(wal) since cp")
                }
                if let mcp = inst.statusline?.mcpHealthy, !mcp.isEmpty {
                    let count = mcp.split(separator: ",").count
                    MetadataItem(icon: "checkmark.circle", text: "\(count) MCP")
                }
                Spacer()
            }

            // Focus file
            if let focus = inst.statusline?.focusFile, !focus.isEmpty {
                let display = focus
                    .replacingOccurrences(of: inst.cwd ?? "", with: ".")
                    .replacingOccurrences(of: home, with: "~")
                HStack(spacing: 6) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary.opacity(0.6))
                    Text(display)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                .padding(.horizontal, 4)
            }

            // MCP down warning
            if let mcpDown = inst.statusline?.mcpDown, !mcpDown.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.red)
                    Text("MCP down: \(mcpDown)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.red)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.red.opacity(0.08))
                )
            }

            // Action buttons — fade in on hover
            HStack(spacing: 8) {
                Button(action: { onFocus(inst.cwd ?? "") }) {
                    Label("Focus", systemImage: "terminal")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.bordered)

                if let sid = inst.sessionId, !sid.isEmpty {
                    Button(action: { onOpenTranscript(inst.pid, sid) }) {
                        Label("Transcript", systemImage: "doc.text.magnifyingglass")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                }

                Button(action: { onCopyPID(inst.pid) }) {
                    Label("Copy PID", systemImage: "doc.on.clipboard")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.bordered)

                Spacer()

                Button(action: { onTerminate(inst.pid) }) {
                    Label("Terminate", systemImage: "xmark.circle")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.red)
                }
                .buttonStyle(.bordered)
            }
            .opacity(isHovered ? 1.0 : 0.4)
            .animation(.easeInOut(duration: 0.15), value: isHovered)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    isHovered ? Color(nsColor: m.color).opacity(0.5) : Color.white.opacity(0.06),
                    lineWidth: 1
                )
        )
        .shadow(color: isHovered ? Color(nsColor: m.color).opacity(0.08) : .clear, radius: 8, y: 2)
        .onHover { hovering in isHovered = hovering }
        .animation(.easeInOut(duration: 0.15), value: isHovered)
    }
}

struct MetadataItem: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundColor(.secondary.opacity(0.6))
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
        .padding(.trailing, 16)
    }
}

// ─── SwiftUI: History Tab ───────────────────────────────────────────────────

struct HistoryTabView: View {
    let data: ScanResult?
    let onResume: (String, String?) -> Void
    let onOpenFile: (String) -> Void

    @State private var sortOrder: HistorySortOrder = .modified
    @State private var ascending: Bool = false
    @State private var searchText: String = ""
    @State private var showSubagents: Bool = true

    enum HistorySortOrder: Equatable {
        case project, model, turns, tokensOut, cost, size, modified

        /// Default ascending direction for each column (true = natural ascending)
        var defaultAscending: Bool {
            switch self {
            case .project, .model: return true
            case .turns, .tokensOut, .cost, .size, .modified: return false
            }
        }

        func compare(_ a: SessionHistory, _ b: SessionHistory, ascending: Bool) -> Bool {
            let result: Bool
            switch self {
            case .project:   result = a.project < b.project
            case .model:     result = (a.model ?? "") < (b.model ?? "")
            case .turns:     result = a.turns > b.turns
            case .tokensOut: result = (a.tokensOut ?? 0) > (b.tokensOut ?? 0)
            case .cost:      result = (a.costUsd ?? 0) > (b.costUsd ?? 0)
            case .size:      result = a.sizeKb > b.sizeKb
            case .modified:  result = (a.modified ?? "") > (b.modified ?? "")
            }
            return ascending ? !result : result
        }
    }

    private var filteredSessions: [SessionHistory] {
        guard let d = data else { return [] }
        var sessions = d.history
        // Filter subagents
        if !showSubagents {
            sessions = sessions.filter { !$0.sessionId.hasPrefix("agent-") }
        }
        // Search filter
        if !searchText.isEmpty {
            let q = searchText.lowercased()
            sessions = sessions.filter {
                $0.project.lowercased().contains(q) ||
                $0.sessionId.lowercased().contains(q) ||
                ($0.model ?? "").lowercased().contains(q)
            }
        }
        return sessions.sorted { sortOrder.compare($0, $1, ascending: ascending) }
    }

    private func toggleSort(_ col: HistorySortOrder) {
        if sortOrder == col {
            ascending.toggle()
        } else {
            sortOrder = col
            ascending = col.defaultAscending
        }
    }

    /// Summary stats for visible sessions
    private var summaryStats: (sessions: Int, totalTurns: Int, totalTokensIn: Int, totalTokensOut: Int, totalSizeKb: Double, totalCost: Double) {
        let visible = filteredSessions
        return (
            sessions: visible.count,
            totalTurns: visible.reduce(0) { $0 + $1.turns },
            totalTokensIn: visible.reduce(0) { $0 + ($1.tokensIn ?? 0) },
            totalTokensOut: visible.reduce(0) { $0 + ($1.tokensOut ?? 0) },
            totalSizeKb: visible.reduce(0.0) { $0 + $1.sizeKb },
            totalCost: visible.reduce(0.0) { $0 + ($1.costUsd ?? 0) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(alignment: .firstTextBaseline) {
                Text("Session History")
                    .font(.system(size: 22, weight: .bold))
                Spacer()
                let stats = summaryStats
                if stats.sessions > 0 {
                    HStack(spacing: 12) {
                        Text("\(stats.sessions) sessions")
                        Text("\(fmtTokens(stats.totalTokensOut)) out")
                        if stats.totalCost > 0 {
                            Text(fmtCost(stats.totalCost))
                        }
                        Text(fmtSize(stats.totalSizeKb))
                    }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 12)

            // Search bar + agent toggle
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    TextField("Search projects, sessions, models...", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )

                Button(action: { showSubagents.toggle() }) {
                    HStack(spacing: 4) {
                        Image(systemName: showSubagents ? "eye" : "eye.slash")
                            .font(.system(size: 11))
                        Text("Agents")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(showSubagents ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.08))
                    )
                    .foregroundColor(showSubagents ? .accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .help(showSubagents ? "Hide subagent sessions" : "Show subagent sessions")
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 12)

            if !filteredSessions.isEmpty {
                let maxSize = filteredSessions.map { $0.sizeKb }.max() ?? 1
                let sorted = filteredSessions

                // Column headers
                HStack(spacing: 0) {
                    ColumnHeader(title: "Project", width: 170, alignment: .leading,
                                 isActive: sortOrder == .project, ascending: ascending) { toggleSort(.project) }
                    ColumnHeader(title: "Model", width: 80, alignment: .leading,
                                 isActive: sortOrder == .model, ascending: ascending) { toggleSort(.model) }
                    ColumnHeader(title: "Turns", width: 55, alignment: .trailing,
                                 isActive: sortOrder == .turns, ascending: ascending) { toggleSort(.turns) }
                    ColumnHeader(title: "Tokens", width: 65, alignment: .trailing,
                                 isActive: sortOrder == .tokensOut, ascending: ascending) { toggleSort(.tokensOut) }
                    ColumnHeader(title: "Cost", width: 50, alignment: .trailing,
                                 isActive: sortOrder == .cost, ascending: ascending) { toggleSort(.cost) }
                    ColumnHeader(title: "Size", width: 50, alignment: .trailing,
                                 isActive: sortOrder == .size, ascending: ascending) { toggleSort(.size) }
                    Spacer().frame(width: 70) // bar column
                    ColumnHeader(title: "Last Active", width: 80, alignment: .trailing,
                                 isActive: sortOrder == .modified, ascending: ascending) { toggleSort(.modified) }
                    Spacer().frame(width: 80) // action buttons space
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 8)

                Rectangle()
                    .fill(Color.secondary.opacity(0.15))
                    .frame(height: 1)
                    .padding(.horizontal, 20)

                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(sorted.enumerated()), id: \.element.sessionId) { idx, sess in
                            HistoryRow(session: sess, isEven: idx % 2 == 0,
                                       maxSize: maxSize,
                                       onResume: onResume, onOpenFile: onOpenFile)
                        }
                    }
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: searchText.isEmpty ? "clock.arrow.circlepath" : "magnifyingglass")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary.opacity(0.3))
                    Text(searchText.isEmpty ? "No session history" : "No matching sessions")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

// ─── History Row (extracted for hover state) ───────────────────────────────

private struct HistoryRow: View {
    let session: SessionHistory
    let isEven: Bool
    let maxSize: Double
    let onResume: (String, String?) -> Void
    let onOpenFile: (String) -> Void

    @State private var isHovered = false

    private var isAgent: Bool { session.sessionId.hasPrefix("agent-") }

    /// Reconstruct a plausible cwd from the session's JSONL path
    private var sessionCwd: String? {
        // session JSONL lives at ~/.claude/projects/<dir-name>/<sessionId>.jsonl
        // project display is already shortened, so we use nil (resume from home)
        return nil
    }

    var body: some View {
        let m = modelDisplay(session.model)
        HStack(spacing: 0) {
            // Project column — show parent project dimmed for agents
            Group {
                if isAgent {
                    HStack(spacing: 3) {
                        Text("↳")
                            .foregroundColor(.secondary.opacity(0.5))
                        Text(session.project)
                            .foregroundColor(.secondary.opacity(0.6))
                    }
                } else {
                    Text(session.project)
                }
            }
            .lineLimit(1)
            .frame(width: 170, alignment: .leading)

            // Model badge
            HStack(spacing: 4) {
                Text(m.badge).foregroundColor(Color(nsColor: m.color))
                Text(m.label).foregroundColor(Color(nsColor: m.color))
            }
            .font(.system(size: 12, weight: .medium))
            .frame(width: 80, alignment: .leading)

            // Turns
            Text("\(session.turns)")
                .frame(width: 55, alignment: .trailing)

            // Tokens (output tokens — most meaningful metric)
            Text(session.tokensOut.map { fmtTokens($0) } ?? "–")
                .foregroundColor(.secondary)
                .frame(width: 65, alignment: .trailing)
                .help(tokenTooltip)

            // Cost
            Text(session.costUsd.map { fmtCost($0) } ?? "–")
                .foregroundColor(costColor)
                .frame(width: 50, alignment: .trailing)
                .help(session.costUsd.map { String(format: "$%.4f", $0) } ?? "No cost data")

            // Size
            Text(fmtSize(session.sizeKb))
                .frame(width: 50, alignment: .trailing)

            // Size bar with tooltip
            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 3)
                    .fill(
                        LinearGradient(
                            colors: [Color.blue.opacity(0.3), Color.blue.opacity(0.6)],
                            startPoint: .leading, endPoint: .trailing
                        )
                    )
                    .frame(width: max(2, geo.size.width * CGFloat(session.sizeKb / maxSize)), height: 6)
                    .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(width: 70, height: 16)
            .help("JSONL size: \(fmtSize(session.sizeKb)) (relative bar)")

            // Last Active with absolute time tooltip
            Text(relativeTime(session.modified))
                .foregroundColor(.secondary)
                .frame(width: 80, alignment: .trailing)
                .help(session.modified ?? "Unknown")

            // Action buttons — visible on hover
            HStack(spacing: 6) {
                if isHovered {
                    Button(action: { onResume(session.sessionId, sessionCwd) }) {
                        Image(systemName: "play.circle")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.bordered)
                    .help("Resume session")

                    Button(action: {
                        // Find the JSONL path for this session
                        let projectsDir = NSString(string: "~/.claude/projects").expandingTildeInPath
                        let jsonlPath = findJsonlPath(projectsDir: projectsDir, sessionId: session.sessionId)
                        if let path = jsonlPath { onOpenFile(path) }
                    }) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.bordered)
                    .help("View transcript")
                }
            }
            .frame(width: 80, alignment: .trailing)
            .transition(.opacity)
        }
        .font(.system(size: 13, design: .monospaced))
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
        .background(isHovered ? Color.accentColor.opacity(0.06) :
                     (isEven ? Color.clear : Color.secondary.opacity(0.04)))
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) { isHovered = hovering }
        }
    }

    private var tokenTooltip: String {
        let inTok = session.tokensIn.map { fmtTokens($0) } ?? "?"
        let outTok = session.tokensOut.map { fmtTokens($0) } ?? "?"
        return "In: \(inTok)  Out: \(outTok)"
    }

    private var costColor: Color {
        guard let c = session.costUsd else { return .secondary }
        if c >= 1.0 { return .red }
        if c >= 0.25 { return .orange }
        return .secondary
    }
}

/// Find a session's JSONL file by scanning ~/.claude/projects/
private func findJsonlPath(projectsDir: String, sessionId: String) -> String? {
    let fm = FileManager.default
    guard let dirs = try? fm.contentsOfDirectory(atPath: projectsDir) else { return nil }
    for dir in dirs {
        let path = "\(projectsDir)/\(dir)/\(sessionId).jsonl"
        if fm.fileExists(atPath: path) { return path }
    }
    return nil
}

struct ColumnHeader: View {
    let title: String
    let width: CGFloat
    let alignment: Alignment
    let isActive: Bool
    let ascending: Bool
    let action: () -> Void

    init(title: String, width: CGFloat, alignment: Alignment,
         isActive: Bool, ascending: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.width = width
        self.alignment = alignment
        self.isActive = isActive
        self.ascending = ascending
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                if isActive {
                    Image(systemName: ascending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(isActive ? .accentColor : .secondary)
            .textCase(.uppercase)
        }
        .buttonStyle(.plain)
        .frame(width: width, alignment: alignment)
    }
}

// ─── SwiftUI: Events Tab ────────────────────────────────────────────────────

struct EventsTabView: View {
    let data: ScanResult?

    @State private var filterType: String = "All"
    @State private var showDeepHistory: Bool = false

    private var allEventTypes: [String] {
        var types = Set<String>()
        if let events = data?.recentEvents { events.forEach { types.insert($0.event) } }
        if let deep = data?.deepEvents { deep.forEach { types.insert($0.event) } }
        return ["All"] + types.sorted()
    }

    private var displayEvents: [Event] {
        let source: [Event]
        if showDeepHistory, let deep = data?.deepEvents, !deep.isEmpty {
            source = deep
        } else {
            source = data?.recentEvents ?? []
        }
        if filterType == "All" { return source.reversed() }
        return source.filter { $0.event == filterType }.reversed()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(alignment: .firstTextBaseline) {
                Text("Events")
                    .font(.system(size: 22, weight: .bold))
                Spacer()
                Text("\(displayEvents.count) events")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 8)

            // Filter bar
            HStack(spacing: 12) {
                // Deep history toggle
                if data?.deepEvents != nil {
                    Toggle(isOn: $showDeepHistory) {
                        Text("Deep History")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }

                Spacer()

                // Event type filter
                Picker("Type", selection: $filterType) {
                    ForEach(allEventTypes, id: \.self) { type in
                        Text(type == "All" ? "All Types" : eventLabel(type))
                            .tag(type)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 160)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 12)

            Rectangle()
                .fill(Color.secondary.opacity(0.15))
                .frame(height: 1)
                .padding(.horizontal, 20)

            if !displayEvents.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(displayEvents.enumerated()), id: \.offset) { idx, evt in
                            HStack(alignment: .top, spacing: 16) {
                                // Timeline column — dot with connecting lines
                                VStack(spacing: 0) {
                                    Rectangle()
                                        .fill(idx == 0 ? Color.clear : Color.secondary.opacity(0.2))
                                        .frame(width: 1, height: 12)
                                    Circle()
                                        .fill(eventColor(evt.event))
                                        .frame(width: 10, height: 10)
                                    Rectangle()
                                        .fill(idx == displayEvents.count - 1 ? Color.clear : Color.secondary.opacity(0.2))
                                        .frame(width: 1)
                                        .frame(maxHeight: .infinity)
                                }
                                .frame(width: 10)

                                // Event content
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 8) {
                                        EventBadge(event: evt.event)

                                        // Model badge
                                        if let model = evt.model, !model.isEmpty {
                                            let m = modelDisplay(model)
                                            HStack(spacing: 3) {
                                                Text(m.badge)
                                                Text(m.label)
                                                    .font(.system(size: 11, weight: .bold))
                                            }
                                            .foregroundColor(Color(nsColor: m.color))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(
                                                Capsule().fill(Color(nsColor: m.color).opacity(0.1))
                                            )
                                        }

                                        Text(eventTime(evt.ts))
                                            .font(.system(size: 12, design: .monospaced))
                                            .foregroundColor(.secondary)
                                    }

                                    // Tab title or project
                                    HStack(spacing: 6) {
                                        if let title = evt.tabTitle, !title.isEmpty {
                                            Text(title)
                                                .font(.system(size: 13, weight: .medium))
                                                .foregroundColor(.primary.opacity(0.9))
                                                .lineLimit(1)
                                            if let proj = evt.project, !proj.isEmpty {
                                                Text("·")
                                                    .foregroundColor(.secondary.opacity(0.4))
                                                Text(proj)
                                                    .font(.system(size: 12))
                                                    .foregroundColor(.secondary)
                                                    .lineLimit(1)
                                            }
                                        } else if let proj = evt.project, !proj.isEmpty {
                                            Text(proj)
                                                .font(.system(size: 13))
                                                .foregroundColor(.primary.opacity(0.8))
                                                .lineLimit(1)
                                        }
                                    }

                                    // Tool detail for PostToolUse events
                                    if evt.event == "PostToolUse", let tool = evt.tool, !tool.isEmpty {
                                        HStack(spacing: 4) {
                                            Image(systemName: "wrench.fill")
                                                .font(.system(size: 9))
                                                .foregroundColor(.teal.opacity(0.7))
                                            Text(tool)
                                                .font(.system(size: 11, design: .monospaced))
                                                .foregroundColor(.teal)
                                        }
                                    }

                                    if let sid = evt.sessionId, !sid.isEmpty {
                                        Text(sid)
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundColor(.secondary.opacity(0.6))
                                            .lineLimit(1)
                                    }
                                }
                                .padding(.vertical, 6)

                                Spacer()
                            }
                            .frame(minHeight: 56)
                        }
                    }
                    .padding(24)
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "clock")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary.opacity(0.3))
                    Text("No events recorded")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                    Text("Events appear when sessions start, stop, or compact")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary.opacity(0.6))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

// ─── SwiftUI: All Sessions Tab ─────────────────────────────────────────────

struct AllSessionsTabView: View {
    @ObservedObject var dataSource: DashboardData
    let onResume: (String, String?) -> Void
    let onOpenFile: (String) -> Void

    @State private var searchText = ""
    @State private var sortOrder: AllSessionSort = .modified

    enum AllSessionSort {
        case modified, project, model, size

        func compare(_ a: FullSession, _ b: FullSession) -> Bool {
            switch self {
            case .modified: return a.modified > b.modified
            case .project:  return a.project < b.project
            case .model:    return a.model < b.model
            case .size:     return a.sizeKb > b.sizeKb
            }
        }
    }

    private var filteredSessions: [FullSession] {
        guard let all = dataSource.allSessions else { return [] }
        let sorted = all.sorted(by: sortOrder.compare)
        guard !searchText.isEmpty else { return sorted }
        let q = searchText.lowercased()
        return sorted.filter {
            $0.project.lowercased().contains(q) ||
            $0.sessionId.lowercased().contains(q) ||
            $0.model.lowercased().contains(q)
        }
    }

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, HH:mm"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(alignment: .firstTextBaseline) {
                Text("All Sessions")
                    .font(.system(size: 22, weight: .bold))
                Spacer()
                if let all = dataSource.allSessions {
                    Text("\(all.count) sessions")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 12)

            // Search + sort bar
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    TextField("Search projects, sessions, models...", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )

                Picker("Sort", selection: $sortOrder) {
                    Text("Recent").tag(AllSessionSort.modified)
                    Text("Project").tag(AllSessionSort.project)
                    Text("Model").tag(AllSessionSort.model)
                    Text("Size").tag(AllSessionSort.size)
                }
                .pickerStyle(.segmented)
                .frame(width: 280)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 12)

            Rectangle()
                .fill(Color.secondary.opacity(0.15))
                .frame(height: 1)
                .padding(.horizontal, 20)

            if dataSource.isLoadingAllSessions {
                VStack(spacing: 12) {
                    ProgressView()
                        .scaleEffect(1.2)
                    Text("Scanning all sessions...")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredSessions.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "tray")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary.opacity(0.3))
                    Text(searchText.isEmpty ? "No sessions found" : "No matching sessions")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(Array(filteredSessions.enumerated()), id: \.element.sessionId) { idx, sess in
                            SessionRow(session: sess, isEven: idx % 2 == 0,
                                       dateFmt: Self.dateFmt,
                                       onResume: onResume, onOpenFile: onOpenFile)
                        }
                    }
                }
            }
        }
    }
}

private struct SessionRow: View {
    let session: FullSession
    let isEven: Bool
    let dateFmt: DateFormatter
    let onResume: (String, String?) -> Void
    let onOpenFile: (String) -> Void

    @State private var isHovered = false

    var body: some View {
        let m = modelDisplay(session.model)
        let cwdPath = session.projectDirName
            .replacingOccurrences(of: "-", with: "/")
            .replacingOccurrences(of: "^/", with: "", options: .regularExpression)

        HStack(spacing: 0) {
            // Model badge
            HStack(spacing: 4) {
                Text(m.badge).foregroundColor(Color(nsColor: m.color))
                Text(m.label).foregroundColor(Color(nsColor: m.color))
            }
            .font(.system(size: 12, weight: .medium))
            .frame(width: 80, alignment: .leading)

            // Project name
            Text(session.project)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .frame(width: 180, alignment: .leading)

            // Turns + size
            Text("\(session.turns)t")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 50, alignment: .trailing)

            Text(fmtSize(session.sizeKb))
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 60, alignment: .trailing)

            // Date
            Text(dateFmt.string(from: session.modified))
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 100, alignment: .trailing)

            Spacer()

            // Action buttons — visible on hover
            if isHovered {
                HStack(spacing: 6) {
                    Button(action: { onOpenFile(session.jsonlPath) }) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.bordered)
                    .help("View transcript")

                    Button(action: {
                        let dir = "/" + cwdPath
                        onResume(session.sessionId, dir)
                    }) {
                        Image(systemName: "play.circle")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.bordered)
                    .help("Resume session")
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
        .background(isHovered ? Color.accentColor.opacity(0.06) :
                     (isEven ? Color.clear : Color.secondary.opacity(0.04)))
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) { isHovered = hovering }
        }
    }
}

// ─── SwiftUI: Settings tab — palette editor + live preview ─────────────────
//
// Renders a "Widget Menu" section containing:
//   1. A live preview of one live-instance menu row (LiveRowViewRepresentable
//      wrapping the same NSView the actual menu uses).
//   2. A table of palette tokens — name, usage, current swatch (clickable),
//      reset button.
// Click a swatch → popover with Tailwind picker (13 hues × 5 shades).
//
// Persistence is through PaletteStore (UserDefaults). The store posts a
// notification on change; the bar's BarDelegate observes it and refreshes
// the open menu. The preview re-renders by bumping a local @State counter
// observed by the NSViewRepresentable.

/// Tailwind v3 palette subset — 13 hues × 5 mid-range shades. Picked to
/// stay legible on the NSMenu's translucent material in both dark + light
/// mode. Source: https://tailwindcss.com/docs/colors
private let tailwindPalette: [(hue: String, shades: [(name: String, hex: String)])] = [
    ("red",    [("300","#FCA5A5"),("400","#F87171"),("500","#EF4444"),("600","#DC2626"),("700","#B91C1C")]),
    ("orange", [("300","#FDBA74"),("400","#FB923C"),("500","#F97316"),("600","#EA580C"),("700","#C2410C")]),
    ("amber",  [("300","#FCD34D"),("400","#FBBF24"),("500","#F59E0B"),("600","#D97706"),("700","#B45309")]),
    ("yellow", [("300","#FDE047"),("400","#FACC15"),("500","#EAB308"),("600","#CA8A04"),("700","#A16207")]),
    ("green",  [("300","#86EFAC"),("400","#4ADE80"),("500","#22C55E"),("600","#16A34A"),("700","#15803D")]),
    ("teal",   [("300","#5EEAD4"),("400","#2DD4BF"),("500","#14B8A6"),("600","#0D9488"),("700","#0F766E")]),
    ("cyan",   [("300","#67E8F9"),("400","#22D3EE"),("500","#06B6D4"),("600","#0891B2"),("700","#0E7490")]),
    ("blue",   [("300","#93C5FD"),("400","#60A5FA"),("500","#3B82F6"),("600","#2563EB"),("700","#1D4ED8")]),
    ("indigo", [("300","#A5B4FC"),("400","#818CF8"),("500","#6366F1"),("600","#4F46E5"),("700","#4338CA")]),
    ("purple", [("300","#D8B4FE"),("400","#C084FC"),("500","#A855F7"),("600","#9333EA"),("700","#7E22CE")]),
    ("pink",   [("300","#F9A8D4"),("400","#F472B6"),("500","#EC4899"),("600","#DB2777"),("700","#BE185D")]),
    ("rose",   [("300","#FDA4AF"),("400","#FB7185"),("500","#F43F5E"),("600","#E11D48"),("700","#BE123C")]),
    ("gray",   [("300","#D1D5DB"),("400","#9CA3AF"),("500","#6B7280"),("600","#4B5563"),("700","#374151")]),
]

/// Best-effort reverse lookup: given a hex, return "rose-400" if it matches
/// a Tailwind swatch exactly, otherwise nil. Used to show context in the
/// editor row ("Currently: rose-400") when the user picked a Tailwind color.
private func tailwindName(forHex hex: String) -> String? {
    let h = hex.uppercased()
    for (hue, shades) in tailwindPalette {
        for s in shades where s.hex.uppercased() == h {
            return "\(hue)-\(s.name)"
        }
    }
    return nil
}

/// A sample LiveInstance used for the Settings preview. Chosen to exercise
/// most rendering paths: branch + modified count, subagent badge, focus
/// file, MCP-down warning, low-ctx warning, all metric fields populated.
private func samplePreviewInstance() -> LiveInstance {
    let statusline = StatuslineMetrics(
        cpu: "12", mem: "1.2", rssMb: "342",
        focusFile: "/Users/alcatraz627/Code/example/src/components/Nav.tsx",
        mcpHealthy: "scratchpad,shell-mem",
        mcpDown: nil,
        tokSpeed: "420",
        costVel: nil,
        walSinceCp: nil,
        ctxRemaining: "62",
        scratchpadCount: nil,
        pm2Online: nil,
        pm2Errored: nil
    )
    let state = SessionState(state: "tool_use", detail: "Reading src/Nav.tsx")
    return LiveInstance(
        pid: 12345,
        model: "opus", modelFull: "claude-opus-4-7",
        cwd: "/Users/alcatraz627/Code/example",
        cwdShort: "~/Code/example",
        elapsed: "00:08:14",
        turns: 22,
        inputTokens: 12_000, outputTokens: 38_400, cacheRead: 1_800_000,
        sessionId: "abcd1234-…",
        resumeId: nil,
        toolCalls: 17, costUsd: 1.42,
        tabTitle: "Nav UI polish",
        subagentCount: 1,
        sessionState: state,
        statusline: statusline,
        gitBranch: "feature/nav-polish",
        gitModified: 8,
        lastPrompt: "Add hover state to the nav links and make sure focus ring is visible"
    )
}

/// Helper that observes UserDefaults so SwiftUI views re-render when any
/// palette token changes. Bumps a published Int counter on each change.
final class PaletteObservable: ObservableObject {
    @Published var version: Int = 0
    private var token: NSObjectProtocol?
    init() {
        token = NotificationCenter.default.addObserver(
            forName: PaletteStore.didChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.version &+= 1
        }
    }
    deinit { if let t = token { NotificationCenter.default.removeObserver(t) } }
}

struct SettingsTabView: View {
    @StateObject private var palette = PaletteObservable()
    @State private var hoveredToken: PaletteToken? = nil   // shared bidirectional hover state
    private let home = FileManager.default.homeDirectoryForCurrentUser.path

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Settings")
                    .font(.system(size: 24, weight: .bold))
                    .padding(.top, 20)
                    .padding(.horizontal, 24)

                AppearanceSection()
                    .padding(.horizontal, 24)

                OverviewSection(title: "Widget Menu",
                                icon: "menubar.dock.rectangle",
                                iconColor: .gray) {
                    VStack(alignment: .leading, spacing: 16) {
                        // Live preview (the exact NSView the menu uses, wrapped in SwiftUI).
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("PREVIEW")
                                    .font(.system(size: 10, weight: .bold))
                                    .tracking(0.8)
                                    .foregroundColor(.secondary)
                                Spacer()
                                if let h = hoveredToken {
                                    Text(h.rawValue)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(.accentColor)
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(
                                            RoundedRectangle(cornerRadius: 4)
                                                .fill(Color.accentColor.opacity(0.12))
                                        )
                                }
                            }
                            LiveRowViewRepresentable(
                                inst: samplePreviewInstance(),
                                home: home,
                                paletteVersion: palette.version,
                                highlightedToken: hoveredToken,
                                onHoverToken: { t in hoveredToken = t }
                            )
                            .frame(minWidth: 360, minHeight: 180, alignment: .topLeading)
                            .padding(8)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color(NSColor.windowBackgroundColor).opacity(0.6))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.secondary.opacity(0.18))
                            )
                            Text("Hover any line to highlight its color row · Hover a row to highlight the matching part · Click a swatch to pick a new color. Actual menu refreshes on next scan tick (≤5s).")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }

                        Divider()

                        // Header row
                        HStack(spacing: 8) {
                            Text("TOKEN").frame(width: 130, alignment: .leading)
                            Text("USED FOR").frame(maxWidth: .infinity, alignment: .leading)
                            Text("COLOR").frame(width: 110, alignment: .leading)
                            Text("").frame(width: 60, alignment: .trailing)
                        }
                        .font(.system(size: 10, weight: .bold))
                        .tracking(0.8)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 4)

                        ForEach(PaletteToken.allCases, id: \.self) { token in
                            PaletteEditorRow(token: token,
                                             paletteVersion: palette.version,
                                             hoveredToken: $hoveredToken)
                            Divider().opacity(0.4)
                        }

                        // Reset-all
                        HStack {
                            Spacer()
                            Button("Reset all to defaults") {
                                PaletteStore.shared.resetAll()
                            }
                            .controlSize(.small)
                        }
                        .padding(.top, 4)
                    }
                }
                .padding(.horizontal, 24)

                MenuBehaviorSection()
                    .padding(.horizontal, 24)

                Spacer(minLength: 24)
            }
        }
    }
}

struct PaletteEditorRow: View {
    let token: PaletteToken
    let paletteVersion: Int   // included in the view identity so changes re-render
    @Binding var hoveredToken: PaletteToken?

    @State private var showPicker = false

    private var currentHex: String { PaletteStore.shared.hex(for: token) }
    private var currentColor: Color { Color(PaletteStore.shared.color(for: token)) }
    private var defaultHex: String { PaletteStore.shared.defaultColor(for: token).hexString }
    private var isOverridden: Bool { PaletteStore.shared.isOverridden(token) }
    private var isHovered: Bool { hoveredToken == token }

    var body: some View {
        HStack(spacing: 8) {
            // Token name
            VStack(alignment: .leading, spacing: 1) {
                Text(token.displayName)
                    .font(.system(size: 13, weight: .medium))
                Text(token.rawValue)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            .frame(width: 130, alignment: .leading)

            // Usage description
            Text(token.usage)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Swatch button — opens Tailwind picker
            Button {
                showPicker.toggle()
            } label: {
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(currentColor)
                        .frame(width: 22, height: 22)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color.secondary.opacity(0.3))
                        )
                    VStack(alignment: .leading, spacing: 0) {
                        Text(currentHex)
                            .font(.system(size: 11, design: .monospaced))
                        if let tw = tailwindName(forHex: currentHex) {
                            Text(tw)
                                .font(.system(size: 9))
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .buttonStyle(.plain)
            .frame(width: 110, alignment: .leading)
            .popover(isPresented: $showPicker, arrowEdge: .leading) {
                TailwindPicker(currentHex: currentHex) { hex in
                    PaletteStore.shared.set(token, hex: hex)
                    showPicker = false
                }
            }

            // Reset button
            Button("Reset") {
                PaletteStore.shared.reset(token)
            }
            .controlSize(.small)
            .disabled(!isOverridden)
            .frame(width: 60, alignment: .trailing)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 4)
        .background(
            // Light offshade for the bg when this row matches the hovered
            // preview token. Color.accentColor adapts to user accent +
            // dark/light mode automatically.
            RoundedRectangle(cornerRadius: 4)
                .fill(isHovered ? Color.accentColor.opacity(0.12) : Color.clear)
        )
        .onHover { inside in
            // Forward: hovering this row sets the hovered token, which
            // flows into the preview via the @State binding and triggers
            // LiveRowView.setHighlightedToken(...) on the matching label.
            hoveredToken = inside ? token : (hoveredToken == token ? nil : hoveredToken)
        }
    }
}

/// Appearance preference: System / Light / Dark. Applied by setting
/// `NSApp.appearance` and re-rendering the dashboard. Persists across launches.
enum AppearancePref: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .system: return "System"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light:  return NSAppearance(named: .aqua)
        case .dark:   return NSAppearance(named: .darkAqua)
        }
    }
}

private let appearancePrefKey = "appearance.mode"
func loadAppearancePref() -> AppearancePref {
    if let raw = UserDefaults.standard.string(forKey: appearancePrefKey),
       let p = AppearancePref(rawValue: raw) { return p }
    return .system
}
func applyAppearancePref(_ pref: AppearancePref) {
    NSApp.appearance = pref.nsAppearance
}

struct AppearanceSection: View {
    @State private var pref: AppearancePref = loadAppearancePref()

    var body: some View {
        OverviewSection(title: "Appearance",
                        icon: "paintbrush.fill",
                        iconColor: .indigo) {
            HStack(spacing: 12) {
                Text("Theme")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 130, alignment: .leading)
                Picker("", selection: $pref) {
                    ForEach(AppearancePref.allCases) { p in
                        Text(p.displayName).tag(p)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 280)
                Text("Affects the dashboard window. The menu's translucent material adapts to the OS regardless.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                Spacer()
            }
            .padding(.vertical, 4)
            .onChange(of: pref) { _, newPref in
                UserDefaults.standard.set(newPref.rawValue, forKey: appearancePrefKey)
                applyAppearancePref(newPref)
            }
        }
    }
}

/// Section for misc. menu-side behavior toggles. Each control persists via
/// UserDefaults and is read by the bar at the relevant call site. Adding
/// more here is mechanical: define a key, expose a Toggle/Picker, and have
/// the bar read it.
struct MenuBehaviorSection: View {
    @AppStorage("density") private var density: String = "comfortable"
    @AppStorage("defaultTab") private var defaultTab: String = DashboardTab.overview.rawValue
    @AppStorage("time.use24h") private var use24h: Bool = false

    var body: some View {
        OverviewSection(title: "Menu Behavior",
                        icon: "slider.horizontal.below.rectangle",
                        iconColor: .teal) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Text("Density")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 130, alignment: .leading)
                    Picker("", selection: $density) {
                        Text("Compact").tag("compact")
                        Text("Cozy").tag("cozy")
                        Text("Comfortable").tag("comfortable")
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 280)
                    Spacer()
                }

                HStack(spacing: 12) {
                    Text("Default tab")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 130, alignment: .leading)
                    Picker("", selection: $defaultTab) {
                        ForEach(DashboardTab.allCases) { tab in
                            Text(tab.rawValue).tag(tab.rawValue)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 220)
                    Text("Which tab opens when the dashboard launches.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Spacer()
                }

                HStack(spacing: 12) {
                    Text("Time format")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 130, alignment: .leading)
                    Toggle("Use 24-hour clock", isOn: $use24h)
                        .toggleStyle(.checkbox)
                    Spacer()
                }
            }
            .padding(.vertical, 4)
        }
    }
}

struct TailwindPicker: View {
    let currentHex: String
    let onPick: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Tailwind colors")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)

            ForEach(tailwindPalette, id: \.hue) { row in
                HStack(spacing: 6) {
                    Text(row.hue)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                        .frame(width: 50, alignment: .trailing)
                    ForEach(row.shades, id: \.hex) { shade in
                        Button {
                            onPick(shade.hex)
                        } label: {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color(NSColor.fromHex(shade.hex) ?? .gray))
                                .frame(width: 28, height: 24)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4)
                                        .stroke(currentHex.uppercased() == shade.hex.uppercased()
                                                ? Color.accentColor : Color.secondary.opacity(0.25),
                                                lineWidth: currentHex.uppercased() == shade.hex.uppercased() ? 2 : 1)
                                )
                        }
                        .buttonStyle(.plain)
                        .help("\(row.hue)-\(shade.name) · \(shade.hex)")
                    }
                }
            }
        }
        .padding(14)
    }
}

// ─── SwiftUI: About Tab ────────────────────────────────────────────────────

struct AboutTabView: View {
    private let buildInfo: [String: String] = {
        let path = widgetDir + "/native/.build-info"
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return [:] }
        var info: [String: String] = [:]
        for line in content.components(separatedBy: .newlines) {
            let parts = line.trimmingCharacters(in: .whitespaces).components(separatedBy: "=")
            if parts.count == 2 { info[parts[0]] = parts[1] }
        }
        return info
    }()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Title
                HStack(alignment: .firstTextBaseline) {
                    Text("About")
                        .font(.system(size: 22, weight: .bold))
                    Spacer()
                }

                // App identity
                OverviewSection(title: "Claude Instances", icon: "cpu", iconColor: .accentColor) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Native macOS menu bar widget for monitoring and managing concurrent Claude Code sessions.")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                        HStack(spacing: 16) {
                            InfoPill(label: "Platform", value: "macOS 13+")
                            InfoPill(label: "Language", value: "Swift 5.9")
                            InfoPill(label: "Build", value: "swiftc (no Xcode)")
                        }
                    }
                }

                // Build info
                OverviewSection(title: "Build Info", icon: "hammer.fill", iconColor: .orange) {
                    VStack(alignment: .leading, spacing: 4) {
                        AboutRow(label: "Commit", value: buildInfo["commit"] ?? "–")
                        AboutRow(label: "Source Hash", value: buildInfo["src_hash"] ?? "–")
                        AboutRow(label: "Built At", value: buildInfo["built_at"] ?? "–")
                        AboutRow(label: "Widget Dir", value: widgetDir.replacingOccurrences(of: home, with: "~"))
                    }
                }

                // Keyboard shortcuts
                OverviewSection(title: "Keyboard Shortcuts", icon: "keyboard", iconColor: .blue) {
                    VStack(alignment: .leading, spacing: 4) {
                        ShortcutRow(keys: "⌘N", desc: "New Claude session in Ghostty")
                        ShortcutRow(keys: "⌘D", desc: "Open/focus Dashboard")
                        ShortcutRow(keys: "⌘R", desc: "Force refresh scan data")
                    }
                }

                // Data sources
                OverviewSection(title: "Data Sources", icon: "cylinder.split.1x2", iconColor: .purple) {
                    VStack(alignment: .leading, spacing: 4) {
                        AboutRow(label: "Scanner", value: "lib/scan.sh (Python → JSON)")
                        AboutRow(label: "Statusline", value: "/tmp/claude-statusline-<pid>")
                        AboutRow(label: "Sessions", value: "~/.claude/projects/")
                        AboutRow(label: "Rate Limits", value: "~/.claude/widgets/.limits.json")
                        AboutRow(label: "Refresh", value: "5s quick / 30s full")
                    }
                }

                // Dashboard tabs guide
                OverviewSection(title: "Dashboard Tabs", icon: "sidebar.squares.left", iconColor: .indigo) {
                    VStack(alignment: .leading, spacing: 6) {
                        TabHelp(icon: "square.grid.2x2.fill", color: .blue, name: "Overview",
                                desc: "Stat cards, rate limits, active totals, recent events")
                        TabHelp(icon: "sparkles", color: .green, name: "Live",
                                desc: "Running instances with metrics, hover actions, transcript viewer")
                        TabHelp(icon: "clock.arrow.circlepath", color: .purple, name: "History",
                                desc: "Recent sessions — search, sort, resume, tokens, cost")
                        TabHelp(icon: "list.bullet", color: .orange, name: "Events",
                                desc: "Timeline of start/stop/compact/permission events")
                        TabHelp(icon: "tray.full.fill", color: .indigo, name: "All Sessions",
                                desc: "Deep scan of ALL past sessions with search and resume")
                    }
                }

                // Links
                OverviewSection(title: "Links", icon: "link", iconColor: .cyan) {
                    VStack(alignment: .leading, spacing: 4) {
                        Button(action: {
                            NSWorkspace.shared.open(URL(string: "https://github.com/alcatraz627/claude-instances")!)
                        }) {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.up.right.square")
                                    .font(.system(size: 11))
                                Text("GitHub Repository")
                                    .font(.system(size: 13))
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.accentColor)

                        AboutRow(label: "Logs", value: "/tmp/claude-instances-bar.log")
                        AboutRow(label: "LaunchAgent", value: "dev.claude-instances.menubar")
                    }
                }

                // Troubleshooting
                OverviewSection(title: "Troubleshooting", icon: "wrench.and.screwdriver", iconColor: .yellow) {
                    VStack(alignment: .leading, spacing: 6) {
                        TroubleshootRow(problem: "Two icons in menu bar",
                                       fix: "Hover stale icon to clear, or reinstall")
                        TroubleshootRow(problem: "Focus doesn't switch tabs",
                                       fix: "Grant Accessibility permission in System Settings")
                        TroubleshootRow(problem: "Menu shows 'Scanning...'",
                                       fix: "Test scan.sh directly: bash lib/scan.sh")
                    }
                }
            }
            .padding(20)
        }
    }
}

private struct InfoPill: View {
    let label: String
    let value: String
    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(.primary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.08)))
    }
}

private struct AboutRow: View {
    let label: String
    let value: String
    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)
                .frame(width: 100, alignment: .leading)
            Text(value)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.primary)
                .lineLimit(1)
            Spacer()
        }
    }
}

private struct ShortcutRow: View {
    let keys: String
    let desc: String
    var body: some View {
        HStack {
            Text(keys)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundColor(.accentColor)
                .frame(width: 40, alignment: .leading)
            Text(desc)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Spacer()
        }
    }
}

private struct TabHelp: View {
    let icon: String
    let color: Color
    let name: String
    let desc: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundColor(color)
                .frame(width: 16)
            Text(name)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 80, alignment: .leading)
            Text(desc)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .lineLimit(1)
            Spacer()
        }
    }
}

private struct TroubleshootRow: View {
    let problem: String
    let fix: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(problem)
                .font(.system(size: 12, weight: .medium))
            Text(fix)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
    }
}

// ─── SwiftUI Helpers ────────────────────────────────────────────────────────

private func eventColor(_ event: String) -> Color {
    switch event {
    case "SessionStart":      return .green
    case "Stop":              return .red
    case "PermissionRequest": return .orange
    case "PostCompact":       return .blue
    case "PreCompact":        return .blue
    case "SubagentStart":     return .purple
    case "SubagentStop":      return .purple
    case "Notification":      return .yellow
    case "PostToolUse":       return .teal
    default:                  return .secondary
    }
}

private func eventLabel(_ event: String) -> String {
    switch event {
    case "SessionStart":      return "Started"
    case "Stop":              return "Stopped"
    case "PermissionRequest": return "Permission"
    case "PostCompact":       return "Compacted"
    case "PreCompact":        return "Compacting"
    case "SubagentStart":     return "Agent ▶"
    case "SubagentStop":      return "Agent ■"
    case "Notification":      return "Notified"
    case "PostToolUse":       return "Tool"
    default:                  return event
    }
}

private func eventTime(_ ts: String) -> String {
    if ts.contains("T"), let time = ts.split(separator: "T").last {
        return String(time.prefix(5))
    }
    return ts
}

// ─── Entry point ──────────────────────────────────────────────────────────────

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // No Dock icon
let delegate = BarDelegate()
app.delegate = delegate
app.run()
