// PolicyPanel.swift
// The agent-policy panel: a second menu bar icon whose popover lists every
// policy in ~/.claude/policy/registry.json with the control its type asks for
// (switch, segmented choice, menu, slider), a scope picker for per-repo
// overrides, and a timed flip ("snooze") on any switch or choice.
//
// Layout follows conventions/visual-design.md: weight and spacing carry the
// hierarchy, one type scale, colour only where it means something (a blocked
// action, a pending flip, a changed value).

import AppKit
import SwiftUI

// ── Type and spacing, one place ─────────────────────────────────────────────

enum PT {
    static let title   = Font.system(size: 14, weight: .semibold)
    static let label   = Font.system(size: 12.5)
    static let caption = Font.system(size: 11)
    static let section = Font.system(size: 10, weight: .semibold)
    static let mono    = Font.system(size: 11.5, weight: .medium).monospacedDigit()
    static let rowV: CGFloat = 5.5
    static let rowH: CGFloat = 12
    static let gap: CGFloat = 12
    /// Wide enough for the longest label with a legacy (mouse) scrollbar showing.
    static let width: CGFloat = 424
    /// As tall as the screen allows, so the whole list usually fits unscrolled.
    static var maxHeight: CGFloat {
        let h = NSScreen.main?.visibleFrame.height ?? 800
        return max(360, min(h - 150, 980))
    }
    static let control: CGFloat = 160
    static let segment: CGFloat = 52
    static let slider: CGFloat = 108
}

private let blockedTint = Color(nsColor: .systemRed)
private let snoozeTint = Color(nsColor: .systemTeal)
private let changedTint = Color(nsColor: .systemOrange)

// ── The panel ───────────────────────────────────────────────────────────────

private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// One concern the Switchboard shows, as a tab. Adding a concern is one new
/// file (a store and a view) plus one entry in `SwitchboardConcerns.all`.
struct SwitchboardConcern: Identifiable {
    let id: String
    let title: String          // the tab label
    let subtitle: String       // the line under "Switchboard"
    let icon: String           // SF Symbol for the tab and subtitle
    let footer: String
    let footerIcon: String
    let content: AnyView
    /// Runs when the panel opens and on the footer's reload button.
    var refresh: () -> Void = {}
}

/// The registry: every concern, in tab order.
enum SwitchboardConcerns {
    static func all(policy: PolicyStore, usage: UsageStore, lights: LightsStore) -> [SwitchboardConcern] {
        [
            SwitchboardConcern(id: "agents", title: "Agents", subtitle: "What agents may do", icon: "person.badge.shield.checkmark",
                               footer: "Applies to every session at once. Only you can change it.", footerIcon: "bolt.fill",
                               content: AnyView(AgentsTabView(store: policy)),
                               refresh: { policy.reload() }),
            SwitchboardConcern(id: "usage", title: "Usage", subtitle: "Claude and Codex limits", icon: "gauge.with.dots.needle.67percent",
                               footer: "Bars mark the thresholds that act on them.", footerIcon: "line.diagonal",
                               content: AnyView(UsageTabView(usage: usage, policy: policy)),
                               refresh: { usage.reload() }),
            SwitchboardConcern(id: "system", title: "Machine", subtitle: "This Mac's switches", icon: "desktopcomputer",
                               footer: "The timer icon flips a switch for a while.", footerIcon: "timer",
                               content: AnyView(SystemTabView(store: policy)),
                               refresh: { policy.requestSystemRefresh() }),
            SwitchboardConcern(id: "home", title: "Home", subtitle: "Your home network", icon: "house",
                               footer: "Talks to the bulbs directly over the LAN.", footerIcon: "wifi",
                               content: AnyView(LightsTabView(lights: lights)),
                               refresh: { lights.discover() }),
        ]
    }
}

struct PolicyPanel: View {
    let concerns: [SwitchboardConcern]
    /// Fixed-height rendering for snapshots, where a ScrollView would clip.
    var unbounded = false
    /// Pins a tab for snapshots; nil follows the owner's last choice.
    var forcedTab: String? = nil
    @State private var contentHeight: CGFloat = 0
    @AppStorage("policyPanel.tab") private var storedTab = "agents"

