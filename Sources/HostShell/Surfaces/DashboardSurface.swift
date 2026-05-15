import SwiftUI
import HostKernel

/// Dashboard layout: sidebar (entries grouped by `section`) on the left,
/// pane stack on the right. Phase 3 uses hand-coded demo entries to exercise
/// every pane kind; Phase 4+ wires this to the registry's
/// `dashboard.pane` contributions.
struct DashboardSurface: View {
    @State private var selection: String? = "demo-all-kinds"

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Demo") {
                    NavigationLink(value: "demo-all-kinds") {
                        Label("All Pane Kinds", systemImage: "rectangle.3.group")
                    }
                    NavigationLink(value: "demo-error") {
                        Label("Error State", systemImage: "exclamationmark.triangle")
                    }
                }
                Section("Coming Next") {
                    Text("Registered plugins (Phase 4)")
                        .font(.caption)
                        .foregroundStyle(Palette.tertiary)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
            .listStyle(.sidebar)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if selection == "demo-error" {
                        errorDemo
                    } else {
                        allKindsDemo
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minWidth: 480)
            .background(Palette.surface.opacity(0.5))
        }
        .frame(minWidth: 720, minHeight: 480)
    }

    // MARK: - Demo content

    private var allKindsDemo: some View {
        Group {
            PaneRenderer(
                content: .summary(DemoPaneData.summary),
                title: "Summary",
                subtitle: "stat tiles · tones · progress · badges",
                fetchedAt: Date().addingTimeInterval(-7)
            )
            PaneRenderer(
                content: .table(DemoPaneData.table),
                title: "Table",
                subtitle: "columns · row actions · alignment",
                fetchedAt: Date().addingTimeInterval(-23),
                onRefresh: {}
            )
            PaneRenderer(
                content: .schedule(DemoPaneData.schedule),
                title: "Schedule",
                subtitle: "cron + launchd · read-only in V1",
                fetchedAt: Date().addingTimeInterval(-120)
            )
            PaneRenderer(
                content: .assets(DemoPaneData.assets),
                title: "Assets",
                subtitle: "files · size + mtime · open-with",
                fetchedAt: Date().addingTimeInterval(-310)
            )
            PaneRenderer(
                content: .log(DemoPaneData.log),
                title: "Log",
                subtitle: "monospaced · auto-scroll",
                fetchedAt: Date().addingTimeInterval(-2)
            )
            .frame(height: 200)
        }
    }

    private var errorDemo: some View {
        Group {
            PaneRenderer(
                content: .error(DemoPaneData.errorSample),
                title: "Demo error state",
                subtitle: "fetch.timeout with stderr disclosure",
                fetchedAt: nil)
        }
    }
}
