// Dashboard.swift
// SwiftUI dashboard: panel, tabs, settings, and their helpers.
// (split from claude-instances-bar.swift — one module, same binary)

import AppKit
import Foundation
import SwiftUI

struct TranscriptServer: Identifiable, Equatable {
    let pid: Int            // Claude PID
    let port: Int           // localhost port
    let serverPid: Int      // python process PID
    let logPath: String

    var id: Int { pid }
}

final class DashboardData: ObservableObject {
    @Published var data: ScanResult?
    @Published var allSessions: [FullSession]?
    @Published var isLoadingAllSessions = false
    @Published var transcriptServers: [TranscriptServer] = []

    /// Re-scan /tmp for transcript-server PID files and verify each.
    /// Called every dashboard tick + on demand after the user clicks Kill.
    func refreshTranscriptServers() {
        let tmp = "/tmp"
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: tmp) else {
            DispatchQueue.main.async { self.transcriptServers = [] }
            return
        }
        let pattern = try? NSRegularExpression(pattern: #"^claude-widget-(\d+)\.server$"#)
        var found: [TranscriptServer] = []
        for name in contents {
            guard let re = pattern,
                  let m = re.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
                  let pidRange = Range(m.range(at: 1), in: name),
                  let claudePid = Int(name[pidRange])
            else { continue }
            let pidFile = "\(tmp)/\(name)"
            guard let raw = try? String(contentsOfFile: pidFile, encoding: .utf8),
                  let srvPid = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
                  kill(Int32(srvPid), 0) == 0
            else {
                // Stale file — remove.
                try? fm.removeItem(atPath: pidFile)
                continue
            }
            let port = 5400 + (claudePid % 500)
            found.append(TranscriptServer(
                pid: claudePid, port: port, serverPid: srvPid,
                logPath: "/tmp/claude-widget-\(claudePid).server.log"
            ))
        }
        DispatchQueue.main.async {
            if self.transcriptServers != found {
                self.transcriptServers = found
            }
        }
    }

    /// Send SIGTERM to the named transcript server's python process. The
    /// python's signal handler removes the PID file on exit, but we also
    /// proactively remove it here for fast UI feedback.
    func killTranscriptServer(_ srv: TranscriptServer) {
        kill(Int32(srv.serverPid), SIGTERM)
        let pidFile = "/tmp/claude-widget-\(srv.pid).server"
        try? FileManager.default.removeItem(atPath: pidFile)
        refreshTranscriptServers()
    }

    func killAllTranscriptServers() {
        for srv in transcriptServers { killTranscriptServer(srv) }
    }

    /// Cheap signature comparison so we don't trigger a SwiftUI tree
    /// re-render every 5s when no field actually changed. ScanResult itself
    /// isn't Equatable (a lot of nested types) but a tuple of "the bits the
    /// UI cares about" is good enough — false positives just mean an extra
    /// render, never a missed update.
    private var lastSignature: String = ""
    private static func signature(_ r: ScanResult?) -> String {
        guard let r = r else { return "" }
        let liveSig = r.live.map { inst -> String in
            "\(inst.pid):\(inst.turns ?? 0):\(inst.outputTokens ?? 0):\(inst.costUsd ?? 0):\(inst.sessionState?.state ?? "")"
        }.joined(separator: "|")
        let limSig  = r.limits.map { "\($0.fiveH?.pct ?? 0):\($0.week?.pct ?? 0)" } ?? ""
        return "\(liveSig)#\(limSig)#\(r.history.count)"
    }

