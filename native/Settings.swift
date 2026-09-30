// Settings.swift
// The Settings window's views: palette editor with live row preview, display
// sizing, badge, appearance, menu behaviour, refresh, row visibility, keybinds.
// Hosted by SettingsWindowController (the Dashboard window that also hosted it
// was removed on 2026-09-30).

import AppKit
import Foundation
import SwiftUI

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
let tailwindPalette: [(hue: String, shades: [(name: String, hex: String)])] = [
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
func tailwindName(forHex hex: String) -> String? {
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
func samplePreviewInstance() -> LiveInstance {
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
        lastPrompt: "Add hover state to the nav links and make sure focus ring is visible",
        permissionMode: "auto",
        lastTool: LastTool(name: "Edit", target: "src/components/Nav.tsx", agoSeconds: 4)
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

    /// Clicking anywhere on the settings background resigns first responder
    /// — gives users a way to "dismiss" the keybind textfield without
    /// having to find a specific other control to click. Triggered via
    /// the .onTapGesture on the ScrollView's background.
    private func resignFirstResponder() {
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

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
                                // Token pill — reserved space so its appearance
                                // doesn't cause layout shift of PREVIEW label.
                                // Fixed-height frame + opacity transition.
                                Text(hoveredToken?.rawValue ?? " ")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.accentColor)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(
                                        RoundedRectangle(cornerRadius: 4)
                                            .fill(Color.accentColor.opacity(hoveredToken != nil ? 0.12 : 0))
                                    )
                                    .opacity(hoveredToken != nil ? 1 : 0)
                                    .frame(minHeight: 18)
                                    .animation(.easeInOut(duration: 0.15), value: hoveredToken)
                            }
                            LiveRowViewRepresentable(
                                inst: samplePreviewInstance(),
                                home: home,
                                paletteVersion: palette.version,
                                highlightedToken: hoveredToken,
                                onHoverToken: { t in hoveredToken = t }
                            )
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(minWidth: 360, alignment: .topLeading)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color(NSColor.windowBackgroundColor).opacity(0.6))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
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

                DisplaySizingSection()
                    .padding(.horizontal, 24)

                MenuBarBadgeSection()
                    .padding(.horizontal, 24)

                RefreshAndWarningsSection()
                    .padding(.horizontal, 24)

                RowVisibilitySection()
                    .padding(.horizontal, 24)

                KeybindsSection()
                    .padding(.horizontal, 24)

                Spacer(minLength: 24)
            }
            // Tap anywhere on the scroll background → resign focus from any
            // text field. Restricted to clicks on the empty area (the
            // contentShape of VStack doesn't extend to children's hit-tests,
            // so buttons / textfields still receive their own clicks).
            .contentShape(Rectangle())
            .onTapGesture { resignFirstResponder() }
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
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.accentColor)
                .opacity(isHovered ? 0.08 : 0)
                .animation(.easeInOut(duration: 0.15), value: isHovered)
        )
        .contentShape(Rectangle())
        .onHover { inside in
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

let appearancePrefKey = "appearance.mode"
func loadAppearancePref() -> AppearancePref {
    if let raw = UserDefaults.standard.string(forKey: appearancePrefKey),
       let p = AppearancePref(rawValue: raw) { return p }
    return .system
}
func applyAppearancePref(_ pref: AppearancePref) {
    NSApp.appearance = pref.nsAppearance
}

/// Settings → Display Sizing. A UI font-scale multiplier applied across the
/// menu's live-instance rows and the menu-bar chrome. Written to `ui.fontScale`;
/// BarFont + LiveRowView read it at render time, and `.menuBehaviorDidChange`
/// re-renders the open rows.
struct DisplaySizingSection: View {
    @AppStorage("ui.fontScale") private var fontScale: Double = 1.0

    private func postChange() {
        NotificationCenter.default.post(name: .menuBehaviorDidChange, object: nil)
    }

    var body: some View {
        OverviewSection(title: "Display Sizing",
                        icon: "textformat.size",
                        iconColor: .indigo) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Text("Font size")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 130, alignment: .leading)
                    Slider(value: $fontScale, in: 0.85...1.3, step: 0.05)
                        .frame(maxWidth: 220)
                        .onChange(of: fontScale) { _, _ in postChange() }
                    Text("\(Int(fontScale * 100))%")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.secondary)
                        .frame(width: 44, alignment: .trailing)
                    Spacer()
                }
                Text("Scales text across the menu's live-instance rows and the menu-bar chrome.")
                    .font(.system(size: 11)).foregroundColor(.secondary)
            }
            .padding(.vertical, 4)
        }
    }
}

