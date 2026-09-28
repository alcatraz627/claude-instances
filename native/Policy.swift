// Policy.swift
// The owner's policy switches, as the menu bar panel sees them: what agents may
// do as the owner (GitHub, Slack, commits, deploys, model seats) and a few
// tunable thresholds. Values live in ~/.claude/policy and are read and written
// only through pol.sh, so the panel and the hooks can never disagree.
//
// The panel runs pol.sh with the agent-shell markers stripped from its
// environment. pol.sh refuses writes from agent shells; this app is the
// owner's own surface, and every write here is a click.

import AppKit
import Foundation
import SwiftUI

// ── Model: one policy as pol.sh json reports it ─────────────────────────────

enum PolicyValue: Equatable, Hashable {
    case text(String)
    case number(Double)

    init?(json: Any?) {
        if let s = json as? String { self = .text(s) }
        else if let n = json as? NSNumber { self = .number(n.doubleValue) }
        else { return nil }
    }

    /// The form pol.sh set takes on its command line.
    var cli: String {
        switch self {
        case .text(let s): return s
        case .number(let d): return d == d.rounded() ? String(Int(d)) : String(d)
        }
    }
}

struct PolicySnooze: Equatable {
    let scope: String          // "global" or "project"
    let until: Date
    let then: PolicyValue
    let expired: Bool
}

struct PolicyItem: Identifiable, Equatable {
    enum Kind: Equatable {
        case toggle                           // bool: allow / block
        case segmented([String])              // enum of 3 or fewer
        case menu([String])                   // larger enum
        case slider(min: Double, max: Double, step: Double, unit: String)
    }

    let key: String
    let label: String
    let group: String
    let help: String
    let kind: Kind
    let value: PolicyValue
    let defaultValue: PolicyValue
    let source: String                        // "project", "global" or "default"
    let globalValue: PolicyValue?
    let projectValue: PolicyValue?
    let projectScoped: Bool
    let snooze: PolicySnooze?

    var id: String { key }
    var isDefault: Bool { value == defaultValue }

    /// Every value this policy can take, for the snooze menu and pickers.
    var options: [PolicyValue] {
        switch kind {
        case .toggle: return [.text("allow"), .text("block")]
        case .segmented(let o), .menu(let o): return o.map { .text($0) }
        case .slider: return []
        }
    }

    static func from(_ d: [String: Any], now: Date) -> PolicyItem? {
        guard let key = d["key"] as? String, let type = d["type"] as? String,
              let value = PolicyValue(json: d["value"]),
              let def = PolicyValue(json: d["default"]) else { return nil }
        let kind: Kind
        switch type {
        case "bool": kind = .toggle
        case "enum":
            let opts = d["options"] as? [String] ?? []
            kind = opts.count <= 3 ? .segmented(opts) : .menu(opts)
        case "number":
            kind = .slider(min: (d["min"] as? NSNumber)?.doubleValue ?? 0,
                           max: (d["max"] as? NSNumber)?.doubleValue ?? 100,
                           step: (d["step"] as? NSNumber)?.doubleValue ?? 1,
                           unit: d["unit"] as? String ?? "")
        default: return nil
        }
        var snooze: PolicySnooze?
        if let s = d["snooze"] as? [String: Any],
           let until = (s["until"] as? NSNumber)?.doubleValue,
           let then = PolicyValue(json: s["then"]) {
            snooze = PolicySnooze(scope: s["scope"] as? String ?? "global",
                                  until: Date(timeIntervalSince1970: until),
                                  then: then,
                                  expired: s["expired"] as? Bool ?? false)
        }
        return PolicyItem(key: key,
                          label: d["label"] as? String ?? key,
                          group: d["group"] as? String ?? "Other",
                          help: d["help"] as? String ?? "",
                          kind: kind, value: value, defaultValue: def,
                          source: d["source"] as? String ?? "default",
                          globalValue: PolicyValue(json: d["global_value"]),
                          projectValue: PolicyValue(json: d["project_value"]),
                          projectScoped: d["project_scoped"] as? Bool ?? false,
                          snooze: snooze)
    }
}

/// Where a change lands: everywhere, or one repository's override.
enum PolicyScope: Hashable {
    case global
    case project(String)      // absolute repo root, as pol.sh keys it

    var cliArgs: [String] {
        switch self {
        case .global: return ["--global"]
        case .project(let root): return ["--project", root]
        }
    }

    var title: String {
        switch self {
        case .global: return "Everywhere"
        case .project(let root): return (root as NSString).lastPathComponent
        }
    }
}

// ── The bridge to pol.sh ────────────────────────────────────────────────────

enum PolicyCLI {
    /// Overridable so a probe can point the panel at a fixture store.
    static var script: String = NSString(string: "~/.claude/scripts/pol/pol.sh").expandingTildeInPath
    static var extraEnv: [String: String] = [:]

    /// Markers that make pol.sh treat the caller as an agent. The panel is the
    /// owner's surface, so its child process never carries them.
    static let agentMarkers = ["CLAUDECODE", "AI_AGENT", "CODEX_SANDBOX", "CODEX_THREAD_ID", "GCC_DISPATCH"]

