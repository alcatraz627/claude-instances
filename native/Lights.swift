// Lights.swift
// The Switchboard's Home tab: the WiZ smart bulbs on the home network, each
// with on/off, brightness, warmth and scenes. All protocol work is in
// lib/wiz.py; this file only calls it and draws the result.

import AppKit
import Foundation
import SwiftUI

struct Bulb: Identifiable, Equatable {
    let ip: String
    let mac: String
    var name: String
    var reachable: Bool
    var on: Bool
    var dimming: Int
    var temp: Int?
    var scene: Int?
    var sceneName: String?

    var id: String { mac }
    var title: String { name.isEmpty ? "Bulb \(ip.split(separator: ".").last ?? "")" : name }

    init?(_ d: [String: Any]) {
        guard let ip = d["ip"] as? String, let mac = d["mac"] as? String else { return nil }
        self.ip = ip; self.mac = mac
        name = d["name"] as? String ?? ""
        reachable = d["reachable"] as? Bool ?? false
        on = d["on"] as? Bool ?? false
        dimming = (d["dimming"] as? NSNumber)?.intValue ?? 100
        temp = (d["temp"] as? NSNumber)?.intValue
        scene = (d["scene"] as? NSNumber)?.intValue
        sceneName = d["scene_name"] as? String
    }
}

enum WizCLI {
    static var script = NSString(string: "~/.claude/widgets/claude-instances/lib/wiz.py").expandingTildeInPath

    static func run(_ args: [String], timeout: TimeInterval = 8) -> (json: Any?, err: String?) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", script] + args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return (nil, "could not start wiz.py") }
        var data = Data()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { data = out.fileHandleForReading.readDataToEndOfFile(); done.signal() }
        if done.wait(timeout: .now() + timeout) == .timedOut { p.terminate(); return (nil, "wiz.py timed out") }
        p.waitUntilExit()
        let obj = try? JSONSerialization.jsonObject(with: data)
        if let e = (obj as? [String: Any])?["error"] as? String { return (nil, e) }
        return (obj, p.terminationStatus == 0 ? nil : "wiz.py failed")
    }
}

final class LightsStore: ObservableObject {
    @Published private(set) var bulbs: [Bulb] = []
    @Published private(set) var discovering = false
    @Published private(set) var lastScan: Date?
    @Published var error: String?
    @Published private(set) var busy: Set<String> = []
    private let queue = DispatchQueue(label: "lights.store", qos: .userInitiated)

    /// Scan the network. Cheap (one broadcast, 3 s of listening), so it runs
    /// on every open; the last list stays on screen meanwhile.
    func discover() {
        guard !discovering else { return }
        discovering = true
        queue.async { [weak self] in
            let r = WizCLI.run(["discover"])
            let list = (r.json as? [[String: Any]])?.compactMap(Bulb.init) ?? []
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.discovering = false
                self.lastScan = Date()
                if let e = r.err { self.error = e; return }
                self.error = nil
                self.bulbs = list
            }
        }
    }

    /// Send one change to one bulb and show what the bulb reports back.
    func set(_ bulb: Bulb, _ pairs: [String]) {
        busy.insert(bulb.mac)
        queue.async { [weak self] in
            let r = WizCLI.run(["set", bulb.ip] + pairs)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.busy.remove(bulb.mac)
                if let e = r.err { self.error = "\(bulb.title): \(e)"; return }
                self.error = nil
                if let d = r.json as? [String: Any], var b = Bulb(d),
                   let i = self.bulbs.firstIndex(where: { $0.mac == bulb.mac }) {
                    b.name = self.bulbs[i].name
                    self.bulbs[i] = b
                }
            }
        }
    }

    func setAll(on: Bool) {
        for b in bulbs where b.reachable && b.on != on { set(b, ["state=\(on ? "on" : "off")"]) }
    }

    func rename(_ bulb: Bulb, to name: String) {
        _ = WizCLI.run(["name", bulb.mac, name])
        if let i = bulbs.firstIndex(where: { $0.mac == bulb.mac }) { bulbs[i].name = name }
    }

    func loadForSnapshot() {
        let r = WizCLI.run(["discover"])
        bulbs = (r.json as? [[String: Any]])?.compactMap(Bulb.init) ?? []
        error = r.err
        lastScan = Date()
    }

    static let scenes: [(Int, String)] = [
        (11, "Warm White"), (30, "Golden White"), (12, "Daylight"), (13, "Cool White"),
        (14, "Night Light"), (15, "Focus"), (16, "Relax"), (29, "Candlelight"), (6, "Cozy"),
        (10, "Bedtime"), (9, "Wake Up"), (18, "TV Time"), (5, "Fireplace"), (3, "Sunset"),
        (1, "Ocean"), (7, "Forest"), (8, "Pastel Colors"), (17, "True Colors"), (2, "Romance"),
        (4, "Party"), (26, "Club"), (31, "Pulse"),
    ]
}

