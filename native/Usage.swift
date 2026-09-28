// Usage.swift
// The Switchboard's Usage tab: how much of each Claude and Codex usage window
// is spent, when each resets, and the thresholds that act on those numbers.
//
// Claude's windows come from what Claude Code hands the statusline
// (~/.claude/widgets/.rate-limits-raw.json, every window it sends, falling
// back to .limits.json). Codex's come from codex-usage-gate.py --json, which
// asks Codex's app-server and caches the answer for ten minutes.

import AppKit
import Foundation
import SwiftUI

struct UsageWindow: Identifiable, Equatable {
    let id: String
    let label: String
    let pct: Int
    let resetsAt: Date?
}

struct CodexResetCredit: Equatable {
    let title: String
    let expiresAt: Date?
}

final class UsageStore: ObservableObject {
    @Published private(set) var claude: [UsageWindow] = []
    @Published private(set) var claudeAsOf: Date?
    @Published private(set) var codex: [UsageWindow] = []
    @Published private(set) var codexAsOf: Date?
    @Published private(set) var codexPlan: String?
    @Published private(set) var codexResets: [CodexResetCredit] = []
    @Published private(set) var codexError: String?
    @Published private(set) var codexBusy = false

    /// The Claude usage zones: the same UserDefaults keys the bar's icon flag
    /// and the instances dropdown read, so one slider moves all three.
    @Published var warnPct: Int = UserDefaults.standard.integer(forKey: "rateLimitWarningThreshold") {
        didSet { saveZone("rateLimitWarningThreshold", warnPct) }
    }
    @Published var dangerPct: Int = UserDefaults.standard.integer(forKey: "rateLimitDangerThreshold") {
        didSet { saveZone("rateLimitDangerThreshold", dangerPct) }
    }

    /// Where a Codex bar turns amber. Its red line is the policy's Codex seat
    /// stand-down, so only the warning needs a setting of its own.
    @Published var codexWarnPct: Int = UserDefaults.standard.integer(forKey: "codexWarningThreshold") {
        didSet { saveZone("codexWarningThreshold", codexWarnPct) }
    }

    /// The same fallbacks the bar registers at launch, so a process that did
    /// not launch the bar (a snapshot, a probe) still reads 70 and 90.
    init() {
        UserDefaults.standard.register(defaults: ["rateLimitWarningThreshold": 70, "rateLimitDangerThreshold": 90,
                                                  "codexWarningThreshold": 60])
        warnPct = UserDefaults.standard.integer(forKey: "rateLimitWarningThreshold")
        dangerPct = UserDefaults.standard.integer(forKey: "rateLimitDangerThreshold")
        codexWarnPct = UserDefaults.standard.integer(forKey: "codexWarningThreshold")
    }

    static var widgetsDir = NSString(string: "~/.claude/widgets").expandingTildeInPath
    static var codexGate = NSString(string: "~/.claude/adapters/codex/bin/codex-usage-gate.py").expandingTildeInPath
    private let queue = DispatchQueue(label: "usage.store", qos: .userInitiated)

    private func saveZone(_ key: String, _ v: Int) {
        guard UserDefaults.standard.integer(forKey: key) != v else { return }
        UserDefaults.standard.set(v, forKey: key)
        NotificationCenter.default.post(name: .menuBehaviorDidChange, object: nil)
    }

    /// Claude is a file read, so it is always fresh; Codex is re-asked only
    /// when its cache is older than ten minutes, or when `force` is set.
    func reload(forceCodex: Bool = false) {
        loadClaude()
        if forceCodex || codexAsOf.map({ Date().timeIntervalSince($0) > 600 }) ?? true {
            loadCodex(fresh: forceCodex)
        }
    }

    // ── Claude ──