    /// Runs pol.sh with a hard time cap. Returns stdout, stderr and the exit code.
    static func run(_ args: [String], timeout: TimeInterval = 5) -> (out: String, err: String, code: Int32) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script] + args
        var env = ProcessInfo.processInfo.environment
        for k in agentMarkers { env.removeValue(forKey: k) }
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        for (k, v) in extraEnv { env[k] = v }
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        guard (try? p.run()) != nil else { return ("", "could not start pol.sh", 127) }

        // Drain both pipes off this thread so a large reply cannot deadlock.
        var o = Data(), e = Data()
        let group = DispatchGroup()
        group.enter(); DispatchQueue.global().async { o = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter(); DispatchQueue.global().async { e = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        if group.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            return ("", "pol.sh timed out", 124)
        }
        p.waitUntilExit()
        return (String(data: o, encoding: .utf8) ?? "", String(data: e, encoding: .utf8) ?? "", p.terminationStatus)
    }

    static func load(_ scope: PolicyScope) -> (items: [PolicyItem], projects: [String], error: String?) {
        var args = ["json"]
        if case .project(let root) = scope { args += ["--cwd", root] }
        let r = run(args)
        guard r.code == 0, let data = r.out.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = obj["policies"] as? [[String: Any]] else {
            let msg = r.err.trimmingCharacters(in: .whitespacesAndNewlines)
            return ([], [], msg.isEmpty ? "Could not read the policy store." : msg)
        }
        let now = Date()
        return (list.compactMap { PolicyItem.from($0, now: now) },
                obj["projects"] as? [String] ?? [], nil)
    }

    static func root(of dir: String) -> String? {
        let r = run(["root", dir])
        let s = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }
}

// ── System switches: the dropdown Switchboard's rows, shown in the panel ────
// Built by BarDelegate from the same rows and actions the dropdown uses, so the
// two surfaces can never disagree about a state or do different things.

struct SystemRow: Identifiable {
    enum State {
        case on(NSColor)
        case off
        case count(Int, NSColor)
        case ok
    }
    let label: String
    let state: State
    let note: String
    var enabled = true
    var tip = ""
    var link: String? = nil
    /// One click: flip or run it.
    var action: (() -> Void)? = nil
    /// A list of items to act on one by one, shown as a native menu.
    var menu: (() -> NSMenu)? = nil
    /// A pick-one setting (the scan cadence): labels, current index, setter.
    var choices: [String]? = nil
    var selected: Int = -1
    var onChoose: ((Int) -> Void)? = nil
    /// A running "for a while" flip on this switch, if any.
    var timer: SystemTimer? = nil
    /// Switches that can take a timer; nil for rows where one makes no sense.
    var timerKey: String? = nil
    /// A stable identity when labels can repeat (two jobs with one name).
    var key: String? = nil

    var id: String { key ?? label }
    /// A plain on/off with a single action renders as a switch.
    var isSwitch: Bool {
        guard action != nil, menu == nil else { return false }
        switch state { case .on, .off: return true; default: return false }
    }
    var isOn: Bool { if case .on = state { return true }; return false }
}

/// A switch flipped for a while: at `until` it returns to `restoreOn`, unless
/// the owner already put it there. Kept by the bar, so it survives restarts.
struct SystemTimer: Equatable {
    let until: Date
    let restoreOn: Bool
}

struct SystemGroup: Identifiable {
    let title: String
    let rows: [SystemRow]
    var id: String { title }
}

// ── The store the panel observes ────────────────────────────────────────────

final class PolicyStore: ObservableObject {
    @Published var scope: PolicyScope = .global
    @Published private(set) var items: [PolicyItem] = []
    @Published private(set) var projects: [String] = []
    @Published private(set) var error: String?
    @Published private(set) var busyKey: String?
    @Published var now = Date()
    @Published var systemGroups: [SystemGroup] = []

    /// Repositories the owner is working in right now, from the live sessions.
    var liveDirs: () -> [String] = { [] }
    /// Asks the bar to re-probe its services; results arrive via systemGroups.
    var requestSystemRefresh: () -> Void = {}
    /// Flip a system switch now and back at a time; cancel keeps the current
    /// state, endNow flips it back at once. The bar owns the timers.
    var startSystemTimer: (_ key: String, _ until: Date) -> Void = { _, _ in }
    var cancelSystemTimer: (_ key: String) -> Void = { _ in }
    var endSystemTimerNow: (_ key: String) -> Void = { _ in }
    private var liveRoots: [String] = []
    /// A directory's repo root never changes while the app runs, and each
    /// lookup is a process, so each directory is resolved once.
    private var rootCache: [String: String] = [:]
    private var rootMisses: Set<String> = []
    private let queue = DispatchQueue(label: "policy.store", qos: .userInitiated)

    /// Every scope the picker offers: everywhere, then each repo with an
    /// override or a live session, by name.
    var scopes: [PolicyScope] {
        let roots = Set(projects + liveRoots)
        return [.global] + roots.sorted { ($0 as NSString).lastPathComponent.lowercased() < ($1 as NSString).lastPathComponent.lowercased() }
            .map { .project($0) }
    }