// ── The tab ─────────────────────────────────────────────────────────────────

struct LightsTabView: View {
    @ObservedObject var lights: LightsStore

    var body: some View {
        VStack(alignment: .leading, spacing: SBStyle.gap) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    SBGroupHeader(name: "Lights")
                    if lights.discovering { ProgressView().controlSize(.mini) }
                    Spacer()
                    if lights.bulbs.contains(where: { $0.reachable }) {
                        Button("All off") { lights.setAll(on: false) }.controlSize(.small)
                        Button("All on") { lights.setAll(on: true) }.controlSize(.small)
                    }
                    Button { lights.discover() } label: {
                        Image(systemName: "arrow.clockwise").font(.system(size: 10))
                    }
                    .buttonStyle(.borderless)
                    .help("Look for bulbs on the network again")
                }
                .padding(.trailing, 4)
                SBCard {
                    if let e = lights.error {
                        Text(e).font(SBStyle.caption).foregroundStyle(.red)
                            .padding(.horizontal, SBStyle.rowH).padding(.vertical, 6)
                    }
                    if lights.bulbs.isEmpty {
                        Text(lights.discovering ? "Looking for bulbs…" : "No bulbs answered on this network.")
                            .font(SBStyle.caption).foregroundStyle(.secondary)
                            .padding(.horizontal, SBStyle.rowH).padding(.vertical, 8)
                    }
                    ForEach(Array(lights.bulbs.enumerated()), id: \.element.id) { i, b in
                        if i > 0 { Divider().padding(.leading, SBStyle.rowH) }
                        BulbRow(bulb: b, lights: lights)
                    }
                }
            }
            Text("WiZ bulbs on your home network, controlled directly over the LAN. No account or cloud involved.")
                .font(SBStyle.caption).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }
        .padding(SBStyle.gap)
    }
}

private struct BulbRow: View {
    let bulb: Bulb
    @ObservedObject var lights: LightsStore
    @State private var dim: Double = 50
    @State private var warm: Double = 2700
    @State private var editing = false

    private var busy: Bool { lights.busy.contains(bulb.mac) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: bulb.on ? "lightbulb.fill" : "lightbulb")
                    .foregroundStyle(bulb.on ? Color.yellow : Color.secondary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(bulb.title).font(SBStyle.label)
                    Text(bulb.reachable
                         ? (bulb.on ? "\(bulb.dimming)% · \(bulb.sceneName ?? bulb.temp.map { "\($0)K" } ?? "")" : "off")
                         : "not answering")
                        .font(SBStyle.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    Section("Scene") {
                        ForEach(LightsStore.scenes, id: \.0) { s in
                            Button(s.1) { lights.set(bulb, ["scene=\(s.0)"]) }
                        }
                    }
                    Divider()
                    Button("Rename…") { rename() }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .disabled(!bulb.reachable)
                Toggle("", isOn: Binding(get: { bulb.on },
                                         set: { lights.set(bulb, ["state=\($0 ? "on" : "off")"]) }))
                    .toggleStyle(.switch).controlSize(.small).labelsHidden()
                    .disabled(!bulb.reachable || busy)
            }
            if bulb.on && bulb.reachable {
                HStack(spacing: 8) {
                    Image(systemName: "sun.min").font(.system(size: 10)).foregroundStyle(.secondary)
                    Slider(value: Binding(get: { editing ? dim : Double(bulb.dimming) }, set: { dim = $0 }),
                           in: 10...100,
                           onEditingChanged: { e in
                               if e { dim = Double(bulb.dimming); editing = true }
                               else { editing = false; lights.set(bulb, ["dimming=\(Int(dim))"]) }
                           }).controlSize(.mini)
                    Image(systemName: "thermometer.medium").font(.system(size: 10)).foregroundStyle(.secondary)
                    Slider(value: Binding(get: { editing ? warm : Double(bulb.temp ?? 2700) }, set: { warm = $0 }),
                           in: 2200...6500,
                           onEditingChanged: { e in
                               if e { warm = Double(bulb.temp ?? 2700); editing = true }
                               else { editing = false; lights.set(bulb, ["temp=\(Int(warm / 100) * 100)"]) }
                           }).controlSize(.mini)
                        .help("Warm to cool white")
                }
                .padding(.leading, 24)
                .disabled(busy)
            }
        }
        .padding(.horizontal, SBStyle.rowH).padding(.vertical, SBStyle.rowV + 1)
        .opacity(bulb.reachable ? 1 : 0.55)
    }

    private func rename() {
        let a = NSAlert()
        a.messageText = "Name this bulb"
        a.informativeText = "\(bulb.ip) · \(bulb.mac)"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.stringValue = bulb.name
        a.accessoryView = field
        a.addButton(withTitle: "Save")
        a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn { lights.rename(bulb, to: field.stringValue) }
    }
}