    private var current: SwitchboardConcern {
        let id = forcedTab ?? storedTab
        return concerns.first { $0.id == id } ?? concerns[0]
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if unbounded {
                current.content
            } else {
                // Sized to the content, up to the screen cap, so a short tab
                // does not leave the popover padded with space.
                ScrollView(.vertical, showsIndicators: true) {
                    current.content.background(GeometryReader { g in
                        Color.clear.preference(key: ContentHeightKey.self, value: g.size.height)
                    })
                }
                .frame(height: min(max(contentHeight, 120), PT.maxHeight))
                .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }
            }
            Divider()
            footer
        }
        .frame(width: PT.width)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Switchboard", systemImage: "slider.vertical.3").font(PT.title)
                Spacer(minLength: 8)
                Text(current.subtitle).font(PT.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            headerTop
        }
        .padding(.horizontal, PT.gap)
        .padding(.vertical, 10)
    }

    private var headerTop: some View {
        HStack(spacing: 0) {
            // A drawn tab bar: the native segmented control drops a label's icon on macOS.
            HStack(spacing: 2) {
                ForEach(concerns) { c in
                    let on = c.id == current.id
                    Button {
                        storedTab = c.id
                        c.refresh()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: c.icon).font(.system(size: 10.5))
                            Text(c.title).font(.system(size: 11.5, weight: on ? .semibold : .regular))
                                .lineLimit(1).fixedSize()
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                        .foregroundStyle(on ? Color.white : Color.primary.opacity(0.75))
                        .background(RoundedRectangle(cornerRadius: 5).fill(on ? Color.accentColor : .clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(c.subtitle)
                }
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.07)))
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: current.footerIcon).font(.system(size: 9)).foregroundStyle(.secondary)
            Text(current.footer).font(PT.caption).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Button { current.refresh() } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .help("Reload this tab")
        }
        .padding(.horizontal, PT.gap)
        .padding(.vertical, 8)
    }
}

// ── The Agents concern: the policy store, with its scope picker ────────────

struct AgentsTabView: View {
    @ObservedObject var store: PolicyStore

    var body: some View {
        VStack(alignment: .leading, spacing: PT.gap) {
            HStack(spacing: 6) {
                Text("Applies to").font(PT.caption).foregroundStyle(.secondary)
                scopeMenu
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
            if let e = store.error {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(blockedTint)
                    Text(e).font(PT.caption).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 4)
            }
            if store.scopeIsProject, case .project(let root) = store.scope {
                Text("Overrides for \(abbreviate(root)). A row with no override follows the Everywhere value.")
                    .font(PT.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
            if store.items.isEmpty && store.error == nil {
                Text("Loading…").font(PT.caption).foregroundStyle(.secondary).padding(.horizontal, 4)
            }
            // Usage thresholds (the *_pct limits) live on the Usage tab, next
            // to the bars they act on.
            ForEach(store.groups, id: \.name) { g in
                let items = g.items.filter { !($0.group == "Limits" && $0.key.hasSuffix("_pct")) }
                if !items.isEmpty { PolicyGroupView(name: g.name, items: items, store: store) }
            }
        }
        .padding(PT.gap)
    }

    @State private var showScopes = false

    // A list, not a native menu: menus cannot draw a two-line item or hold a
    // button inside an item, and each project row wants both.
    private var scopeMenu: some View {
        Button { showScopes.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: store.scopeIsProject ? "folder" : "globe")
                Text(store.scope.title)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .font(PT.caption)
        }
        .buttonStyle(.borderless)
        .help("Where a change applies: everywhere, or one repository's override")
        .popover(isPresented: $showScopes, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(store.scopes, id: \.self) { s in ScopeRow(scope: s, selected: s == store.scope) {
                    store.scope = s
                    store.reload()
                    showScopes = false
                } }
            }
            .padding(6)
            .frame(width: 300)
        }
    }
}

/// One scope in the picker: name over its dimmed path, with a folder button.
private struct ScopeRow: View {
    let scope: PolicyScope
    let selected: Bool
    let pick: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if selected { Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)) }
                else { Color.clear }
            }
            .frame(width: 12, height: 12)
            .foregroundStyle(Color.accentColor)
            Image(systemName: isGlobal ? "globe" : "folder.fill")
                .font(.system(size: 12))
                .foregroundStyle(isGlobal ? Color.secondary : Color.accentColor.opacity(0.8))
            VStack(alignment: .leading, spacing: 1) {
                Text(scope.title).font(PT.label).lineLimit(1)
                Text(subtitle).font(.system(size: 10.5)).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if case .project(let root) = scope {
                Button { NSWorkspace.shared.open(URL(fileURLWithPath: root)) } label: {
                    Image(systemName: "arrow.up.forward.app").font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Open \(abbreviate(root)) in Finder")
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 5).fill(hover ? Color.primary.opacity(0.08) : .clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: pick)
    }

    private var isGlobal: Bool { if case .global = scope { return true }; return false }
    private var subtitle: String {
        switch scope {
        case .global: return "All projects, unless one overrides"
        case .project(let root): return abbreviate(root)
        }
    }
}

