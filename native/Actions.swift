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

/// Open a URL preferring Chrome, falling
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

// ─── Scanner ─────────────────────────────────────────────────────────────────

func runScanner(quick: Bool = false) -> ScanResult? {
    do {
        let (outData, errData, status) = try runCollecting(
            "/bin/bash", quick ? [scanScript, "--quick"] : [scanScript],
            environment: ProcessInfo.processInfo.environment)
        let stderr  = String(data: errData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if status != 0 {
            let mode = quick ? "--quick" : "full"
            derr("scanner \(mode) exit=\(status)" +
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

