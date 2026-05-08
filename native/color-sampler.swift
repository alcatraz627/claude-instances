// color-sampler.swift
// Vibrancy color sampler — shows candidate colors on menu-like translucent bg.
// Auto-saves on every toggle to /tmp/color-sampler-result.json.
//
// Compile:  swiftc -O -framework SwiftUI color-sampler.swift -o /tmp/color-sampler
// Run:      /tmp/color-sampler

import AppKit
import SwiftUI

// ─── Data ────────────────────────────────────────────────────────────────────

struct ColorEntry: Identifiable, Codable {
    let id: String
    let group: String
    let name: String
    let rgb: String
    var good: Bool = false
}

func resolve(_ rgb: String) -> NSColor {
    switch rgb {
    case "systemGreen":         return .systemGreen
    case "systemYellow":        return .systemYellow
    case "systemCyan":          return .systemCyan
    case "systemBrown":         return .systemBrown
    case "systemGray":          return .systemGray
    case "secondaryLabelColor": return .secondaryLabelColor
    case "tertiaryLabelColor":  return .tertiaryLabelColor
    case "labelColor":          return .labelColor
    default:
        let p = rgb.split(separator: "/").compactMap { Double($0) }
        guard p.count == 3 else { return .labelColor }
        return NSColor(red: p[0], green: p[1], blue: p[2], alpha: 1)
    }
}

let allEntries: [ColorEntry] = [
    // Green
    ColorEntry(id: "green-0", group: "Green (rate bar & ctx %)",  name: ".systemGreen (current)", rgb: "systemGreen"),
    ColorEntry(id: "green-A", group: "Green (rate bar & ctx %)",  name: "Dark Forest A",          rgb: "0.0/0.50/0.0"),
    ColorEntry(id: "green-B", group: "Green (rate bar & ctx %)",  name: "Dark Forest B",          rgb: "0.0/0.42/0.05"),
    ColorEntry(id: "green-C", group: "Green (rate bar & ctx %)",  name: "Emerald",                rgb: "0.05/0.38/0.12"),
    ColorEntry(id: "green-D", group: "Green (rate bar & ctx %)",  name: "Pine",                   rgb: "0.0/0.35/0.15"),
    ColorEntry(id: "green-E", group: "Green (rate bar & ctx %)",  name: "Dark Olive",             rgb: "0.20/0.38/0.0"),
    // Yellow
    ColorEntry(id: "yellow-0", group: "Yellow (rate bar 50-75%)", name: ".systemYellow (current)", rgb: "systemYellow"),
    ColorEntry(id: "yellow-A", group: "Yellow (rate bar 50-75%)", name: "Dark Gold",               rgb: "0.60/0.50/0.0"),
    ColorEntry(id: "yellow-B", group: "Yellow (rate bar 50-75%)", name: "Amber",                   rgb: "0.65/0.45/0.0"),
    ColorEntry(id: "yellow-C", group: "Yellow (rate bar 50-75%)", name: "Ochre",                   rgb: "0.50/0.40/0.05"),
    ColorEntry(id: "yellow-D", group: "Yellow (rate bar 50-75%)", name: "Mustard",                 rgb: "0.55/0.48/0.0"),
    ColorEntry(id: "yellow-E", group: "Yellow (rate bar 50-75%)", name: "Dark Honey",              rgb: "0.58/0.42/0.05"),
    // Cyan
    ColorEntry(id: "cyan-0",  group: "Cyan (weekly rate bar)",    name: ".systemCyan (current)",   rgb: "systemCyan"),
    ColorEntry(id: "cyan-A",  group: "Cyan (weekly rate bar)",    name: "Dark Cyan A",             rgb: "0.0/0.45/0.55"),
    ColorEntry(id: "cyan-B",  group: "Cyan (weekly rate bar)",    name: "Dark Cyan B",             rgb: "0.0/0.38/0.50"),
    ColorEntry(id: "cyan-C",  group: "Cyan (weekly rate bar)",    name: "Deep Teal",               rgb: "0.0/0.40/0.48"),
    ColorEntry(id: "cyan-D",  group: "Cyan (weekly rate bar)",    name: "Steel Cyan",              rgb: "0.10/0.42/0.52"),
    ColorEntry(id: "cyan-E",  group: "Cyan (weekly rate bar)",    name: "Ocean",                   rgb: "0.0/0.35/0.45"),
    // Elapsed
    ColorEntry(id: "elapsed-0", group: "Elapsed time",            name: ".systemBrown (current)",  rgb: "systemBrown"),
    ColorEntry(id: "elapsed-A", group: "Elapsed time",            name: ".secondaryLabelColor",    rgb: "secondaryLabelColor"),
    ColorEntry(id: "elapsed-B", group: "Elapsed time",            name: ".systemGray",             rgb: "systemGray"),
    ColorEntry(id: "elapsed-C", group: "Elapsed time",            name: ".labelColor",             rgb: "labelColor"),
    ColorEntry(id: "elapsed-D", group: "Elapsed time",            name: ".tertiaryLabelColor",     rgb: "tertiaryLabelColor"),
]