// ── The Machine concern: the bar's system switches ─────────────────────────

struct SystemTabView: View {
    @ObservedObject var store: PolicyStore

    var body: some View {
        VStack(alignment: .leading, spacing: PT.gap) {
            if store.systemGroups.isEmpty {
                Text("Loading…").font(PT.caption).foregroundStyle(.secondary).padding(.horizontal, 4)
            }
            ForEach(store.systemGroups) { g in
                VStack(alignment: .leading, spacing: 5) {
                    GroupHeader(name: g.title)
                    Card {
                        ForEach(Array(g.rows.enumerated()), id: \.element.id) { i, row in
                            if i > 0 { Divider().padding(.leading, PT.rowH) }
                            SystemRowView(row: row, store: store)
                        }
                    }
                }
            }
        }
        .padding(PT.gap)
    }
}

// ── One group: a tracked header over a rounded card of rows ────────────────

private struct PolicyGroupView: View {
    let name: String
    let items: [PolicyItem]
    @ObservedObject var store: PolicyStore

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            GroupHeader(name: name)
            Card {
                ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                    if i > 0 { Divider().padding(.leading, PT.rowH) }
                    PolicyRowView(item: item, store: store)
                }
            }
        }
    }
}

// ── Shared chrome: the tracked group label and the rounded card ────────────

struct GroupHeader: View {
    let name: String
    var body: some View {
        HStack(spacing: 5) {
            if let icon = Self.icons[name] {
                Image(systemName: icon).font(.system(size: 9.5, weight: .semibold))
            }
            Text(name.uppercased()).font(PT.section).tracking(0.7)
        }
        .foregroundStyle(.secondary)
        .padding(.leading, 4)
    }

    /// One symbol per group, named for what the group holds.
    static let icons: [String: String] = [
        "Acting as you": "person.wave.2",
        "Code": "chevron.left.forwardslash.chevron.right",
        "Deploy": "icloud.and.arrow.up",
        "Models": "cpu",
        "Machine": "desktopcomputer",
        "Limits": "gauge.with.dots.needle.33percent",
        "Gates": "checkmark.shield",
        "Guards": "shield.lefthalf.filled",
        "Services": "server.rack",
        "Schedules": "calendar.badge.clock",
        "Session": "cup.and.saucer",
        "Feed": "arrow.triangle.2.circlepath",
        "Claude": "sparkle",
        "Codex": "terminal",
        "What acts on these numbers": "slider.horizontal.3",
        "Lights": "lightbulb.led",
    ]
}

struct Card<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.045)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.08)))
    }
}

// ── A system row: the dropdown Switchboard's row, as a panel row ───────────

private struct SystemRowView: View {
    let row: SystemRow
    @ObservedObject var store: PolicyStore
    @State private var picking = false
    @State private var pickedTime = SystemRowView.defaultPick()

    var body: some View {
        VStack(spacing: 0) {
            mainLine
            if picking, let key = row.timerKey { timePicker(key) }
        }
    }

