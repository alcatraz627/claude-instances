import SwiftUI
import HostKernel

/// Dashboard layout: sidebar + content scroller. Phase 4 swaps the
/// demo entries for registry-driven `dashboard.pane` contributions. Plugins
/// supply the render content; `PaneRenderer` paints it through the design
/// system the user controls in Settings.
struct DashboardSurface: View {
    @EnvironmentObject var store: HostSettingsStore
    @EnvironmentObject var platform: PlatformRegistry
    @Environment(\.design) var design

    @State private var selection: String? = nil

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
        } detail: {
            detail
                .frame(minWidth: 520)
                .background(DesignTokens.Surface.page)
        }
        .frame(minWidth: 760, minHeight: 480)
        .onAppear {
            if selection == nil {
                // Default to the first dashboard.pane contribution.
                selection = platform.dashboardSections()
                    .flatMap { $0.items }
                    .first?.1.id
            }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $selection) {
            ForEach(platform.dashboardSections(), id: \.section) { group in
                Section(group.section) {
                    ForEach(group.items, id: \.1.id) { _, contribution in
                        NavigationLink(value: contribution.id) {
                            Label(contribution.title,
                                  systemImage: contribution.icon ?? "rectangle")
                        }
                    }
                }
            }
            Section("System") {
                NavigationLink(value: "settings") {
                    Label("Settings", systemImage: "slider.horizontal.3")
                }
            }
            if platform.bootstrapped == false {
                Section("Status") {
                    Text("Loading plugins…")
                        .font(design.font(DesignTokens.FontSize.caption))
                        .foregroundStyle(DesignTokens.TextColor.tertiary)
                }
            }
        }
        .listStyle(.sidebar)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case "settings":
            SettingsTab()
        case let id? where id != "settings":
            if let pair = findContribution(by: id) {
                ContributionView(manifest: pair.0, contribution: pair.1)
            } else {
                fallback("No contribution found for id \(id).")
            }
        default:
            fallback("Pick something from the sidebar.")
        }
    }

    private func findContribution(by id: String) -> (Manifest, DashboardPane)? {
        for group in platform.dashboardSections() {
            for (manifest, contribution) in group.items where contribution.id == id {
                return (manifest, contribution)
            }
        }
        return nil
    }

    private func fallback(_ message: String) -> some View {
        VStack(spacing: design.space(DesignTokens.Space.s)) {
            Image(systemName: "rectangle.dashed")
                .font(.system(size: 32))
                .foregroundStyle(DesignTokens.TextColor.tertiary)
            Text(message)
                .font(design.font(DesignTokens.FontSize.body))
                .foregroundStyle(DesignTokens.TextColor.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Renders a single `dashboard.pane` contribution: stacks all its declared
/// panes vertically, each routed through `PaneRenderer`. Pane content is
/// fetched lazily from the plugin's `render(_:)` method via an async task.
private struct ContributionView: View {
    let manifest: Manifest
    let contribution: DashboardPane

    @EnvironmentObject var platform: PlatformRegistry
    @Environment(\.design) var design

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: design.space(DesignTokens.Space.m)) {
                ForEach(Array(contribution.panes.enumerated()), id: \.offset) { idx, spec in
                    PaneHolder(manifest: manifest, contribution: contribution,
                                spec: spec, index: idx)
                }
            }
            .padding(design.space(DesignTokens.Space.l))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// One pane within a contribution. Owns the async render lifecycle —
/// kicks off `plugin.render(source)` on appear and holds the resulting
/// `PaneContent` in @State.
private struct PaneHolder: View {
    let manifest: Manifest
    let contribution: DashboardPane
    let spec: PaneSpec
    let index: Int

    @EnvironmentObject var platform: PlatformRegistry
    @State private var content: PaneContent? = nil
    @State private var fetchedAt: Date? = nil

    private var paneTitle: String? {
        // Only the first pane in a contribution shows the contribution's title
        // in its chrome — subsequent panes are sub-sections without a separate
        // title. Keep it simple for Phase 4; surface-specific titling is a
        // future refinement.
        index == 0 ? contribution.title : spec.label
    }

    private var paneSubtitle: String? {
        index == 0 ? contribution.subtitle : nil
    }

    var body: some View {
        Group {
            if let content {
                PaneRenderer(content: content,
                             title: paneTitle,
                             subtitle: paneSubtitle,
                             fetchedAt: fetchedAt,
                             onRefresh: { Task { await refresh() } })
            } else {
                placeholder
            }
        }
        .task(id: spec.source) { await refresh() }
    }

    private var placeholder: some View {
        PaneRenderer(
            content: .summary(SummaryContent(tiles: [
                .init(label: "Loading", value: "…", tone: .dim)
            ])),
            title: paneTitle,
            subtitle: paneSubtitle,
            fetchedAt: nil)
    }

    @MainActor
    private func refresh() async {
        guard let plugin = platform.plugin(for: manifest) else {
            content = .error(PluginError(
                .nativeActivationFailed,
                "No plugin instance for id '\(manifest.id)' (script plugins arrive in Phase 5)"))
            fetchedAt = Date()
            return
        }
        // Source string: "native:method" → "method". "fetch:..." / "event:..."
        // are deferred to later phases; for now anything non-native errors.
        let source = parseSource(spec.source)
        do {
            content = try await plugin.render(source.argument)
        } catch {
            content = .error(PluginError(
                .nativeMethodThrew,
                "Plugin \(manifest.id) threw during render('\(source.argument)'): \(error)"))
        }
        fetchedAt = Date()
    }

    private struct ParsedSource {
        let scheme: String   // "native" | "fetch" | "event" | "static"
        let argument: String
    }

    private func parseSource(_ raw: String) -> ParsedSource {
        if let colon = raw.firstIndex(of: ":") {
            return ParsedSource(
                scheme: String(raw[..<colon]),
                argument: String(raw[raw.index(after: colon)...]))
        }
        return ParsedSource(scheme: "native", argument: raw)
    }
}