    func loadClaude() {
        let raw = Self.widgetsDir + "/.rate-limits-raw.json"
        let legacy = Self.widgetsDir + "/.limits.json"
        var windows: [UsageWindow] = []
        var asOf: Date?
        if let d = FileManager.default.contents(atPath: raw),
           let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any], !o.isEmpty {
            asOf = modified(raw)
            for (key, v) in o {
                guard let w = v as? [String: Any],
                      let pct = (w["used_percentage"] as? NSNumber)?.doubleValue else { continue }
                windows.append(UsageWindow(id: key, label: Self.claudeLabel(key), pct: Int(pct.rounded()),
                                           resetsAt: Self.epoch(w["resets_at"])))
            }
        } else if let d = FileManager.default.contents(atPath: legacy),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            asOf = modified(legacy)
            if let p = (o["5h"] as? [String: Any])?["pct"] as? NSNumber {
                windows.append(UsageWindow(id: "five_hour", label: "5 hours", pct: p.intValue, resetsAt: Self.epoch(o["resets_at"])))
            }
            if let p = (o["week"] as? [String: Any])?["pct"] as? NSNumber {
                windows.append(UsageWindow(id: "seven_day", label: "Week", pct: p.intValue, resetsAt: Self.epoch(o["resets_at_weekly"])))
            }
        }
        claude = windows.sorted { Self.order($0.id) < Self.order($1.id) }
        claudeAsOf = asOf
    }

    /// five_hour, seven_day, then any per-model window, by name.
    static func order(_ id: String) -> String {
        id == "five_hour" ? "0" : id == "seven_day" ? "1" : "2" + id
    }

    static func claudeLabel(_ key: String) -> String {
        switch key {
        case "five_hour": return "5 hours"
        case "seven_day": return "Week"
        default:
            // seven_day_opus → "Week · Opus": a per-model window, named by model.
            let model = key.replacingOccurrences(of: "seven_day_", with: "")
                .replacingOccurrences(of: "five_hour_", with: "")
                .replacingOccurrences(of: "_", with: " ").capitalized
            return (key.hasPrefix("five_hour") ? "5 hours · " : "Week · ") + model
        }
    }

    // ── Codex ──

    func loadCodex(fresh: Bool) {
        guard !codexBusy else { return }
        codexBusy = true
        queue.async { [weak self] in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = ["python3", Self.codexGate, "--json"] + (fresh ? ["--fresh"] : [])
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
            p.environment = env
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            var parsed: [String: Any]?
            if (try? p.run()) != nil {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                // stdout is the JSON object, then one VERDICT line; take the object.
                if let s = String(data: data, encoding: .utf8), let end = s.range(of: "\n}", options: .backwards) {
                    let obj = String(s[s.startIndex..<end.upperBound])
                    parsed = try? JSONSerialization.jsonObject(with: Data(obj.utf8)) as? [String: Any]
                }
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.codexBusy = false
                guard let o = parsed else {
                    self.codexError = "Could not read Codex usage (is the codex CLI installed and signed in?)"
                    return
                }
                self.applyCodex(o)
            }
        }
    }

    func applyCodex(_ o: [String: Any]) {
        codexError = nil
        codexAsOf = Date()
        var windows: [UsageWindow] = []
        let byId = o["rateLimitsByLimitId"] as? [String: [String: Any]]
            ?? ["codex": (o["rateLimits"] as? [String: Any]) ?? [:]]
        for (id, lim) in byId {
            let name = id == "codex" ? "Codex" : ((lim["limitName"] as? String) ?? id)
            for slot in ["primary", "secondary"] {
                guard let w = lim[slot] as? [String: Any],
                      let pct = (w["usedPercent"] as? NSNumber)?.intValue else { continue }
                let mins = (w["windowDurationMins"] as? NSNumber)?.intValue ?? 0
                let span = mins == 10080 ? "Week" : mins == 300 ? "5 hours" : mins >= 60 ? "\(mins / 60)h" : "\(mins)m"
                windows.append(UsageWindow(id: "\(id).\(slot)", label: id == "codex" ? span : "\(span) · \(name)",
                                           pct: pct, resetsAt: Self.epoch(w["resetsAt"])))
            }
        }
        codex = windows.sorted { ($0.id.hasPrefix("codex") ? "0" : "1") + $0.id < ($1.id.hasPrefix("codex") ? "0" : "1") + $1.id }
        codexPlan = (o["rateLimits"] as? [String: Any])?["planType"] as? String
        let credits = ((o["rateLimitResetCredits"] as? [String: Any])?["credits"] as? [[String: Any]]) ?? []
        codexResets = credits.filter { ($0["status"] as? String) == "available" }.map {
            CodexResetCredit(title: ($0["title"] as? String) ?? "Reset", expiresAt: Self.epoch($0["expiresAt"]))
        }
    }

    // ── Helpers ──

    static func epoch(_ v: Any?) -> Date? {
        if let n = v as? NSNumber, n.doubleValue > 0 { return Date(timeIntervalSince1970: n.doubleValue) }
        if let s = v as? String, let d = Double(s), d > 0, d < 9_000_000_000 { return Date(timeIntervalSince1970: d) }
        return nil
    }

    private func modified(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
    }

    /// Fill synchronously, for the headless snapshot.
    func loadForSnapshot(codexJSON: [String: Any]?) {
        loadClaude()
        if let o = codexJSON { applyCodex(o) }
    }
}