    private var mainLine: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.label).font(PT.label).lineLimit(1)
                    .foregroundStyle(row.enabled || !row.isSwitch ? .primary : .secondary)
                if let t = row.timer, let key = row.timerKey {
                    HStack(spacing: 4) {
                        Text("→ \(t.restoreOn ? "On" : "Off") in \(countdown(to: t.until, now: store.now))")
                            .lineLimit(1)
                        Button { store.cancelSystemTimer(key) } label: {
                            Image(systemName: "xmark.circle.fill").font(.system(size: 10))
                        }
                        .buttonStyle(.borderless)
                        .help("Cancel the timer and keep the current state")
                    }
                    .font(PT.caption).foregroundStyle(snoozeTint)
                } else if !row.note.isEmpty {
                    Text(row.note).font(PT.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            if let key = row.timerKey { timerMenu(key).frame(width: 18) }
            if let link = row.link, let url = URL(string: link) {
                Button { NSWorkspace.shared.open(url) } label: {
                    Image(systemName: "arrow.up.right.square").font(.system(size: 12))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Open \(link)")
            }
            control.frame(minWidth: 44, alignment: .trailing)
        }
        .padding(.horizontal, PT.rowH)
        .padding(.vertical, PT.rowV)
        .contentShape(Rectangle())
        .help(row.tip)
    }

    // ── Timers: flip now, flip back later ──

    private static func defaultPick() -> Date {
        // An hour from now, on the next quarter hour: a sensible first guess.
        let t = Date().addingTimeInterval(3600)
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: t)
        var r = c; r.minute = ((c.minute ?? 0) / 15) * 15
        return Calendar.current.date(from: r) ?? t
    }

    private func timerMenu(_ key: String) -> some View {
        let verb = row.isOn ? "Off" : "On"
        let active = row.timer != nil
        return Menu {
            Section(active ? "Change the timer" : "\(verb) for a while") {
                Button("\(verb) for 30 minutes") { start(key, 30 * 60) }
                Button("\(verb) for 1 hour") { start(key, 3600) }
                Button("\(verb) for 2 hours") { start(key, 2 * 3600) }
                Button("\(verb) for 4 hours") { start(key, 4 * 3600) }
                Button("\(verb) for 2 days") { start(key, 2 * 86400) }
                Button("\(verb) for 3 days") { start(key, 3 * 86400) }
                Button("\(verb) until the end of today") {
                    if let end = Calendar.current.date(bySettingHour: 23, minute: 59, second: 0, of: Date()) {
                        store.startSystemTimer(key, end)
                    }
                }
                Button("\(verb) until a time…") { pickedTime = Self.defaultPick(); picking = true }
            }
            if active {
                Divider()
                Button("End now") { store.endSystemTimerNow(key) }
                Button("Cancel the timer") { store.cancelSystemTimer(key) }
            }
        } label: {
            Image(systemName: active ? "timer.circle.fill" : "timer")
                .font(.system(size: 11))
                .foregroundStyle(active ? AnyShapeStyle(snoozeTint) : AnyShapeStyle(.tertiary))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(row.isOn ? "Turn this off for a while" : "Turn this on for a while")
    }

    private func start(_ key: String, _ seconds: TimeInterval) {
        store.startSystemTimer(key, Date().addingTimeInterval(seconds))
    }

    /// "Until 6:30 PM": a time earlier than now means tomorrow.
    private func timePicker(_ key: String) -> some View {
        HStack(spacing: 8) {
            Text("\(row.isOn ? "Off" : "On") until").font(PT.caption).foregroundStyle(.secondary)
            DatePicker("", selection: $pickedTime, displayedComponents: .hourAndMinute)
                .labelsHidden()
                .datePickerStyle(.stepperField)
                .controlSize(.small)
            Spacer(minLength: 0)
            Button("Cancel") { picking = false }
                .controlSize(.small)
            Button("Start") {
                var until = pickedTime
                if until <= Date() { until = Calendar.current.date(byAdding: .day, value: 1, to: until) ?? until }
                store.startSystemTimer(key, until)
                picking = false
            }
            .controlSize(.small)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, PT.rowH)
        .padding(.bottom, PT.rowV + 2)
    }

    @ViewBuilder private var control: some View {
        if let choices = row.choices {
            Picker("", selection: Binding(get: { row.selected }, set: { row.onChoose?($0) })) {
                ForEach(Array(choices.enumerated()), id: \.offset) { i, c in Text(c).tag(i) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
            .disabled(!row.enabled)
        } else if row.isSwitch {
            Toggle("", isOn: Binding(get: { row.isOn }, set: { _ in row.action?() }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .disabled(!row.enabled)
        } else if let menu = row.menu {
            // The dropdown's own drill-down menu, popped where the click was.
            Button {
                menu().popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
            } label: {
                HStack(spacing: 4) {
                    StateBadge(state: row.state)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
        } else if let action = row.action, row.enabled {
            Button(action: action) { StateBadge(state: row.state) }
                .buttonStyle(.plain)
        } else {
            StateBadge(state: row.state)
        }
    }
}

/// The dropdown's pill: filled and tinted when engaged, hollow when not.
private struct StateBadge: View {
    let state: SystemRow.State

    private var text: String {
        switch state {
        case .on: return "on"
        case .off: return "off"
        case .count(let n, _): return "\(n)"
        case .ok: return "ok"
        }
    }
    private var tint: NSColor? {
        switch state {
        case .on(let c), .count(_, let c): return c
        case .off, .ok: return nil
        }
    }

    var body: some View {
        let label = Text(text).font(.system(size: 10, weight: .semibold).monospacedDigit())
            .padding(.horizontal, 7).padding(.vertical, 1.5)
        if let t = tint {
            label.foregroundStyle(Color(nsColor: t))
                .background(Capsule().fill(Color(nsColor: t).opacity(0.18)))
        } else {
            label.foregroundStyle(.secondary)
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.2)))
        }
    }
}

// ── One row: label and state on the left, the control on the right ─────────

struct PolicyRowView: View {
    let item: PolicyItem
    @ObservedObject var store: PolicyStore
    @State private var draft: Double = 0
    @State private var dragging = false

    private var busy: Bool { store.busyKey == item.key }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(item.label).font(PT.label).lineLimit(1)
                    if !item.isDefault {
                        Circle().fill(changedTint).frame(width: 5, height: 5)
                            .help("Changed from the default (\(item.defaultValue.cli))")
                    }
                }
                caption
            }
            Spacer(minLength: 6)
            // Fixed columns: the clock and the control line up down the whole
            // panel whatever each control's own width is.
            snoozeMenu
                .frame(width: 18, alignment: .center)
            control
                .disabled(busy)
                .opacity(busy ? 0.5 : 1)
                .frame(width: PT.control, alignment: .trailing)
        }
        .padding(.horizontal, PT.rowH)
        .padding(.vertical, PT.rowV)
        .contentShape(Rectangle())
        .help(item.help)
    }

    // What sits under the label: a pending flip, an override, or nothing.
    @ViewBuilder private var caption: some View {
        if let z = item.snooze, !z.expired {
            HStack(spacing: 4) {
                Text("→ \(word(z.then)) in \(countdown(to: z.until, now: store.now))")
                    .lineLimit(1)
                Button { store.cancelSnooze(item) } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 10))
                }
                .buttonStyle(.borderless)
                .help("Cancel the timed change and keep the current value")
            }
            .font(PT.caption).foregroundStyle(snoozeTint)
        } else if store.scopeIsProject {
            if item.source == "project" {
                resettable("Everywhere is \(word(item.globalValue ?? item.defaultValue))")
            } else {
                Text("Follows Everywhere").font(PT.caption).foregroundStyle(.tertiary)
            }
        } else if store.hasOwnValue(item) && !item.isDefault {
            resettable("Default is \(word(item.defaultValue))")
        }
    }

    private func resettable(_ text: String) -> some View {
        HStack(spacing: 4) {
            Text(text).font(PT.caption).foregroundStyle(.secondary)
            Button { store.reset(item) } label: {
                Image(systemName: "arrow.uturn.backward").font(.system(size: 9, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help(store.scopeIsProject ? "Remove this repo's override" : "Back to the default")
        }
    }

    // ── The control, chosen by the policy's declared type ──

    @ViewBuilder private var control: some View {
        switch item.kind {
        case .toggle:
            let allowed = item.value == .text("allow")
            HStack(spacing: 8) {
                Text(allowed ? "Allowed" : "Blocked")
                    .font(PT.caption)
                    .foregroundStyle(allowed ? AnyShapeStyle(.secondary) : AnyShapeStyle(blockedTint))
                Toggle("", isOn: Binding(
                    get: { allowed },
                    set: { store.set(item, .text($0 ? "allow" : "block")) }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }
        case .segmented(let opts):
            Picker("", selection: Binding(
                get: { item.value.cli },
                set: { store.set(item, .text($0)) })) {
                ForEach(opts, id: \.self) { Text(word(.text($0))).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .frame(width: CGFloat(max(2, opts.count)) * PT.segment)
        case .menu(let opts):
            Picker("", selection: Binding(
                get: { item.value.cli },
                set: { store.set(item, .text($0)) })) {
                ForEach(opts, id: \.self) { Text(word(.text($0))).tag($0) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
        case .slider(let lo, let hi, let step, let unit):
            HStack(spacing: 8) {
                // Snapped by hand rather than with `step:`, which draws a tick
                // mark per step and turns a 50-100 range into a row of dots.
                Slider(value: Binding(
                    get: { dragging ? draft : numeric(item.value) },
                    set: { draft = (($0 - lo) / step).rounded() * step + lo }),
                       in: lo...hi,
                       onEditingChanged: { editing in
                           if editing { draft = numeric(item.value); dragging = true }
                           else { dragging = false; store.set(item, .number(draft)) }
                       })
                    .controlSize(.small)
                    .frame(width: PT.slider)
                Text("\(Int(dragging ? draft : numeric(item.value)))\(unit)")
                    .font(PT.mono)
                    .frame(width: 36, alignment: .trailing)
            }
        }
    }

    // ── Timed flip: switch to another value later, keep this one until then ──

    @ViewBuilder private var snoozeMenu: some View {
        let targets = item.options.filter { $0 != item.value }
        if !targets.isEmpty {
            let active = item.snooze.map { !$0.expired } ?? false
            Menu {
                ForEach(targets, id: \.self) { t in
                    Section("Switch to \(word(t))") {
                        Button("in 1 hour") { store.snooze(item, seconds: 3600, then: t) }
                        Button("in 4 hours") { store.snooze(item, seconds: 4 * 3600, then: t) }
                        Button("at the end of today") { store.snoozeTonight(item, then: t) }
                        Button("in 1 day") { store.snooze(item, seconds: 86400, then: t) }
                        Button("in 2 days") { store.snooze(item, seconds: 2 * 86400, then: t) }
                        Button("in 3 days") { store.snooze(item, seconds: 3 * 86400, then: t) }
                        Button("in 7 days") { store.snooze(item, seconds: 7 * 86400, then: t) }
                    }
                }
                if active {
                    Divider()
                    Button("Cancel the timed change") { store.cancelSnooze(item) }
                }
            } label: {
                // A plain-styled menu keeps the icon's own colour; the borderless
                // style repaints its label and loses the "pending" tint.
                Image(systemName: active ? "clock.fill" : "clock")
                    .font(.system(size: 11))
                    .foregroundStyle(active ? AnyShapeStyle(snoozeTint) : AnyShapeStyle(.tertiary))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Change this later, keeping the current value until then")
        }
    }
}

// ── Small formatting helpers ────────────────────────────────────────────────

private func numeric(_ v: PolicyValue) -> Double {
    if case .number(let d) = v { return d }
    return 0
}

/// The word a person reads for a stored value.
private func word(_ v: PolicyValue) -> String {
    switch v {
    case .number: return v.cli
    case .text(let s):
        switch s {
        case "allow": return "Allow"
        case "block": return "Block"
        case "ask": return "Ask"
        case "warn": return "Warn"
        case "off": return "Off"
        case "enforce": return "Enforce"
        case "encourage": return "Prefer"
        default: return s.prefix(1).uppercased() + s.dropFirst()
        }
    }
}

// The panel's shared look, under the names other tabs (Usage, Home) use.
typealias SBStyle = PT
typealias SBGroupHeader = GroupHeader
typealias SBCard = Card
func countdownText(to date: Date, now: Date) -> String { countdown(to: date, now: now) }

private func countdown(to date: Date, now: Date) -> String {
    let s = Int(date.timeIntervalSince(now))
    if s < 60 { return "under a minute" }
    let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
    if d > 0 { return h > 0 ? "\(d)d \(h)h" : "\(d)d" }
    if h > 0 { return m > 0 ? "\(h)h \(m)m" : "\(h)h" }
    return "\(m)m"
}

private func abbreviate(_ path: String) -> String {
    let home = NSHomeDirectory()
    return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
}

// ── The menu bar icon that opens the panel ─────────────────────────────────

final class PolicyStatusController: NSObject, NSPopoverDelegate {
    let store = PolicyStore()
    let usage = UsageStore()
    let lights = LightsStore()
    private var concerns: [SwitchboardConcern] = []
    private let item: NSStatusItem
    private let popover = NSPopover()
    private var ticker: Timer?

    init(liveDirs: @escaping () -> [String], requestSystemRefresh: @escaping () -> Void) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        item.autosaveName = "gcc-agent-policy"
        store.liveDirs = liveDirs
        store.requestSystemRefresh = requestSystemRefresh
        if let b = item.button {
            b.image = switchboardGlyph()
            b.toolTip = "Switchboard: agent policy and system switches"
            b.target = self
            b.action = #selector(toggle(_:))
        }
        concerns = SwitchboardConcerns.all(policy: store, usage: usage, lights: lights)
        let host = NSHostingController(rootView: PolicyPanel(concerns: concerns))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        // Pay the first-open costs now, not on the owner's click: load the
        // values and lay out the view once while nobody is waiting.
        store.reload()
        usage.reload()
        host.view.layoutSubtreeIfNeeded()

        // Lets a script or hotkey tool open or close the panel without a click.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("dev.claude-instances.toggle-policy"),
            object: nil, queue: .main) { [weak self] _ in self?.toggle(nil) }
    }

    @objc private func toggle(_ sender: Any?) {
        if popover.isShown { popover.performClose(sender); return }
        show()
    }

    func show() {
        // Open at once on what is already loaded, then refresh underneath. The
        // values rarely change between opens, and waiting for pol.sh first is
        // what made the click feel slow.
        guard let b = item.button, !popover.isShown else { return }
        let t0 = Date()
        popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        dlog("policy panel shown in \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
        // Every concern refreshes on open: each is cheap or runs in the
        // background (a Codex re-ask only when its cache is stale).
        store.reload()
        concerns.forEach { $0.refresh() }
        // Keep countdowns honest while open, and pick up changes made elsewhere.
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.store.reload()
            self?.usage.loadClaude()
        }
    }

    func popoverDidClose(_ notification: Notification) {
        ticker?.invalidate()
        ticker = nil
    }
}

// ── The menu bar glyph ─────────────────────────────────────────────────────

/// A bank of three vertical faders: a mixing desk, which reads as "switches
/// and levels" and stays clearly apart from Control Center's stacked toggles.
/// An SF Symbol, so it is hinted for the menu bar at 1x and 2x alike.
func switchboardGlyph() -> NSImage {
    let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
    let img = NSImage(systemSymbolName: "slider.vertical.3", accessibilityDescription: "Switchboard")?
        .withSymbolConfiguration(cfg) ?? NSImage()
    img.isTemplate = true
    return img
}

// ── Headless: render the panel to a PNG, in a chosen appearance and scope ──

/// Draws the real panel offscreen, so it can be checked in dark and light
/// without opening anything on the owner's screen. Returns false on failure.
@discardableResult
func snapshotPolicyPanel(to path: String, dark: Bool, scopeDir: String?,
                         tab: String = "agents", system: [SystemGroup] = []) -> Bool {
    let store = PolicyStore()
    if let d = scopeDir, let root = PolicyCLI.root(of: d) { store.scope = .project(root) }
    let r = PolicyCLI.load(store.scope)
    store.applyForSnapshot(items: r.items, projects: r.projects, error: r.error)
    store.systemGroups = system
    let usage = UsageStore()
    let lights = LightsStore()
    if tab == "usage" {
        // The Codex reading comes from the gate's own cache or a live ask.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", UsageStore.codexGate, "--json"]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        var codex: [String: Any]?
        if (try? p.run()) != nil {
            let s = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            p.waitUntilExit()
            if let end = s.range(of: "\n}", options: .backwards) {
                codex = try? JSONSerialization.jsonObject(with: Data(s[s.startIndex..<end.upperBound].utf8)) as? [String: Any]
            }
        }
        usage.loadForSnapshot(codexJSON: codex)
    }
    if tab == "home" { lights.loadForSnapshot() }
    let concerns = SwitchboardConcerns.all(policy: store, usage: usage, lights: lights)

    let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
    // "scopes" renders the scope picker's list on its own; a popover cannot be
    // drawn offscreen, so this is how its rows get checked.
    let root: AnyView = tab == "scopes"
        ? AnyView(VStack(alignment: .leading, spacing: 0) {
              ForEach(store.scopes, id: \.self) { s in ScopeRow(scope: s, selected: s == store.scope) {} }
          }.padding(6).frame(width: 300))
        : AnyView(PolicyPanel(concerns: concerns, unbounded: true, forcedTab: tab))
    let host = NSHostingView(rootView: root.background(Color(nsColor: .windowBackgroundColor)))
    host.appearance = appearance
    host.safeAreaRegions = []
    let size = host.fittingSize
    host.frame = NSRect(origin: .zero, size: size)
    let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    win.appearance = appearance
    win.backgroundColor = .windowBackgroundColor
    win.contentView = host
    host.layoutSubtreeIfNeeded()
    host.displayIfNeeded()
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return false }
    host.cacheDisplay(in: host.bounds, to: rep)
    guard let png = rep.representation(using: .png, properties: [:]) else { return false }
    return (try? png.write(to: URL(fileURLWithPath: path))) != nil
}
