// Actions.swift
// Side-effecting actions: Ghostty/resume, file open, hub bridge, scanner.
// (split from claude-instances-bar.swift — one module, same binary)

import AppKit
import Foundation
import SwiftUI

func focusGhosttyTab(forCwd cwd: String) {
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

func activateGhostty() {
    let script = NSAppleScript(source: "tell application \"Ghostty\" to activate")
    script?.executeAndReturnError(nil)
}

/// Launch `claude --resume <sessionId>` in a new Ghostty tab
func resumeSession(sessionId: String, cwd: String? = nil) {
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
func openFile(_ path: String) {
    NSWorkspace.shared.open(URL(fileURLWithPath: path))
}

// ─── Session hub bridge ──────────────────────────────────────────────────────
// The hub is one long-lived server that serves every session's transcript and a
// device-spanning index, reachable from the phone over Tailscale. These helpers
// let the menu open a session through it (starting it on first use).

/// Ensure the hub is running (idempotent) and return the address it bound to:
/// the tailnet IP when Tailscale is up, otherwise 127.0.0.1.
@discardableResult
func ensureHubRunning() -> String {
    let start = Process()
    start.executableURL = URL(fileURLWithPath: "/bin/bash")
    start.arguments = [hubScript, "start"]
    start.standardOutput = FileHandle.nullDevice
    start.standardError = FileHandle.nullDevice
    try? start.run()
    start.waitUntilExit()

    let probe = Process()
    probe.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    probe.arguments = ["python3", hubServer, "--print-host", "--port", "\(hubPort)"]
    let pipe = Pipe()
    probe.standardOutput = pipe
    probe.standardError = FileHandle.nullDevice
    try? probe.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    probe.waitUntilExit()
    let host = String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return host.isEmpty ? "127.0.0.1" : host
}

/// Open a URL preferring Chrome (matching the old detail.sh behaviour), falling
/// back to the default browser when Chrome isn't installed.
func openURLPreferChrome(_ url: String) {
    let chrome = Process()
    chrome.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    chrome.arguments = ["-a", "Google Chrome", url]
    chrome.standardError = FileHandle.nullDevice
    do {
        try chrome.run()
        chrome.waitUntilExit()
        if chrome.terminationStatus == 0 { return }
    } catch { }
    let fallback = Process()
    fallback.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    fallback.arguments = [url]
    try? fallback.run()
}

/// Ensure the hub is up, then open a live session's transcript through it.
func openHubTranscript(sessionId: String) {
    DispatchQueue.global(qos: .userInitiated).async {
        _ = ensureHubRunning()
        openURLPreferChrome("http://127.0.0.1:\(hubPort)/s/\(sessionId)")
    }
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

func scanAllSessions() -> [FullSession] {
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

func runScanner(quick: Bool = false) -> ScanResult? {
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