/// Settings → Menu Bar Badge: whether the icon shows the live session count.
/// Read live by `updateButton()`.
struct MenuBarBadgeSection: View {
    @AppStorage("ui.badge.showCount")     private var showCount = true

    private func postChange() {
        NotificationCenter.default.post(name: .menuBehaviorDidChange, object: nil)
    }

    var body: some View {
        OverviewSection(title: "Menu Bar Badge",
                        icon: "menubar.rectangle",
                        iconColor: .orange) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Show live session count", isOn: $showCount)
                    .toggleStyle(.checkbox).onChange(of: showCount) { _, _ in postChange() }
            }
            .padding(.vertical, 4)
        }
    }
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
                Text("Affects this Settings window. The menu follows the system, and the hub pages have their own switch.")
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
/// UserDefaults AND posts `.menuBehaviorDidChange` so the bar's BarDelegate
/// can refresh open menus immediately. Adding more here is mechanical:
/// define a key, expose a control with `.onChange { _ in postChange() }`,
/// have the bar read it from the appropriate global accessor.
struct MenuBehaviorSection: View {
    @AppStorage("density") private var density: String = "comfortable"

    private func postChange() {
        NotificationCenter.default.post(name: .menuBehaviorDidChange, object: nil)
    }

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
                    .onChange(of: density) { _, _ in postChange() }
                    Text("Vertical gap between rows in the menu's live-instance card.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                    Spacer()
                }
            }
            .padding(.vertical, 4)
        }
    }
}

/// Settings → Refresh. Same UserDefaults keys as the menu's Refresh submenu,
/// so edits flow both ways; posts .menuBehaviorDidChange to restart the timer.
struct RefreshAndWarningsSection: View {
    @State private var cadence: Double
    @State private var paused: Bool

    init() {
        let raw = UserDefaults.standard.double(forKey: "scanRefreshInterval")
        _cadence   = State(initialValue: raw > 0 ? raw : 5.0)
        _paused    = State(initialValue: UserDefaults.standard.bool(forKey: "scanRefreshInterval.paused"))
    }

    private let presets: [Double] = [1, 2, 5, 10, 30, 60]

    var body: some View {
        OverviewSection(title: "Refresh & Warnings",
                        icon: "timer",
                        iconColor: .green) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Text("Scan cadence")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 130, alignment: .leading)
                    Picker("", selection: $cadence) {
                        ForEach(presets, id: \.self) { p in
                            Text(p < 1 ? String(format: "%.1fs", p) : "\(Int(p))s").tag(p)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 360)
                    .disabled(paused)
                    .onChange(of: cadence) { _, newVal in
                        UserDefaults.standard.set(newVal, forKey: "scanRefreshInterval")
                        NotificationCenter.default.post(name: .menuBehaviorDidChange, object: nil)
                    }
                    Spacer()
                }
                HStack(spacing: 12) {
                    Text("Paused")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 130, alignment: .leading)
                    Toggle("Stop auto-refresh entirely", isOn: $paused)
                        .toggleStyle(.checkbox)
                        .onChange(of: paused) { _, newVal in
                            UserDefaults.standard.set(newVal, forKey: "scanRefreshInterval.paused")
                            NotificationCenter.default.post(name: .menuBehaviorDidChange, object: nil)
                        }
                    Spacer()
                }
            }
            .padding(.vertical, 4)
        }
    }
}

/// Settings → Row Visibility. Toggle per non-critical line in the live
/// menu's instance card. Header + metrics are always shown (hiding either
/// makes the row useless). Lines flagged isSafetyRelevant get an extra
/// "safety" hint so users disabling them know what they're losing.
struct RowVisibilitySection: View {
    @State private var refreshTick = 0

    var body: some View {
        OverviewSection(title: "Row Visibility",
                        icon: "list.bullet.below.rectangle",
                        iconColor: .purple) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Toggle which lines appear in the live menu's instance card. The model badge + metrics row are always shown.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .padding(.bottom, 4)

                ForEach(RowElement.allCases) { el in
                    RowToggleRow(element: el, refreshTick: refreshTick) {
                        refreshTick &+= 1
                    }
                    Divider().opacity(0.4)
                }
            }
        }
    }
}

struct RowToggleRow: View {
    let element: RowElement
    let refreshTick: Int
    let onChange: () -> Void

    @State private var on: Bool

    init(element: RowElement, refreshTick: Int, onChange: @escaping () -> Void) {
        self.element = element
        self.refreshTick = refreshTick
        self.onChange = onChange
        _on = State(initialValue: rowShows(element))
    }