// ── The tab ─────────────────────────────────────────────────────────────────

struct UsageTabView: View {
    @ObservedObject var usage: UsageStore
    @ObservedObject var policy: PolicyStore
    private var now: Date { policy.now }

    var body: some View {
        VStack(alignment: .leading, spacing: SBStyle.gap) {
            section("Claude", link: ("Usage page", "https://claude.ai/settings/usage"), asOf: usage.claudeAsOf) {
                if usage.claude.isEmpty {
                    note("No usage reading yet. It arrives with the next statusline render.")
                }
                ForEach(usage.claude) { w in
                    UsageBarRow(window: w, now: now,
                                color: zoneColor(w.pct, warn: usage.warnPct, danger: usage.dangerPct),
                                ticks: w.id == "seven_day" || w.id == "five_hour"
                                    ? [(usage.warnPct, "warn"), (usage.dangerPct, "danger"), (standDown, "stand-down")]
                                    : [(usage.warnPct, "warn"), (usage.dangerPct, "danger")])
                }
                ZoneSlider(label: "Warn at", value: $usage.warnPct, tint: .orange)
                ZoneSlider(label: "Danger at", value: $usage.dangerPct, tint: .red)
            }
            section("Codex", link: ("Usage page", "https://chatgpt.com/settings/usage?tab=overview"), asOf: usage.codexAsOf,
                    trailing: AnyView(refreshButton)) {
                if let e = usage.codexError { note(e) }
                if usage.codex.isEmpty && usage.codexError == nil {
                    note(usage.codexBusy ? "Asking Codex…" : "No Codex reading yet.")
                }
                ForEach(usage.codex) { w in
                    UsageBarRow(window: w, now: now,
                                color: zoneColor(w.pct, warn: usage.codexWarnPct, danger: codexGate),
                                ticks: w.id.hasPrefix("codex") ? [(usage.codexWarnPct, "warn"), (codexGate, "seat stand-down")]
                                                               : [(usage.codexWarnPct, "warn")])
                }
                ZoneSlider(label: "Warn at", value: $usage.codexWarnPct, tint: .orange)
                if !usage.codexResets.isEmpty {
                    let f = DateFormatter()
                    let _ = f.dateFormat = "d MMM"
                    note("\(usage.codexResets.count) free full reset\(usage.codexResets.count == 1 ? "" : "s") available"
                         + (usage.codexResets.compactMap { $0.expiresAt }.min().map { ", first expires \(f.string(from: $0))" } ?? ""))
                }
            }
            // The thresholds that act on these numbers live in the policy
            // store; they render here with the same rows the Agents tab uses.
            let limits = policy.items.filter { $0.group == "Limits" && $0.key.hasSuffix("_pct") }
            if !limits.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    SBGroupHeader(name: "What acts on these numbers")
                    SBCard {
                        ForEach(Array(limits.enumerated()), id: \.element.id) { i, item in
                            if i > 0 { Divider().padding(.leading, SBStyle.rowH) }
                            PolicyRowView(item: item, store: policy)
                        }
                    }
                }
            }
        }
        .padding(SBStyle.gap)
    }

    private var standDown: Int { policyNumber("ops.usage_gate_pct") ?? 90 }
    private var codexGate: Int { policyNumber("ops.codex_gate_pct") ?? 75 }

    private func policyNumber(_ key: String) -> Int? {
        if case .number(let d)? = policy.items.first(where: { $0.key == key })?.value { return Int(d) }
        return nil
    }

    private var refreshButton: some View {
        Button { usage.reload(forceCodex: true) } label: {
            if usage.codexBusy { ProgressView().controlSize(.mini) }
            else { Image(systemName: "arrow.clockwise").font(.system(size: 10)) }
        }
        .buttonStyle(.borderless)
        .help("Ask Codex for fresh numbers (takes a few seconds)")
    }

    private func zoneColor(_ pct: Int, warn: Int, danger: Int) -> Color {
        pct >= danger ? .red : pct >= warn ? .orange : .green
    }

    private func note(_ s: String) -> some View {
        Text(s).font(SBStyle.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, SBStyle.rowH).padding(.vertical, 4)
    }

    private func section<C: View>(_ title: String, link: (String, String), asOf: Date?,
                                  trailing: AnyView? = nil, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                SBGroupHeader(name: title)
                if let a = asOf, now.timeIntervalSince(a) > 1800 {
                    Text("as of \(relative(a, now: now))").font(.system(size: 9.5)).foregroundStyle(.tertiary)
                }
                Spacer()
                if let t = trailing { t }
                Link(destination: URL(string: link.1)!) {
                    Label(link.0, systemImage: "arrow.up.right").font(SBStyle.caption).labelStyle(.titleAndIcon)
                }
                .help(link.1)
            }
            .padding(.trailing, 4)
            SBCard { content() }
        }
    }
}