// ─── State ───────────────────────────────────────────────────────────────────

let resultPath = "/tmp/color-sampler-result.json"

class SamplerState: ObservableObject {
    @Published var entries: [ColorEntry] = allEntries
    @Published var status: String = ""

    func toggle(_ index: Int) {
        entries[index].good.toggle()
        save()
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(entries.filter { $0.good })
            try data.write(to: URL(fileURLWithPath: resultPath))
            let fmt = DateFormatter()
            fmt.dateFormat = "HH:mm:ss"
            status = "Saved \(entries.filter { $0.good }.count) picks at \(fmt.string(from: Date()))"
        } catch {
            status = "Error: \(error.localizedDescription)"
        }
    }
}

// ─── Vibrancy background (matches NSMenu material) ──────────────────────────

struct MenuVibrancy: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .menu
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

// ─── Views ───────────────────────────────────────────────────────────────────

func sample(_ group: String) -> String {
    if group.contains("Green")   { return "⏱ 5h [████░░░░░░] 35%   ctx 72%" }
    if group.contains("Yellow")  { return "⏱ 5h [██████░░░░] 60%" }
    if group.contains("Cyan")    { return "📅 7d [▓▓▓░░░░░░░] 30%" }
    if group.contains("Elapsed") { return "  3h  ·  12m  ·  45m  ·  now" }
    return "Sample"
}

struct SamplerView: View {
    @StateObject var state = SamplerState()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().padding(.horizontal, 12)
            colorList
            Divider().padding(.horizontal, 12)
            footer
        }
        .frame(minWidth: 680, minHeight: 600)
        .background(MenuVibrancy())
    }

    var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Color Sampler").font(.system(size: 15, weight: .bold))
                Spacer()
                Text("ultraThinMaterial (menu-like vibrancy)")
                    .font(.system(size: 10)).foregroundColor(.secondary)
            }
            Text("Click circles to mark good colors. Auto-saves every toggle.")
                .font(.system(size: 11)).foregroundColor(.secondary)
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 8)
    }

    var colorList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                let grouped = Dictionary(grouping: state.entries.indices, by: { state.entries[$0].group })
                let order = ["Green (rate bar & ctx %)", "Yellow (rate bar 50-75%)",
                             "Cyan (weekly rate bar)", "Elapsed time"]

                ForEach(order, id: \.self) { groupName in
                    if let indices = grouped[groupName] {
                        Text(groupName)
                            .font(.system(size: 12, weight: .bold))
                            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 4)

                        ForEach(indices, id: \.self) { i in
                            let entry = state.entries[i]
                            HStack(spacing: 0) {
                                // Toggle
                                Button { state.toggle(i) } label: {
                                    Image(systemName: entry.good ? "checkmark.circle.fill" : "circle")
                                        .foregroundColor(entry.good ? .green : .secondary)
                                        .font(.system(size: 14))
                                }
                                .buttonStyle(.plain)
                                .frame(width: 28)

                                // Swatch
                                Circle().fill(Color(nsColor: resolve(entry.rgb)))
                                    .frame(width: 12, height: 12).padding(.trailing, 6)

                                // Name
                                Text(entry.name)
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .frame(width: 190, alignment: .leading)

                                // Sample text in this color
                                Text(sample(entry.group))
                                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                                    .foregroundColor(Color(nsColor: resolve(entry.rgb)))

                                Spacer()

                                // RGB ref
                                Text(entry.rgb)
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundColor(.secondary.opacity(0.5))
                                    .frame(width: 120, alignment: .trailing)
                            }
                            .padding(.vertical, 3).padding(.horizontal, 12)
                            .background(entry.good ? Color.green.opacity(0.1) : Color.clear)
                            .cornerRadius(4)
                        }

                        Divider().padding(.horizontal, 12).padding(.top, 6)
                    }
                }
            }
            .padding(.bottom, 12)
        }
    }

    var footer: some View {
        HStack {
            Text(state.status)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(.green)
            Spacer()
            Text(resultPath)
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.secondary.opacity(0.4))
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
}

// ─── App ─────────────────────────────────────────────────────────────────────

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!

    func applicationDidFinishLaunching(_ note: Notification) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 660),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "Color Sampler"
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.backgroundColor = .clear
        window.isOpaque = false
        window.contentView = NSHostingView(rootView: SamplerView())
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ a: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
let del = AppDelegate()
app.delegate = del
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)
app.run()