    var body: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: $on)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
                .onChange(of: on) { _, newVal in
                    setRowShows(element, newVal)
                    onChange()
                }

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(element.displayName)
                        .font(.system(size: 13, weight: .medium))
                    if element.isSafetyRelevant {
                        Text("safety")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color.red.opacity(0.18))
                            )
                            .foregroundColor(.red)
                    }
                }
                Text(element.hint)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .id(refreshTick)
    }
}

/// Section for the per-instance-submenu keybinds. Each row is one
/// SubmenuAction; the user types a single character to set the keybind,
/// presses backspace to clear (disables that action's shortcut), or
/// hits Reset to revert to the bundled default. Persists via the
/// keybindFor / setKeybind / resetKeybind helpers, which post
/// .menuBehaviorDidChange so the bar rebuilds the open menu with the
/// new bindings.
///
/// Wiring: LiveRowView's submenu construction reads keybindFor(.openInFinder)
/// etc. at build time. Changing a keybind here will be visible on the
/// next menu open.
struct KeybindsSection: View {
    @State private var refreshTick = 0  // bumped to force re-read after edits

    var body: some View {
        OverviewSection(title: "Keybinds",
                        icon: "command",
                        iconColor: .blue) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("ACTION").frame(width: 200, alignment: .leading)
                    Text("KEY").frame(width: 80, alignment: .leading)
                    Text("USAGE").frame(maxWidth: .infinity, alignment: .leading)
                    Text("").frame(width: 60, alignment: .trailing)
                }
                .font(.system(size: 10, weight: .bold))
                .tracking(0.8)
                .foregroundColor(.secondary)
                .padding(.horizontal, 4)

                ForEach(SubmenuAction.allCases) { action in
                    KeybindRow(action: action, refreshTick: refreshTick) {
                        refreshTick &+= 1
                    }
                    Divider().opacity(0.4)
                }

                HStack {
                    Text("Press a single character to set · Delete to clear (disable) · Reset to revert")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("Reset all") {
                        for a in SubmenuAction.allCases { resetKeybind(a) }
                        refreshTick &+= 1
                    }
                    .controlSize(.small)
                }
                .padding(.top, 4)
            }
        }
    }
}

/// One row of the keybinds table. The middle column is a TextField
/// bound to the action's persisted key — empty string disables, single
/// char sets the binding.
struct KeybindRow: View {
    let action: SubmenuAction
    let refreshTick: Int                 // bumped to force the View id to refresh
    let onChange: () -> Void

    @State private var draft: String
    @FocusState private var isFocused: Bool

    init(action: SubmenuAction, refreshTick: Int, onChange: @escaping () -> Void) {
        self.action = action
        self.refreshTick = refreshTick
        self.onChange = onChange
        _draft = State(initialValue: keybindFor(action))
    }

    private var isOverridden: Bool { keybindIsOverridden(action) }

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(action.displayName)
                    .font(.system(size: 13, weight: .medium))
                Text(action.rawValue)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            .frame(width: 200, alignment: .leading)

            // Single-character TextField with .plain style so we draw our
            // own border. .roundedBorder has the slow animated blue focus
            // ring that's overkill for a 1-char field AND doesn't dismiss
            // on outside click. The custom border path gives us both.
            TextField("", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: .monospaced))
                .frame(width: 56, height: 22)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 4)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(NSColor.controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(isFocused ? Color.accentColor : Color.secondary.opacity(0.25),
                                lineWidth: isFocused ? 1.5 : 1)
                )
                .focused($isFocused)
                .onChange(of: draft) { _, newVal in
                    let clamped = String(newVal.prefix(1)).lowercased()
                    if clamped != newVal { draft = clamped; return }
                    if clamped.isEmpty {
                        setKeybind(action, "")
                    } else {
                        setKeybind(action, clamped)
                    }
                    onChange()
                }
                .onSubmit { isFocused = false }

            Text(usageDescription(action))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button("Reset") {
                resetKeybind(action)
                draft = keybindFor(action)
                onChange()
            }
            .controlSize(.small)
            .disabled(!isOverridden)
            .frame(width: 60, alignment: .trailing)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 4)
        .id(refreshTick)
    }

    private func usageDescription(_ a: SubmenuAction) -> String {
        switch a {
        case .openInFinder:   return "Reveal the session's cwd in Finder."
        case .openInTerminal: return "Focus the Ghostty tab (or spawn one)."
        case .openInVSCode:   return "Open the cwd in VSCode."
        case .viewTranscript: return "Open the live HTML transcript viewer."
        case .copyPID:        return "Copy the session's PID to clipboard."
        case .terminate:      return "Send SIGTERM to the session."
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

struct OverviewSection<Content: View>: View {
    let title: String
    let icon: String
    let iconColor: Color
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(iconColor)
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(iconColor.opacity(0.12))
                    )
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
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

