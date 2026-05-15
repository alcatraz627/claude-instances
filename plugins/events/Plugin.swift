import Foundation
import HostKernel

/// Third pilot port. Table pane exercising row actions + multi-column.
@MainActor
public final class EventsPlugin: Plugin {
    public static let id = "events"

    public init() {}

    public func render(_ source: String) async throws -> PaneContent {
        switch source {
        case "recent":
            let cols: [TableContent.Column] = [
                .init(id: "ts",   label: "When",    width: .fixed(110), align: nil),
                .init(id: "kind", label: "Kind",    width: .fixed(110), align: nil),
                .init(id: "msg",  label: "Message", width: .flex,        align: nil)
            ]
            let rows: [TableContent.Row] = [
                .init(cells: ["ts": "04:30:12", "kind": "tool.use",
                              "msg": "Read /tmp/foo.txt"]),
                .init(cells: ["ts": "04:31:04", "kind": "tool.use",
                              "msg": "Bash: ls -la"]),
                .init(cells: ["ts": "04:32:18", "kind": "session.start",
                              "msg": "New Claude session (pid 4831)"]),
                .init(cells: ["ts": "04:35:00", "kind": "tool.use",
                              "msg": "Edit ~/.zshrc"]),
                .init(cells: ["ts": "04:38:42", "kind": "session.idle",
                              "msg": "Idle for 60s"]),
                .init(cells: ["ts": "04:42:09", "kind": "tool.use",
                              "msg": "Read ~/.claude/atone/events.jsonl"]),
                .init(cells: ["ts": "04:45:33", "kind": "rate-limit",
                              "msg": "78% used; resets in 2h"]),
            ]
            return .table(TableContent(
                columns: cols, rows: rows,
                empty: "No events.",
                truncatedAt: nil, hasMore: nil))
        default:
            return .error(PluginError(
                .fetchSchemaViolation,
                "EventsPlugin: unknown source '\(source)'"))
        }
    }
}
