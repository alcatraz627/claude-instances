// Switchboard.swift
// The state behind the menu's Switchboard: what is muted, what is running, what
// each turn costs. Deliberately free of menu code so a headless probe can drive
// every read and every mutation without a GUI.
//
// One rule shapes the whole file: a click may restore a protection, never remove
// one. Re-arming deletes a mute file; muting stays a deliberate `touch` in a
// shell. Suppressing a permission prompt is the single exception and it asks first.

import AppKit
import Foundation

// ── Where state lives ────────────────────────────────────────────────────────

enum SwitchboardPaths {
    /// Overridable so probes can run against a fixture tree instead of the real
    /// config. Everything in this file resolves through it.
    static var gccRoot: String = NSString(string: "~/.claude").expandingTildeInPath
    static var settingsJSON: String { gccRoot + "/settings.json" }
    static var hooksDir: String { gccRoot + "/scripts/hooks" }
}

// ── Guards: mute sentinels ───────────────────────────────────────────────────

struct MutedGuard {
    let sentinel: String        // ".no-review-required"
    let name: String            // "review-required"
    let mutedAt: Date?
}

enum Guards {
    /// Every mute sentinel any hook looks for, discovered by reading the hooks
    /// rather than hard-coding a list that would rot as hooks are added.
    static func knownSentinels() -> [String] {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: SwitchboardPaths.hooksDir)
        else { return [] }
        var found = Set<String>()
        // Matches ".no-foo", ".allow-bar", ".baz-off" as they appear in hook source.
        let re = try? NSRegularExpression(
            pattern: #"\.claude/(\.(?:no|allow)-[a-z0-9-]+|\.[a-z0-9-]+-(?:off|gate|guard))"#)
        for f in files where f.hasSuffix(".sh") {
            guard let body = try? String(contentsOfFile: SwitchboardPaths.hooksDir + "/" + f,
                                         encoding: .utf8) else { continue }
            let ns = body as NSString
            re?.enumerateMatches(in: body, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
                if let m = m, m.numberOfRanges > 1 {
                    found.insert(ns.substring(with: m.range(at: 1)))
                }
            }
        }
        return found.sorted()
    }

    /// Only the sentinels that actually exist, i.e. the guards currently off.
    /// `.allow-fable-subagents` is a deliberate policy lift, not a mute, so it is
    /// excluded: listing it would nag the owner to undo a standing decision.
    static func muted() -> [MutedGuard] {
        let fm = FileManager.default
        return knownSentinels().compactMap { sentinel in
            guard sentinel != ".allow-fable-subagents" else { return nil }
            let path = SwitchboardPaths.gccRoot + "/" + sentinel
            guard fm.fileExists(atPath: path) else { return nil }
            let when = (try? fm.attributesOfItem(atPath: path)[.creationDate]) as? Date
            var name = sentinel
            for prefix in [".no-", ".allow-"] where name.hasPrefix(prefix) {
                name = String(name.dropFirst(prefix.count))
            }
            if name.hasPrefix(".") { name = String(name.dropFirst()) }
            return MutedGuard(sentinel: sentinel, name: name, mutedAt: when)
        }
    }

    /// Re-arm: delete the sentinel so the hook fires again. The only direction
    /// this file offers. Returns false if the guard was already armed.
    @discardableResult
    static func rearm(_ g: MutedGuard) -> Bool {
        let path = SwitchboardPaths.gccRoot + "/" + g.sentinel
        guard FileManager.default.fileExists(atPath: path) else { return false }
        return (try? FileManager.default.removeItem(atPath: path)) != nil
    }
}

// ── Guards: stale push approvals ─────────────────────────────────────────────

struct PushApproval {
    let file: String            // ".push-approved-<uuid>"
    let sessionID: String
    let armedAt: Date?
    /// True when the approving session is no longer live, so the approval is a
    /// loaded gun nobody is holding.
    let sessionIsLive: Bool
}

enum PushApprovals {
    static func armed(liveSessionIDs: Set<String>) -> [PushApproval] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: SwitchboardPaths.gccRoot)
        else { return [] }
        return files.filter { $0.hasPrefix(".push-approved-") }.map { f in
            let sid = String(f.dropFirst(".push-approved-".count))
            let when = (try? fm.attributesOfItem(atPath: SwitchboardPaths.gccRoot + "/" + f)[.creationDate]) as? Date
            return PushApproval(file: f, sessionID: sid, armedAt: when,
                                sessionIsLive: liveSessionIDs.contains(sid))
        }.sorted { ($0.armedAt ?? .distantPast) < ($1.armedAt ?? .distantPast) }
    }

    /// Clear: revoke an approval. Safe in one click because revoking can only
    /// add friction, never remove it.
    @discardableResult
    static func clear(_ a: PushApproval) -> Bool {
        (try? FileManager.default.removeItem(atPath: SwitchboardPaths.gccRoot + "/" + a.file)) != nil
    }
}

// ── settings.json: cost and permission flags ─────────────────────────────────

enum SettingsFlag: String, CaseIterable {
    case alwaysThinking       = "alwaysThinkingEnabled"
    case skipDangerousPrompt  = "skipDangerousModePermissionPrompt"
    case skipAutoPrompt       = "skipAutoPermissionPrompt"
    case skipWorkflowWarning  = "skipWorkflowUsageWarning"