    func update(_ newData: ScanResult?) {
        let sig = Self.signature(newData)
        DispatchQueue.main.async {
            // Skip publishing when nothing the UI cares about changed —
            // SwiftUI's diffing is cheap but not free for ~7 tabs of views,
            // and the 5s refreshTimer was triggering a full tree re-render
            // every tick even when data was static.
            if sig == self.lastSignature { return }
            self.lastSignature = sig
            self.data = newData
        }
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

// MARK: - ▼▼▼ DashboardKit — reusable scaffolding ▼▼▼ ────────────────────────
//
// The block between this banner and the matching ▲▲▲ banner is intentionally
// generic. It's the "shell" of the dashboard window — controller, sidebar,
// section containers, stat cards — designed so another macOS app can copy it
// out and adapt to its own data.
//
// See docs/dashboard-kit.md for: what's in the kit, what's app-specific,
// the contract another app needs to satisfy, and a minimal "Hello World"
// example.
//
// What's reusable:
//   - DashboardController       — NSPanel + NSHostingView lifecycle
//   - DashboardTab              — enum of tabs (replace cases for your app)
//   - SidebarButton             — sidebar nav item
//   - DashboardRootView         — NavigationSplitView shell with sidebar
//   - OverviewSection<Content>  — generic section container with icon header
//   - StatCard                  — labeled stat box
//   - AggregateMetric           — bigger stat tile
//   - MetadataItem              — key/value pair
//   - Color helpers + palette glue (PaletteStore is project-specific but the
//     pattern transfers)
//
// What's NOT reusable (project-specific concerns):
//   - The contents of each tab (OverviewTabView, LiveTabView, etc.) — they
//     reference Claude-specific data structures
//   - DashboardData (the @Published wrapper) — Claude session shape
//   - Action callbacks (onFocus, onResume, etc.) — Claude/Ghostty-specific
//
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
        dataSource.refreshTranscriptServers()

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
            self.dataSource.refreshTranscriptServers()
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
        }, onOpenTranscript: { _, sessionId in
            // Open the live transcript through the session hub.
            openHubTranscript(sessionId: sessionId)
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
    case settings    = "Settings"
    case about       = "About"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .overview:    return "square.grid.2x2.fill"
        case .live:        return "sparkles"
        case .history:     return "clock.arrow.circlepath"
        case .events:      return "list.bullet"
        case .allSessions: return "tray.full.fill"
        case .settings:    return "slider.horizontal.3"
        case .about:       return "info.circle"
        }
    }

    var section: String {
        switch self {
        case .overview, .live:          return "Dashboard"
        case .history, .events:         return "Details"
        case .allSessions:              return "Details"
        case .settings, .about:         return "Help"
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
        case .settings:    return .gray
        case .about:       return .secondary
        }
    }
}

struct DashboardRootView: View {
    @ObservedObject var dataSource: DashboardData
    @State private var selectedTab: DashboardTab = {
        // Honor user's "Default tab" preference from Settings → Menu Behavior.
        // Fall back to .overview when unset or unrecognized.
        if let raw = UserDefaults.standard.string(forKey: "defaultTab"),
           let tab = DashboardTab(rawValue: raw) {
            return tab
        }
        return .overview
    }()

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