    /// Policies shown for the current scope. A repo scope shows only the
    /// policies that take a per-repo override.
    var visibleItems: [PolicyItem] {
        if case .project = scope { return items.filter { $0.projectScoped } }
        return items
    }

    var groups: [(name: String, items: [PolicyItem])] {
        var order: [String] = []
        var byGroup: [String: [PolicyItem]] = [:]
        for i in visibleItems {
            if byGroup[i.group] == nil { order.append(i.group) }
            byGroup[i.group, default: []].append(i)
        }
        return order.map { ($0, byGroup[$0]!) }
    }

    /// keepError holds on to a write's refusal message through the reload
    /// that follows it, so the owner sees why a change did not stick.
    func reload(keepError: Bool = false, completion: (() -> Void)? = nil) {
        let scope = self.scope
        let unresolved = Set(liveDirs()).subtracting(rootCache.keys).subtracting(rootMisses)
        queue.async { [weak self] in
            // Values first, so the rows are current before the scope list is.
            let r = PolicyCLI.load(scope)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.items = r.items
                self.projects = r.projects
                if !keepError || r.error != nil { self.error = r.error }
                self.now = Date()
                completion?()
            }
            guard !unresolved.isEmpty else { return }
            var found: [String: String] = [:], missed: [String] = []
            for d in unresolved {
                if let root = PolicyCLI.root(of: d) { found[d] = root } else { missed.append(d) }
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.rootCache.merge(found) { a, _ in a }
                self.rootMisses.formUnion(missed)
                self.liveRoots = Array(Set(self.liveDirs().compactMap { self.rootCache[$0] }))
                self.objectWillChange.send()
            }
        }
    }

    private func write(_ key: String, _ args: [String]) {
        busyKey = key
        queue.async { [weak self] in
            let r = PolicyCLI.run(args)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.busyKey = nil
                if r.code != 0 {
                    let msg = r.err.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.error = msg.isEmpty ? "Could not save \(key)." : msg
                } else {
                    self.error = nil
                }
                self.reload(keepError: r.code != 0)
            }
        }
    }

    func set(_ item: PolicyItem, _ value: PolicyValue) {
        guard value != item.value || (scopeIsProject && item.source != "project") else { return }
        write(item.key, ["set", item.key, value.cli] + scope.cliArgs)
    }

    func snooze(_ item: PolicyItem, seconds: Int, then: PolicyValue) {
        let dur = seconds % 86400 == 0 ? "\(seconds / 86400)d" : "\(seconds / 60)m"
        write(item.key, ["snooze", item.key, "--for", dur, "--then", then.cli] + scope.cliArgs)
    }

    func snoozeTonight(_ item: PolicyItem, then: PolicyValue) {
        write(item.key, ["snooze", item.key, "--until", "today", "--then", then.cli] + scope.cliArgs)
    }

    /// Cancels the snooze where it lives: a repo view can show one inherited
    /// from Everywhere, and cancelling at the repo would leave it running.
    func cancelSnooze(_ item: PolicyItem) {
        let args = item.snooze?.scope == "global" ? PolicyScope.global.cliArgs : scope.cliArgs
        write(item.key, ["unsnooze", item.key] + args)
    }

    /// Remove this scope's own value, so the policy falls back to the next level.
    func reset(_ item: PolicyItem) {
        write(item.key, ["clear", item.key] + scope.cliArgs)
    }

    var scopeIsProject: Bool { if case .project = scope { return true }; return false }

    /// Does this row hold its own value at the current scope (so reset applies)?
    func hasOwnValue(_ item: PolicyItem) -> Bool {
        scopeIsProject ? item.source == "project" : item.globalValue != nil
    }

    /// Fill the store synchronously, for the headless snapshot and dump.
    func applyForSnapshot(items: [PolicyItem], projects: [String], error: String?) {
        self.items = items
        self.projects = projects
        self.error = error
        self.now = Date()
    }
}

// ── Plain-text rendering, for the headless probe and the dump flag ──────────

func policyDump(_ store: PolicyStore) -> String {
    var lines: [String] = []
    lines.append("scope: \(store.scope.title)")
    if let e = store.error { lines.append("error: \(e)") }
    for g in store.groups {
        lines.append("[\(g.name)]")
        for i in g.items {
            let control: String
            switch i.kind {
            case .toggle: control = "switch"
            case .segmented(let o): control = "segmented(\(o.joined(separator: "|")))"
            case .menu(let o): control = "menu(\(o.joined(separator: "|")))"
            case .slider(let lo, let hi, let st, let u): control = "slider(\(Int(lo))-\(Int(hi)) step \(Int(st))\(u))"
            }
            var s = "  \(i.label) = \(i.value.cli) [\(i.source)] \(control)"
            if let z = i.snooze, !z.expired { s += " snooze→\(z.then.cli)@\(Int(z.until.timeIntervalSince1970))" }
            lines.append(s)
        }
    }
    return lines.joined(separator: "\n")
}
