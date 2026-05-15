import Foundation
import HostKernel

/// Second pilot port. Stat tiles over hand-crafted demo data — the real
/// scanner integration arrives in Phase 5+ (when the script executor and
/// host-feeds API land).
@MainActor
public final class OverviewPlugin: Plugin {
    public static let id = "overview"

    public init() {}

    public func render(_ source: String) async throws -> PaneContent {
        switch source {
        case "stats":
            return .summary(SummaryContent(tiles: [
                .init(label: "Live sessions", value: "3", tone: .ok),
                .init(label: "Rate limit", value: "78%",
                      trend: "resets in 2h", tone: .warn, progressPct: 78),
                .init(label: "Weekly tokens", value: "2.1M",
                      trend: "of 5M cap", tone: .none, progressPct: 42),
                .init(label: "Open transcripts", value: "5"),
                .init(label: "Memory growth", value: "+12 MB/hr", tone: .dim),
                .init(label: "Plugin spawns/min", value: "0",
                      trend: "no scripts yet", tone: .dim)
            ]))
        default:
            return .error(PluginError(
                .fetchSchemaViolation,
                "OverviewPlugin: unknown source '\(source)'"))
        }
    }
}
