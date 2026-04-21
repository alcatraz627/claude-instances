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
private let debugLog     = "/tmp/claude-instances-bar.log"
private let iconPath     = home + "/.claude/assets/images/claude-icon-coral-32.png"

// ─── Debug logging ────────────────────────────────────────────────────────────

private func dlog(_ msg: String) {
    let ts   = ISO8601DateFormatter().string(from: Date())
    let line = "  \(ts) [bar] \(msg)\n"
    guard let data = line.data(using: .utf8) else { return }
    if let fh = FileHandle(forWritingAtPath: debugLog) {
        fh.seekToEndOfFile(); fh.write(data); fh.closeFile()
    } else {
        try? data.write(to: URL(fileURLWithPath: debugLog))
    }
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
    let limits: RateLimits?
    let liveCount: Int

    enum CodingKeys: String, CodingKey {
        case live, history, limits
        case recentEvents = "recent_events"
        case liveCount = "live_count"
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
    let statusline: StatuslineMetrics?

    enum CodingKeys: String, CodingKey {
        case pid, model, cwd, elapsed, turns, statusline
        case modelFull = "model_full"
        case cwdShort = "cwd_short"
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheRead = "cache_read"
        case sessionId = "session_id"
        case resumeId = "resume_id"
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

    enum CodingKeys: String, CodingKey {
        case cpu, mem
        case rssMb = "rss_mb"
        case focusFile = "focus_file"
        case mcpHealthy = "mcp_healthy"
        case mcpDown = "mcp_down"
        case tokSpeed = "tok_speed"
        case costVel = "cost_vel"
        case walSinceCp = "wal_since_cp"
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

    enum CodingKeys: String, CodingKey {
        case event, ts, project
        case sessionId = "session_id"
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

    enum CodingKeys: String, CodingKey {
        case fiveH = "5h"
        case week
    }
}

// ─── Model display config ────────────────────────────────────────────────────

private struct ModelDisplay {
    let badge: String
    let label: String
    let color: NSColor
}

private let modelConfig: [String: ModelDisplay] = [
    "opus":   ModelDisplay(badge: "◆", label: "Opus",
                           color: NSColor(red: 0.95, green: 0.65, blue: 0.20, alpha: 1.0)),  // warm amber/gold
    "sonnet": ModelDisplay(badge: "●", label: "Sonnet",
                           color: NSColor(red: 0.38, green: 0.58, blue: 1.0, alpha: 1.0)),   // vibrant blue
    "haiku":  ModelDisplay(badge: "○", label: "Haiku",
                           color: NSColor(red: 0.30, green: 0.82, blue: 0.72, alpha: 1.0)),  // teal/mint
]

private let defaultModel = ModelDisplay(badge: "·", label: "?", color: .secondaryLabelColor)

private func modelDisplay(_ name: String?) -> ModelDisplay {
    guard let n = name else { return defaultModel }
    return modelConfig[n] ?? defaultModel
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
        dlog("AppleScript focus error: \(error)")
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
        dlog("resume AppleScript error: \(error)")
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

private func runScanner() -> ScanResult? {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/bash")
    task.arguments = [scanScript]
    task.environment = ProcessInfo.processInfo.environment

    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = FileHandle.nullDevice

    do {
        try task.run()
        task.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if task.terminationStatus != 0 {
            dlog("scanner exited with status \(task.terminationStatus)")
            return nil
        }
        let decoder = JSONDecoder()
        return try decoder.decode(ScanResult.self, from: data)
    } catch {
        dlog("scanner error: \(error)")
        return nil
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

    // ── App lifecycle ────────────────────────────────────────────────────────

    func applicationDidFinishLaunching(_ note: Notification) {
        let myPID = ProcessInfo.processInfo.processIdentifier
        dlog("launched PID=\(myPID)")

        // Kill any other instances of ourselves (dedupe on launch)
        killOtherInstances(myPID: myPID)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        theMenu                  = NSMenu()
        theMenu.autoenablesItems = false
        theMenu.delegate         = self
        statusItem.menu          = theMenu

        // Initial scan
        refreshData()

        // Background timer — scan every 5 seconds
        scanTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.refreshData()
        }
        RunLoop.current.add(scanTimer!, forMode: .common)

        dlog("ready — timer started (5s interval)")
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
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = runScanner()
            DispatchQueue.main.async {
                if let r = result {
                    self?.cachedData = r
                    self?.lastScanError = false
                } else {
                    self?.lastScanError = true
                }
                self?.updateButton()
                // Push fresh data to dashboard if open
                self?.dashboardController?.updateData(self?.cachedData)
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

        // Text color: coral normally, red/orange on rate limit
        var textColor = NSColor(red: 0.85, green: 0.47, blue: 0.34, alpha: 1.0) // coral
        if liveCount == 0 { textColor = .tertiaryLabelColor }
        if let limits = cachedData?.limits {
            let maxPct = max(limits.fiveH?.pct ?? 0, limits.week?.pct ?? 0)
            if maxPct > 90 { textColor = .systemRed }
            else if maxPct > 75 { textColor = .systemOrange }
        }

        btn.attributedTitle = NSAttributedString(string: " \(countText)", attributes: [
            .foregroundColor: textColor,
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
        ])
    }

    // ── NSMenuDelegate ───────────────────────────────────────────────────────

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        populateMenuItems(menu)
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

        // ── Live instances ───────────────────────────────────────────────────
        addLiveInstancesSection(menu, data)

        // ── Rate limits ──────────────────────────────────────────────────────
        addRateLimitsSection(menu, data)

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
        let entries: [(String, RateLimitEntry?)] = [("5h", limits.fiveH), ("7d", limits.week)]
        var hasAny = false
        for (label, entry) in entries {
            guard let e = entry else { continue }
            hasAny = true

            // Gradient bar: green → orange → red based on fill
            let barLen = 16
            let filled = Int(round(e.pct / 100.0 * Double(barLen)))
            let bar = String(repeating: "▓", count: filled) + String(repeating: "░", count: barLen - filled)

            let pctStr = String(format: "%3d%%", Int(e.pct))
            let text = "  \(label)  \(bar)  \(pctStr)  \(fmtTokens(e.used))/\(fmtTokens(e.cap))"

            var color: NSColor = .secondaryLabelColor
            if e.pct > 90      { color = .systemRed }
            else if e.pct > 75 { color = .systemOrange }
            else if e.pct > 50 { color = .systemYellow }

            let item = NSMenuItem()
            item.attributedTitle = NSAttributedString(string: text, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: color,
            ])
            item.isEnabled = false
            menu.addItem(item)
        }
        if hasAny { menu.addItem(.separator()) }
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

        // Section header with aggregate stats
        let totalRss = live.compactMap { Int($0.statusline?.rssMb ?? "0") }.reduce(0, +)
        let totalOut = live.compactMap { $0.outputTokens }.reduce(0, +)
        let headerParts = ["\(live.count) live"]
            + (totalRss > 0 ? ["\(totalRss) MB"] : [])
            + (totalOut > 0 ? ["↑\(fmtTokens(totalOut))"] : [])
        addSectionHeader(menu, headerParts.joined(separator: "  ·  "), icon: "sparkles")

        for (idx, inst) in live.enumerated() {
            let m = modelDisplay(inst.model)
            let cwd = shortenPath(inst.cwdShort, maxLen: 28)
            let elapsed = inst.elapsed?.trimmingCharacters(in: .whitespaces) ?? "?"

            // Row 1: Model badge + project path — CLICKABLE
            let row1 = NSMenuItem()
            let row1Attr = NSMutableAttributedString()
            row1Attr.append(NSAttributedString(string: "  \(m.badge) \(m.label)", attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .bold),
                .foregroundColor: m.color,
            ]))
            row1Attr.append(NSAttributedString(string: "  \(cwd)", attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                .foregroundColor: NSColor.labelColor,
            ]))
            row1Attr.append(NSAttributedString(string: "  \(elapsed)", attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: NSColor(red: 0.85, green: 0.47, blue: 0.34, alpha: 1.0),
            ]))
            row1.attributedTitle = row1Attr
            row1.representedObject = inst.cwd
            row1.action = #selector(focusInstance(_:))
            row1.target = self
            row1.isEnabled = true
            menu.addItem(row1)

            // Row 2: Compact metrics line
            var parts: [String] = []
            parts.append("PID \(inst.pid)")
            if let cpu = inst.statusline?.cpu, !cpu.isEmpty, cpu != "0" { parts.append("CPU \(cpu)%") }
            if let rss = inst.statusline?.rssMb, rss != "0", !rss.isEmpty { parts.append("\(rss) MB") }
            if let t = inst.turns, t > 0 { parts.append("\(t)t") }
            if let o = inst.outputTokens, o > 0 { parts.append("↑\(fmtTokens(o))") }
            if let ts = inst.statusline?.tokSpeed, !ts.isEmpty, ts != "0" { parts.append("\(ts) tok/s") }
            if let cv = inst.statusline?.costVel, !cv.isEmpty, cv != "0" { parts.append("$\(cv)/m") }

            addDimMono(menu, "   " + parts.joined(separator: " · "), size: 11)

            // Row 3: Focus file
            if let focusFile = inst.statusline?.focusFile, !focusFile.isEmpty {
                var display = focusFile
                if let cwdFull = inst.cwd, !cwdFull.isEmpty {
                    display = display.replacingOccurrences(of: cwdFull, with: ".")
                }
                display = display.replacingOccurrences(of: home, with: "~")
                addDimMono(menu, "   📄 \(shortenPath(display, maxLen: 38))", size: 11)
            }

            // MCP down warning
            if let mcpDown = inst.statusline?.mcpDown, !mcpDown.isEmpty {
                addColored(menu, "    ⚠ MCP down: \(mcpDown)", color: .systemRed, size: 11)
            }

            // Submenu: instance actions
            let submenu = NSMenu()

            let focusItem = NSMenuItem(title: "Focus Terminal", action: #selector(focusInstance(_:)), keyEquivalent: "")
            focusItem.target = self
            focusItem.representedObject = inst.cwd
            setIcon(focusItem, "terminal")
            submenu.addItem(focusItem)

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

            row1.submenu = submenu

            if idx < live.count - 1 {
                // Thin separator between instances
                menu.addItem(.separator())
            }
        }
        menu.addItem(.separator())
    }

    // ── Section: Events ──────────────────────────────────────────────────────

    private func addEventsSection(_ menu: NSMenu, _ data: ScanResult) {
        guard let events = data.recentEvents, !events.isEmpty else { return }

        let eventIcons: [String: String] = [
            "SessionStart": "▶",
            "Stop": "■",
            "PermissionRequest": "⚠",
            "PostCompact": "⟳",
        ]
        let eventColors: [String: NSColor] = [
            "SessionStart": .systemGreen,
            "Stop": .systemRed,
            "PermissionRequest": .systemOrange,
            "PostCompact": .systemBlue,
        ]

        addSectionHeader(menu, "Recent Events", icon: "list.bullet")

        for evt in events.suffix(5).reversed() {
            let icon = eventIcons[evt.event] ?? "·"
            let color = eventColors[evt.event] ?? .secondaryLabelColor
            var ts = evt.ts
            if ts.contains("T") {
                ts = String(ts.split(separator: "T").last?.prefix(5) ?? "?")
            }
            var project = evt.project ?? ""
            if project.count > 22 { project = "…" + project.suffix(21) }

            let item = NSMenuItem()
            let attr = NSMutableAttributedString()
            attr.append(NSAttributedString(string: "  \(icon) ", attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: color,
            ]))
            attr.append(NSAttributedString(string: "\(ts)  ", attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: NSColor.tertiaryLabelColor,
            ]))
            attr.append(NSAttributedString(string: project, attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]))
            item.attributedTitle = attr
            item.isEnabled = false
            menu.addItem(item)
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
            attr.append(NSAttributedString(string: "  \(String(sess.turns).leftPad(4))t  \(sz.leftPad(5))  \(rel.leftPad(4))", attributes: [
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
        addAction(menu, "Refresh", #selector(refreshAction), icon: "arrow.clockwise", key: "r")

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
        dlog("manual refresh")
        refreshData()
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
    case about       = "About"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .overview:    return "square.grid.2x2.fill"
        case .live:        return "sparkles"
        case .history:     return "clock.arrow.circlepath"
        case .events:      return "list.bullet"
        case .allSessions: return "tray.full.fill"
        case .about:       return "info.circle"
        }
    }

    var section: String {
        switch self {
        case .overview, .live:          return "Dashboard"
        case .history, .events:         return "Details"
        case .allSessions:              return "Details"
        case .about:                    return "Help"
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

                                        Text(evt.project ?? "")
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
                Text("(\(fmtTokens(entry.used))/\(fmtTokens(entry.cap)))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
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

    var body: some View {
        let m = modelDisplay(inst.model)

        VStack(alignment: .leading, spacing: 12) {
            // Header row: model pill + path + elapsed
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

                Text(inst.cwdShort ?? inst.cwd ?? "?")
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)

                Spacer()

                Text(inst.elapsed?.trimmingCharacters(in: .whitespaces) ?? "?")
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundColor(.orange)
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

                if let o = inst.outputTokens, o > 0 {
                    MetadataItem(icon: "arrow.up", text: fmtTokens(o) + " tok")
                }

                Spacer()
            }

            // Secondary metrics row: token speed, cost velocity, WAL distance
            let hasSecondary = (inst.statusline?.tokSpeed != nil && inst.statusline?.tokSpeed != "0") ||
                               (inst.statusline?.costVel != nil && inst.statusline?.costVel != "0") ||
                               (inst.statusline?.walSinceCp != nil && inst.statusline?.walSinceCp != "0")
            if hasSecondary {
                HStack(spacing: 0) {
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
                .padding(.top, -4)
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Events")
                        .font(.system(size: 22, weight: .bold))
                    Spacer()
                    if let events = data?.recentEvents {
                        Text("\(events.count) events")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                }

                if let events = data?.recentEvents, !events.isEmpty {
                    let reversed = Array(events.reversed())

                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(reversed.enumerated()), id: \.offset) { idx, evt in
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
                                        .fill(idx == reversed.count - 1 ? Color.clear : Color.secondary.opacity(0.2))
                                        .frame(width: 1)
                                        .frame(maxHeight: .infinity)
                                }
                                .frame(width: 10)

                                // Event content
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 8) {
                                        EventBadge(event: evt.event)

                                        Text(eventTime(evt.ts))
                                            .font(.system(size: 12, design: .monospaced))
                                            .foregroundColor(.secondary)
                                    }

                                    if let proj = evt.project, !proj.isEmpty {
                                        Text(proj)
                                            .font(.system(size: 13))
                                            .foregroundColor(.primary.opacity(0.8))
                                            .lineLimit(1)
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
                            .frame(minHeight: 52)
                        }
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
                    .frame(maxWidth: .infinity, minHeight: 240)
                }
            }
            .padding(24)
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
                        AboutRow(label: "Refresh", value: "Every 5 seconds")
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
    case "SessionStart":     return .green
    case "Stop":             return .red
    case "PermissionRequest": return .orange
    case "PostCompact":      return .blue
    default:                 return .secondary
    }
}

private func eventLabel(_ event: String) -> String {
    switch event {
    case "SessionStart":     return "Started"
    case "Stop":             return "Stopped"
    case "PermissionRequest": return "Permission"
    case "PostCompact":      return "Compacted"
    default:                 return event
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
