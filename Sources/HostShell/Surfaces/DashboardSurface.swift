import SwiftUI
import HostKernel

/// Dashboard layout: sidebar + content scroller. Phase 3 ships demo entries
/// + a real Settings tab. Phase 4+ wires the sidebar to the registry's
/// `dashboard.pane` contributions.
struct DashboardSurface: View {
    @State private var selection: String? = "demo-all-kinds"
    @EnvironmentObject var store: HostSettingsStore
    @Environment(\.design) var design

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
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $selection) {
            Section("Demo") {
                NavigationLink(value: "demo-all-kinds") {
                    Label("All Pane Kinds", systemImage: "rectangle.3.group")
                }
                NavigationLink(value: "demo-error") {
                    Label("Error State", systemImage: "exclamationmark.triangle")
                }
            }
            Section("System") {
                NavigationLink(value: "settings") {
                    Label("Settings", systemImage: "slider.horizontal.3")
                }
            }
            Section("Coming Next") {
                Text("Registered plugins (Phase 4)")
                    .font(design.font(DesignTokens.FontSize.caption))
                    .foregroundStyle(DesignTokens.TextColor.tertiary)
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
        case "demo-error":
            scroll {
                PaneRenderer(
                    content: .error(DemoPaneData.errorSample),
                    title: "Demo error state",
                    subtitle: "fetch.timeout with stderr disclosure",
                    fetchedAt: nil)
            }
        default:
            scroll {
                allKindsDemo
            }
        }
    }

    @ViewBuilder
    private func scroll<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: design.space(DesignTokens.Space.m)) {
                content()
            }
            .padding(design.space(DesignTokens.Space.l))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var allKindsDemo: some View {
        Group {
            PaneRenderer(
                content: .summary(DemoPaneData.summary),
                title: "Summary",
                subtitle: "stat tiles · tones · progress · badges",
                fetchedAt: Date().addingTimeInterval(-7))
            PaneRenderer(
                content: .table(DemoPaneData.table),
                title: "Table",
                subtitle: "columns · row actions · hover highlight",
                fetchedAt: Date().addingTimeInterval(-23),
                onRefresh: {})
            PaneRenderer(
                content: .schedule(DemoPaneData.schedule),
                title: "Schedule",
                subtitle: "cron + launchd · read-only in V1",
                fetchedAt: Date().addingTimeInterval(-120))
            PaneRenderer(
                content: .assets(DemoPaneData.assets),
                title: "Assets",
                subtitle: "files · size + mtime · open-with",
                fetchedAt: Date().addingTimeInterval(-310))
            PaneRenderer(
                content: .log(DemoPaneData.log),
                title: "Log",
                subtitle: "monospaced · auto-scroll",
                fetchedAt: Date().addingTimeInterval(-2))
            .frame(height: 220)
        }
    }
}