    var label: String {
        switch self {
        case .alwaysThinking:      return "Always thinking"
        case .skipDangerousPrompt: return "Dangerous-mode prompt"
        case .skipAutoPrompt:      return "Auto-permission prompt"
        case .skipWorkflowWarning: return "Workflow usage warning"
        }
    }

    /// True when flipping this ON removes a safeguard. Those three read
    /// inverted in the UI: the row shows whether the PROMPT is on, not whether
    /// the skip is on, because "skip" as a switch label inverts the mental model.
    var isSuppressor: Bool { self != .alwaysThinking }
}

enum Settings {
    static func read() -> [String: Any] {
        guard let d = FileManager.default.contents(atPath: SwitchboardPaths.settingsJSON),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
        else { return [:] }
        return o
    }

    static func bool(_ f: SettingsFlag) -> Bool {
        read()[f.rawValue] as? Bool ?? false
    }

    static func effortLevel() -> String {
        read()["effortLevel"] as? String ?? "unknown"
    }

    static let efforts = ["low", "medium", "high", "xhigh"]

    /// Read-modify-write that keeps every key it did not touch, writes to a
    /// sibling temp file, and swaps atomically, so an interrupted write cannot
    /// leave a half-file where the config belongs. A timestamped backup is kept
    /// because this is the user's global config, not ours.
    @discardableResult
    static func write(key: String, value: Any) -> Bool {
        let path = SwitchboardPaths.settingsJSON
        var obj = read()
        guard !obj.isEmpty else { return false }   // never create from nothing
        obj[key] = value
        guard let out = try? JSONSerialization.data(withJSONObject: obj,
                                                    options: [.prettyPrinted, .sortedKeys])
        else { return false }
        let backup = path + ".bak-" + String(Int(Date().timeIntervalSince1970))
        try? FileManager.default.copyItem(atPath: path, toPath: backup)
        let tmp = path + ".tmp-\(getpid())"
        guard (try? out.write(to: URL(fileURLWithPath: tmp), options: .atomic)) != nil else { return false }
        do {
            _ = try FileManager.default.replaceItemAt(URL(fileURLWithPath: path),
                                                      withItemAt: URL(fileURLWithPath: tmp))
            return true
        } catch {
            try? FileManager.default.removeItem(atPath: tmp)
            return false
        }
    }
}

// ── Services ─────────────────────────────────────────────────────────────────

struct ServiceState {
    let name: String
    let running: Bool
    /// Distinct from `running` on purpose. The hub taught this: a live process on
    /// a listening socket whose advertised address no longer resolves is up and
    /// unreachable at the same time.
    let reachable: Bool
    let detail: String
}

enum Services {
    /// One blocking HTTP probe with a hard cap. Callers must run this off the
    /// main thread; the menu never waits on the network.
    static func probeHTTP(_ urlString: String, timeout: TimeInterval = 1.0) -> Bool {
        guard let url = URL(string: urlString) else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        var ok = false
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { _, resp, _ in
            ok = (resp as? HTTPURLResponse)?.statusCode == 200
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + timeout + 0.5)
        return ok
    }

    /// The address the hub advertises for phones, read from its own listener
    /// rather than assumed, so a stale tailnet bind is visible.
    static func hubAdvertisedHost() -> String? {
        let out = shell("/usr/sbin/lsof", ["-nP", "-iTCP:5400", "-sTCP:LISTEN"])
        for line in out.split(separator: "\n") {
            guard let tok = line.split(separator: " ").last(where: { $0.contains(":5400") }) else { continue }
            let host = tok.replacingOccurrences(of: ":5400", with: "")
            if host != "127.0.0.1" && host != "*" && !host.isEmpty { return host }
        }
        return nil
    }

    static func pm2Status(_ name: String) -> String? {
        let out = shell("/bin/zsh", ["-lc", "pm2 jlist 2>/dev/null"])
        guard let data = out.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return nil }
        for p in arr where p["name"] as? String == name {
            return ((p["pm2_env"] as? [String: Any])?["status"] as? String)
        }
        return nil
    }

    @discardableResult
    static func pm2(_ verb: String, _ name: String) -> Bool {
        _ = shell("/bin/zsh", ["-lc", "pm2 \(verb) \(name)"])
        return true
    }

    static func shell(_ exe: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return "" }
        let d = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: d, encoding: .utf8) ?? ""
    }
}

// ── Board sync ───────────────────────────────────────────────────────────────

enum BoardSync {
    static var cli: String { SwitchboardPaths.gccRoot + "/scripts/sync-todos/sync-cli.sh" }

    static func enabled() -> Bool {
        guard FileManager.default.fileExists(atPath: cli) else { return false }
        return Services.shell("/bin/bash", [cli, "status"]).contains("state:        enabled")
    }

    @discardableResult
    static func set(_ on: Bool) -> Bool {
        guard FileManager.default.fileExists(atPath: cli) else { return false }
        _ = Services.shell("/bin/bash", [cli, on ? "enable" : "disable"])
        return true
    }
}