/// One window: label, a bar with threshold ticks, the percentage, and when it resets.
struct UsageBarRow: View {
    let window: UsageWindow
    let now: Date
    let color: Color
    let ticks: [(Int, String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(window.label).font(SBStyle.label)
                Spacer()
                Text("\(window.pct)%").font(SBStyle.mono)
                if let r = window.resetsAt, r > now {
                    Text("resets in \(countdownText(to: r, now: now))").font(SBStyle.caption).foregroundStyle(.secondary)
                }
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule().fill(color.opacity(0.85))
                        .frame(width: max(4, g.size.width * CGFloat(min(window.pct, 100)) / 100))
                    ForEach(Array(ticks.enumerated()), id: \.offset) { _, t in
                        Rectangle().fill(Color.primary.opacity(0.45))
                            .frame(width: 1.5, height: 10)
                            .offset(x: g.size.width * CGFloat(min(max(t.0, 0), 100)) / 100 - 0.75)
                            .help("\(t.1) at \(t.0)%")
                    }
                }
            }
            .frame(height: 7)
        }
        .padding(.horizontal, SBStyle.rowH).padding(.vertical, SBStyle.rowV + 1)
    }
}

/// A 50–100% slider for one of the Claude usage zones.
struct ZoneSlider: View {
    let label: String
    @Binding var value: Int
    let tint: Color
    @State private var draft: Double = 0
    @State private var dragging = false

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(tint).frame(width: 6, height: 6)
            Text(label).font(SBStyle.label)
            Spacer()
            Slider(value: Binding(get: { dragging ? draft : Double(value) },
                                  set: { draft = ($0 / 5).rounded() * 5 }),
                   in: 50...100,
                   onEditingChanged: { editing in
                       if editing { draft = Double(value); dragging = true }
                       else { dragging = false; value = Int(draft) }
                   })
                .controlSize(.small)
                .frame(width: 108)
            Text("\(dragging ? Int(draft) : value)%").font(SBStyle.mono).frame(width: 36, alignment: .trailing)
        }
        .padding(.horizontal, SBStyle.rowH).padding(.vertical, SBStyle.rowV)
    }
}

func relative(_ d: Date, now: Date) -> String { countdownText(to: now, now: d) + " ago" }
