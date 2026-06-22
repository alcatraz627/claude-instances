// main.swift
// App entry point + paths, logging, and formatting helpers.
// (split from claude-instances-bar.swift — one module, same binary)

import AppKit
import Foundation
import SwiftUI

// ─── Paths ────────────────────────────────────────────────────────────────────

let home         = FileManager.default.homeDirectoryForCurrentUser.path
let widgetDir    = home + "/.claude/widgets/claude-instances"
let scanScript   = widgetDir + "/lib/scan.sh"
let detailScript = widgetDir + "/lib/detail.sh"
let hubScript    = widgetDir + "/lib/hub.sh"
let hubServer    = widgetDir + "/lib/hub-server.py"
let hubPort       = 5400
let logDir       = home + "/Library/Logs/ClaudeInstances"
let debugLog     = logDir + "/bar.log"
let debugLogPrev = logDir + "/bar.log.1"
let iconPath     = home + "/.claude/widgets/claude-instances/native/claude-logo.svg"

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

enum LogLevel: String { case info = "INFO", warn = "WARN", error = "ERROR" }

let logRotateBytes: UInt64 = 1_000_000
let pidStr = String(ProcessInfo.processInfo.processIdentifier)

func ensureLogDir() {
    try? FileManager.default.createDirectory(
        atPath: logDir, withIntermediateDirectories: true)
}

func rotateLogIfNeeded() {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: debugLog),
          let size = attrs[.size] as? UInt64, size > logRotateBytes else { return }
    try? FileManager.default.removeItem(atPath: debugLogPrev)
    try? FileManager.default.moveItem(atPath: debugLog, toPath: debugLogPrev)
}

func writeLog(_ level: LogLevel, _ msg: String) {
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

func dlog (_ msg: String) { writeLog(.info,  msg) }
func dwarn(_ msg: String) { writeLog(.warn,  msg) }
func derr (_ msg: String) { writeLog(.error, msg) }

/// Pretty-print an NSError so multi-line dumps fit on one log line.
func fmtErr(_ error: Error) -> String {
    let ns = error as NSError
    return "\(ns.domain) #\(ns.code): \(ns.localizedDescription)"
}

/// Pretty-print the NSDictionary returned by `NSAppleScript.executeAndReturnError`.
/// Strips noisy keys (NSAppleScriptErrorRange) and surfaces brief message + code + app.
func fmtASErr(_ info: NSDictionary) -> String {
    let brief = info["NSAppleScriptErrorBriefMessage"] as? String
             ?? info["NSAppleScriptErrorMessage"] as? String
             ?? "unknown error"
    let num   = (info["NSAppleScriptErrorNumber"] as? NSNumber)?.intValue ?? -1
    let app   = info["NSAppleScriptErrorAppName"] as? String ?? "?"
    return "AppleScript[\(app) #\(num)]: \(brief)"
}

// ─── Formatting helpers ──────────────────────────────────────────────────────

func fmtTokens(_ n: Int) -> String {
    switch n {
    case 1_000_000...: return String(format: "%.1fM", Double(n) / 1_000_000)
    case 1_000...:     return String(format: "%.0fK", Double(n) / 1_000)
    default:           return "\(n)"
    }
}

func fmtSize(_ kb: Double) -> String {
    return kb > 1024 ? String(format: "%.1fM", kb / 1024) : "\(Int(kb))K"
}

// Cached ISO8601 formatters. Allocating a new one each call was a real
// perf hit: relativeTime() runs once per history row and once per
// All-Sessions row on every dashboard render (5s tick). 50+ rows × 2
// formatters per call × ~1-3ms per allocation was tens of milliseconds
// of main-thread work per refresh — visible as dashboard "hitch."
// DateFormatter is thread-safe for parsing on macOS 10.10+, so a single
// shared instance is fine.
let iso8601WithFractionalFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()
let iso8601BasicFormatter: ISO8601DateFormatter = {
    return ISO8601DateFormatter()
}()

func relativeTime(_ isoString: String?) -> String {
    guard let s = isoString else { return "?" }
    var date = iso8601WithFractionalFormatter.date(from: s)
    if date == nil { date = iso8601BasicFormatter.date(from: s) }
    if date == nil {
        // Last-chance: replace `Z` with `+00:00` for sources that emit
        // fractional seconds without the timezone designator.
        let cleaned = s.replacingOccurrences(of: "Z", with: "+00:00")
        date = iso8601WithFractionalFormatter.date(from: cleaned)
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

func fmtCost(_ usd: Double) -> String {
    if usd >= 1.0 { return String(format: "$%.2f", usd) }
    if usd >= 0.01 { return String(format: "%.0f¢", usd * 100) }
    if usd > 0 { return String(format: "%.1f¢", usd * 100) }
    return "–"
}

func shortenPath(_ path: String?, maxLen: Int = 32) -> String {
    guard let p = path, !p.isEmpty else { return "?" }
    if p.count <= maxLen { return p }
    return "…" + p.suffix(maxLen - 1)
}

func rateLimitCountdown(_ resetsAt: String?) -> String? {
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


// ─── Entry point ──────────────────────────────────────────────────────────────

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // No Dock icon
let delegate = BarDelegate()
app.delegate = delegate
app.run()