                // Transcript-server status — visible iff any are running.
                // Click the × button to kill them all. Sits directly above
                // the live-count row so the two "ambient runtime signals"
                // cluster together.
                if !dataSource.transcriptServers.isEmpty {
                    let n = dataSource.transcriptServers.count
                    HStack(spacing: 6) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.teal)
                        Text("\(n) transcript\(n == 1 ? "" : "s")")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)
                        Spacer()
                        Button {
                            dataSource.killAllTranscriptServers()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Kill all transcript HTTP servers")
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 4)
                }

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
                case .settings:
                    SettingsTabView()
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

                    // ── Today / This Week aggregates (from scan.sh) ──
                    if let agg = d.aggregates, (agg.today != nil || agg.week != nil) {
                        HStack(alignment: .top, spacing: 10) {
                            if let today = agg.today {
                                OverviewSection(title: "Today", icon: "sun.max.fill", iconColor: .yellow) {
                                    VStack(spacing: 8) {
                                        HStack(spacing: 0) {
                                            AggregateMetric(label: "Sessions", value: "\(today.sessions ?? 0)", color: .blue)
                                            Divider().frame(height: 28)
                                            AggregateMetric(label: "Turns", value: fmtTokens(today.turns ?? 0), color: .purple)
                                            Spacer()
                                        }
                                        HStack(spacing: 0) {
                                            AggregateMetric(label: "Tokens In", value: fmtTokens(today.tokensIn ?? 0), color: .cyan)
                                            Divider().frame(height: 28)
                                            AggregateMetric(label: "Tokens Out", value: fmtTokens(today.tokensOut ?? 0), color: .indigo)
                                            Divider().frame(height: 28)
                                            AggregateMetric(label: "Cost", value: fmtCost(today.costUsd ?? 0), color: .mint)
                                            Spacer()
                                        }
                                    }
                                }
                            }
                            if let week = agg.week {
                                OverviewSection(title: "This Week", icon: "calendar", iconColor: .blue) {
                                    VStack(spacing: 8) {
                                        HStack(spacing: 0) {
                                            AggregateMetric(label: "Sessions", value: "\(week.sessions ?? 0)", color: .blue)
                                            Divider().frame(height: 28)
                                            AggregateMetric(label: "Turns", value: fmtTokens(week.turns ?? 0), color: .purple)
                                            Spacer()
                                        }
                                        HStack(spacing: 0) {
                                            AggregateMetric(label: "Tokens In", value: fmtTokens(week.tokensIn ?? 0), color: .cyan)
                                            Divider().frame(height: 28)
                                            AggregateMetric(label: "Tokens Out", value: fmtTokens(week.tokensOut ?? 0), color: .indigo)
                                            Divider().frame(height: 28)
                                            AggregateMetric(label: "Cost", value: fmtCost(week.costUsd ?? 0), color: .mint)
                                            Spacer()
                                        }
                                    }
                                }
                            }
                        }

                        // Model breakdown badges (from aggregates)
                        if let mb = agg.modelBreakdown, !mb.isEmpty {
                            OverviewSection(title: "Model Usage", icon: "cpu.fill", iconColor: .pink) {
                                HStack(spacing: 8) {
                                    ForEach(mb.sorted(by: { $0.value > $1.value }), id: \.key) { model, count in
                                        let m = modelDisplay(model)
                                        HStack(spacing: 4) {
                                            Text(m.badge)
                                            Text(m.label)
                                                .font(.system(size: 12, weight: .bold))
                                            Text("×\(count)")
                                                .font(.system(size: 12))
                                                .foregroundColor(.secondary)
                                        }
                                        .foregroundColor(Color(nsColor: m.color))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(
                                            Capsule().fill(Color(nsColor: m.color).opacity(0.1))
                                        )
                                    }
                                    Spacer()
                                }
                            }
                        }
                    }

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
                                    if let countdown = rateLimitCountdown(limits.resetsAt) {
                                        HStack(spacing: 4) {
                                            Image(systemName: "clock.arrow.circlepath")
                                                .font(.system(size: 11))
                                                .foregroundColor(.secondary)
                                            Text("Resets in \(countdown)")
                                                .font(.system(size: 12, weight: .medium))
                                                .foregroundColor(.secondary)
                                        }
                                        .padding(.top, 2)
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

                                        // Model badge inline
                                        if let model = evt.model, !model.isEmpty {
                                            let em = modelDisplay(model)
                                            Text(em.badge)
                                                .font(.system(size: 10))
                                                .foregroundColor(Color(nsColor: em.color))
                                        }

                                        Text(evt.tabTitle ?? evt.project ?? "")
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
                if entry.used > 0 || entry.cap > 0 {
                    Text("(\(fmtTokens(entry.used))/\(fmtTokens(entry.cap)))")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                }
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

// MARK: - ▲▲▲ End DashboardKit. Below: project-specific tab content ▲▲▲ ─────
//
// Everything from here on consumes the kit. The Tab views reference
// Claude-specific data shapes (LiveInstance, ScanResult, etc.) and would
// be replaced wholesale when copying the kit into another app.
//
// One helper struct (MetadataItem) is defined inside this section but is
// generic enough to live in the kit — see docs/dashboard-kit.md for the
// extraction instructions.
//
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

    @State private var blinkOn = true

    var body: some View {
        let m = modelDisplay(inst.model)
        let stateStr = inst.sessionState?.state ?? "idle"
        let isActive = stateStr != "idle"

        VStack(alignment: .leading, spacing: 12) {
            // Header row: model pill + state + title/path + elapsed
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

                // Session state pill (blinking when active)
                if isActive {
                    let stateLabels: [String: String] = [
                        "thinking": "Thinking", "responding": "Writing",
                        "tool_use": "Tool", "tool_result": "Processing",
                    ]
                    let stateColors: [String: Color] = [
                        "thinking": .yellow, "responding": .green,
                        "tool_use": .teal, "tool_result": .blue,
                    ]
                    let label = stateLabels[stateStr] ?? stateStr
                    let stColor = stateColors[stateStr] ?? .secondary

                    Text(label)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(stColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule().fill(stColor.opacity(blinkOn ? 0.15 : 0.05))
                        )
                        .opacity(blinkOn ? 1.0 : 0.5)
                        .onAppear {
                            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                                blinkOn.toggle()
                            }
                        }
                }

                // Subagent badge
                if let subs = inst.subagentCount, subs > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 10))
                        Text("\(subs)")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(.purple)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.purple.opacity(0.12)))
                }

                Spacer()

                Text(inst.elapsed?.trimmingCharacters(in: .whitespaces) ?? "?")
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundColor(.orange)
            }

            // Tab title / path row
            HStack(spacing: 6) {
                if let tabTitle = inst.tabTitle, !tabTitle.isEmpty {
                    Text(tabTitle)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    Text("·")
                        .foregroundColor(.secondary.opacity(0.4))
                    Text(inst.cwdShort ?? inst.cwd ?? "?")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                } else {
                    Text(inst.cwdShort ?? inst.cwd ?? "?")
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(1)
                }
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

                if let tc = inst.toolCalls, tc > 0 {
                    MetadataItem(icon: "wrench.fill", text: "\(tc) tools")
                }

                if let o = inst.outputTokens, o > 0 {
                    MetadataItem(icon: "arrow.up", text: fmtTokens(o) + " tok")
                }

                if let c = inst.costUsd, c > 0 {
                    MetadataItem(icon: "dollarsign.circle", text: fmtCost(c))
                }

                Spacer()
            }

            // Context remaining + secondary metrics row
            HStack(spacing: 0) {
                if let ctx = inst.statusline?.ctxRemaining, !ctx.isEmpty, ctx != "0" {
                    let ctxInt = Int(ctx) ?? 100
                    let ctxColor: Color = ctxInt < 30 ? .red : (ctxInt < 60 ? .orange : .green)
                    HStack(spacing: 4) {
                        Image(systemName: "circle.lefthalf.filled")
                            .font(.system(size: 10))
                            .foregroundColor(ctxColor)
                        Text("ctx \(ctx)%")
                            .font(.system(size: 12))
                            .foregroundColor(ctxColor)
                    }
                    .padding(.trailing, 16)
                }

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

            // Action buttons — always fully visible. The previous pattern
            // fade-in-on-hover-only had two bugs: (1) at 40% opacity the
            // Transcript button was easy to overlook ("where did it go?"),
            // (2) the buttons exist precisely so the user CAN take action
            // without needing to hover — hiding them behind hover defeats
            // their purpose.
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
                    .buttonStyle(.borderedProminent)
                    .tint(.teal)
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
func findJsonlPath(projectsDir: String, sessionId: String) -> String? {
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

    @State private var filterType: String = "All"
    @State private var showDeepHistory: Bool = false

    private var allEventTypes: [String] {
        var types = Set<String>()
        if let events = data?.recentEvents { events.forEach { types.insert($0.event) } }
        if let deep = data?.deepEvents { deep.forEach { types.insert($0.event) } }
        return ["All"] + types.sorted()
    }

    private var displayEvents: [Event] {
        let source: [Event]
        if showDeepHistory, let deep = data?.deepEvents, !deep.isEmpty {
            source = deep
        } else {
            source = data?.recentEvents ?? []
        }
        if filterType == "All" { return source.reversed() }
        return source.filter { $0.event == filterType }.reversed()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(alignment: .firstTextBaseline) {
                Text("Events")
                    .font(.system(size: 22, weight: .bold))
                Spacer()
                Text("\(displayEvents.count) events")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 8)

            // Filter bar
            HStack(spacing: 12) {
                // Deep history toggle
                if data?.deepEvents != nil {
                    Toggle(isOn: $showDeepHistory) {
                        Text("Deep History")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }

                Spacer()

                // Event type filter
                Picker("Type", selection: $filterType) {
                    ForEach(allEventTypes, id: \.self) { type in
                        Text(type == "All" ? "All Types" : eventLabel(type))
                            .tag(type)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 160)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 12)

            Rectangle()
                .fill(Color.secondary.opacity(0.15))
                .frame(height: 1)
                .padding(.horizontal, 20)

            if !displayEvents.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(displayEvents.enumerated()), id: \.offset) { idx, evt in
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
                                        .fill(idx == displayEvents.count - 1 ? Color.clear : Color.secondary.opacity(0.2))
                                        .frame(width: 1)
                                        .frame(maxHeight: .infinity)
                                }
                                .frame(width: 10)

                                // Event content
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 8) {
                                        EventBadge(event: evt.event)

                                        // Model badge
                                        if let model = evt.model, !model.isEmpty {
                                            let m = modelDisplay(model)
                                            HStack(spacing: 3) {
                                                Text(m.badge)
                                                Text(m.label)
                                                    .font(.system(size: 11, weight: .bold))
                                            }
                                            .foregroundColor(Color(nsColor: m.color))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(
                                                Capsule().fill(Color(nsColor: m.color).opacity(0.1))
                                            )
                                        }

                                        Text(eventTime(evt.ts))
                                            .font(.system(size: 12, design: .monospaced))
                                            .foregroundColor(.secondary)
                                    }

                                    // Tab title or project
                                    HStack(spacing: 6) {
                                        if let title = evt.tabTitle, !title.isEmpty {
                                            Text(title)
                                                .font(.system(size: 13, weight: .medium))
                                                .foregroundColor(.primary.opacity(0.9))
                                                .lineLimit(1)
                                            if let proj = evt.project, !proj.isEmpty {
                                                Text("·")
                                                    .foregroundColor(.secondary.opacity(0.4))
                                                Text(proj)
                                                    .font(.system(size: 12))
                                                    .foregroundColor(.secondary)
                                                    .lineLimit(1)
                                            }
                                        } else if let proj = evt.project, !proj.isEmpty {
                                            Text(proj)
                                                .font(.system(size: 13))
                                                .foregroundColor(.primary.opacity(0.8))
                                                .lineLimit(1)
                                        }
                                    }

                                    // Tool detail for PostToolUse events
                                    if evt.event == "PostToolUse", let tool = evt.tool, !tool.isEmpty {
                                        HStack(spacing: 4) {
                                            Image(systemName: "wrench.fill")
                                                .font(.system(size: 9))
                                                .foregroundColor(.teal.opacity(0.7))
                                            Text(tool)
                                                .font(.system(size: 11, design: .monospaced))
                                                .foregroundColor(.teal)
                                        }
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
                            .frame(minHeight: 56)
                        }
                    }
                    .padding(24)
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
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
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

    // Derived from user preference (24h vs 12h). Re-read on each access so
    // changes from Settings → Menu Behavior propagate without view recreation.
    private var dateFmt: DateFormatter { userTimeFormatter(includesDate: true) }

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
                                       dateFmt: dateFmt,
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

/// Settings → Menu Bar Badge. What the menu-bar icon shows — the live session
/// count, the per-limit usage rows (5h / weekly), the permission-request marker,
/// and the "resets soon" dot threshold. Read live by `updateButton()`.
struct MenuBarBadgeSection: View {
    @AppStorage("ui.badge.showCount")     private var showCount = true
    @AppStorage("ui.badge.showRows")      private var showRows = true
    @AppStorage("ui.badge.showPermWarn")  private var showPermWarn = true
    @AppStorage("rateLimitResetSoonMinutes") private var resetSoon = 30

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
                Toggle("Show per-limit usage rows (5h / weekly)", isOn: $showRows)
                    .toggleStyle(.checkbox).onChange(of: showRows) { _, _ in postChange() }
                Toggle("Show permission-request marker (⚠)", isOn: $showPermWarn)
                    .toggleStyle(.checkbox).onChange(of: showPermWarn) { _, _ in postChange() }
                Divider()
                HStack(spacing: 12) {
                    Text("Resets-soon dot")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 130, alignment: .leading)
                    Stepper(value: $resetSoon, in: 5...240, step: 5) {
                        Text("Within \(resetSoon) min")
                            .font(.system(size: 12, design: .monospaced))
                    }
                    .frame(maxWidth: 200)
                    .onChange(of: resetSoon) { _, _ in postChange() }
                    Text("A light-blue dot appears on a limit's row when its window resets within this time.")
                        .font(.system(size: 11)).foregroundColor(.secondary).lineLimit(2)
                    Spacer()
                }
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
                Text("Affects the dashboard window. The menu's translucent material adapts to the OS regardless.")
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
    @AppStorage("defaultTab") private var defaultTab: String = DashboardTab.overview.rawValue
    @AppStorage("time.use24h") private var use24h: Bool = false

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

                HStack(spacing: 12) {
                    Text("Default tab")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 130, alignment: .leading)
                    Picker("", selection: $defaultTab) {
                        ForEach(DashboardTab.allCases) { tab in
                            Text(tab.rawValue).tag(tab.rawValue)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 220)
                    .onChange(of: defaultTab) { _, _ in postChange() }
                    Text("Which tab opens on the next dashboard launch.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Spacer()
                }

                HStack(spacing: 12) {
                    Text("Time format")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 130, alignment: .leading)
                    Toggle("Use 24-hour clock", isOn: $use24h)
                        .toggleStyle(.checkbox)
                        .onChange(of: use24h) { _, _ in postChange() }
                    Text("Applies to absolute timestamps in the dashboard (history, sessions, events).")
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

/// Settings → Refresh & Warnings. Centralizes the two preferences that
/// also live in the menu (Refresh submenu + warning-threshold slider).
/// Reads/writes the SAME UserDefaults keys the menu uses, so changes
/// flow both ways: edit here → menu updates on next open; edit in menu
/// → these controls update on next dashboard render. Posts
/// .menuBehaviorDidChange so the bar restarts its scan timer.
struct RefreshAndWarningsSection: View {
    @State private var cadence: Double
    @State private var paused: Bool
    @State private var threshold: Double
    @State private var danger: Double

    init() {
        let raw = UserDefaults.standard.double(forKey: "scanRefreshInterval")
        _cadence   = State(initialValue: raw > 0 ? raw : 5.0)
        _paused    = State(initialValue: UserDefaults.standard.bool(forKey: "scanRefreshInterval.paused"))
        let thr    = UserDefaults.standard.integer(forKey: "rateLimitWarningThreshold")
        _threshold = State(initialValue: thr > 0 ? Double(thr) : 70.0)
        let dng    = UserDefaults.standard.integer(forKey: "rateLimitDangerThreshold")
        _danger    = State(initialValue: dng > 0 ? Double(dng) : 90.0)
    }

    // One usage-zone slider row, persisting its own UserDefaults key (the same
    // keys the menu's two-slider control writes — edits flow both ways).
    @ViewBuilder
    private func zoneRow(_ label: String, value: Binding<Double>, key: String) -> some View {
        HStack(spacing: 12) {
            Text(label).font(.system(size: 13, weight: .medium)).frame(width: 130, alignment: .leading)
            Slider(value: value, in: 50...100, step: 5) { Text(label) }
            minimumValueLabel: { Text("50%").font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary) }
            maximumValueLabel: { Text("100%").font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary) }
            .frame(maxWidth: 320)
            .onChange(of: value.wrappedValue) { _, newVal in
                UserDefaults.standard.set(Int(newVal), forKey: key)
                NotificationCenter.default.post(name: .menuBehaviorDidChange, object: nil)
            }
            Text("\(Int(value.wrappedValue))%").font(.system(size: 13, design: .monospaced)).frame(width: 40, alignment: .leading)
            Spacer()
        }
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
                Divider().opacity(0.4)
                Text("Usage zones")
                    .font(.system(size: 13, weight: .semibold))
                zoneRow("Warn at", value: $threshold, key: "rateLimitWarningThreshold")
                zoneRow("Danger at", value: $danger, key: "rateLimitDangerThreshold")
                Text("When 5h or 7d usage crosses a zone, the menu-bar % turns orange (warn) or red (danger). Hitting a cap is fine; these are signals, not limits.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .padding(.leading, 130 + 12)
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
                        AboutRow(label: "Scanner", value: "lib/scan.sh — Python → JSON, ~950 lines")
                        AboutRow(label: "Statusline cache", value: "/tmp/claude-statusline-<pid>")
                        AboutRow(label: "Sessions JSONL", value: "~/.claude/projects/")
                        AboutRow(label: "Rate Limits cache", value: "~/.claude/widgets/.limits.json")
                        AboutRow(label: "Refresh cadence", value: "user-selectable (default 5s) · full scan every 6 ticks")
                        AboutRow(label: "Transcript HTTP server", value: "lib/detail-server.py — per-pid, idle-exit at 10min")
                    }
                }

                // Dashboard tabs guide
                OverviewSection(title: "Dashboard Tabs", icon: "sidebar.squares.left", iconColor: .indigo) {
                    VStack(alignment: .leading, spacing: 6) {
                        TabHelp(icon: "square.grid.2x2.fill", color: .blue, name: "Overview",
                                desc: "Stat cards, rate limits, today/week aggregates, model breakdown")
                        TabHelp(icon: "sparkles", color: .green, name: "Live",
                                desc: "Running instances with metrics, hover actions, transcript viewer")
                        TabHelp(icon: "clock.arrow.circlepath", color: .purple, name: "History",
                                desc: "Recent sessions — search, sort, resume, tokens, cost")
                        TabHelp(icon: "list.bullet", color: .orange, name: "Events",
                                desc: "Timeline of start/stop/compact/permission/hook events")
                        TabHelp(icon: "tray.full.fill", color: .indigo, name: "All Sessions",
                                desc: "Deep scan of all past sessions with search and resume")
                        TabHelp(icon: "slider.horizontal.3", color: .gray, name: "Settings",
                                desc: "Appearance · Widget Menu palette (17 tokens) · Menu Behavior · Keybinds")
                    }
                }

                // The view-based menu row + live-update mechanism
                OverviewSection(title: "Live Menu Row", icon: "rectangle.stack", iconColor: .green) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Each running session is rendered as a view-based NSMenuItem (LiveRowView) that mutates in place while the menu is held open — AppKit doesn't redraw attributedTitle of an open menu item, so the row owns a vertical NSStackView of chips and updates each on every scan tick.")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .padding(.bottom, 4)
                        AboutRow(label: "Per-chip hover", value: "Header + metrics chips tagged with palette tokens")
                        AboutRow(label: "Sizing", value: "setFrameSize(stack.fittingSize) after each update()")
                        AboutRow(label: "Reverse highlight", value: "Settings preview hover → row chip tints in place")
                    }
                }

                // Palette + Settings
                OverviewSection(title: "Palette System", icon: "paintpalette", iconColor: .pink) {
                    VStack(alignment: .leading, spacing: 4) {
                        AboutRow(label: "Tokens", value: "17 user-tunable colors (model/metric/accent/warn/success/permission)")
                        AboutRow(label: "Storage", value: "UserDefaults: palette.<token> = #RRGGBB hex")
                        AboutRow(label: "Picker", value: "Tailwind v3 subset: 13 hues × 5 shades = 65 swatches")
                        AboutRow(label: "Live propagation", value: "PaletteStore.didChangeNotification → BarDelegate refreshLiveRows + updateButton")
                    }
                }

                // Transcript viewer
                OverviewSection(title: "Live Transcript Viewer", icon: "doc.text.magnifyingglass", iconColor: .teal) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Clicking \"View Transcript\" on an instance opens a live HTML view of its conversation. detail.sh spawns a per-pid localhost http.server (port 5400 + pid % 500) and Chrome opens via http:// so the JS can fetch() itself for live updates (file:// → file:// fetch is CORS-blocked).")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .padding(.bottom, 4)
                        AboutRow(label: "Server", value: "lib/detail-server.py — http.server + /regen endpoint")
                        AboutRow(label: "Poll cadence", value: "30s — JS calls /regen, fetches HTML, swaps #msgs in place")
                        AboutRow(label: "Shutdown", value: "Claude PID death (60s) · 10-min idle · 2h hard deadline · SIGTERM")
                        AboutRow(label: "Rendering", value: "marked.js + highlight.js (CDN), Edit diffs side-by-side")
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

                        AboutRow(label: "Bar log", value: "~/Library/Logs/ClaudeInstances/bar.log (rotated at 1MB)")
                        AboutRow(label: "Server logs", value: "/tmp/claude-widget-<pid>.server.log")
                        AboutRow(label: "LaunchAgent", value: "dev.claude-instances.menubar")
                        AboutRow(label: "Dashboard kit docs", value: "docs/dashboard-kit.md")
                    }
                }

                // Troubleshooting
                OverviewSection(title: "Troubleshooting", icon: "wrench.and.screwdriver", iconColor: .yellow) {
                    VStack(alignment: .leading, spacing: 6) {
                        TroubleshootRow(problem: "Two icons in menu bar",
                                       fix: "Hover stale icon to clear, or `bash native/build.sh --install`")
                        TroubleshootRow(problem: "Focus doesn't switch tabs",
                                       fix: "Grant Accessibility permission in System Settings")
                        TroubleshootRow(problem: "Menu shows 'Scanning...'",
                                       fix: "Test scan.sh directly: `bash lib/scan.sh | head`")
                        TroubleshootRow(problem: "Transcript URL opens but server is dead",
                                       fix: "Server exits after 10min idle. Click View Transcript again to respawn — detail.sh is idempotent.")
                        TroubleshootRow(problem: "Branch / last-prompt missing in row",
                                       fix: "Quick scans skip git ops; wait for next full scan (~30s) or click Refresh Now")
                        TroubleshootRow(problem: "Palette change didn't apply",
                                       fix: "Close + reopen the menu — bar refreshes open rows but stale ones need a rebuild")
                        TroubleshootRow(problem: "Dashboard hitches",
                                       fix: "Check tests/run-tests.sh for known perf regressions; DateFormatter caching ships in the current build")
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

func eventColor(_ event: String) -> Color {
    switch event {
    case "SessionStart":      return .green
    case "Stop":              return .red
    case "PermissionRequest": return .orange
    case "PostCompact":       return .blue
    case "PreCompact":        return .blue
    case "SubagentStart":     return .purple
    case "SubagentStop":      return .purple
    case "Notification":      return .yellow
    case "PostToolUse":       return .teal
    default:                  return .secondary
    }
}

func eventLabel(_ event: String) -> String {
    switch event {
    case "SessionStart":      return "Started"
    case "Stop":              return "Stopped"
    case "PermissionRequest": return "Permission"
    case "PostCompact":       return "Compacted"
    case "PreCompact":        return "Compacting"
    case "SubagentStart":     return "Agent ▶"
    case "SubagentStop":      return "Agent ■"
    case "Notification":      return "Notified"
    case "PostToolUse":       return "Tool"
    default:                  return event
    }
}

func eventTime(_ ts: String) -> String {
    if ts.contains("T"), let time = ts.split(separator: "T").last {
        return String(time.prefix(5))
    }
    return ts
}

