import Foundation
import HostKernel

/// First native plugin port. Static content only — no data dependencies,
/// no commands. Demonstrates the minimum Plugin shape.
@MainActor
public final class AboutPlugin: Plugin {
    public static let id = "about-v2"

    public init() {}

    public func render(_ source: String) async throws -> PaneContent {
        switch source {
        case "summary":
            return .summary(SummaryContent(tiles: [
                .init(label: "Host version", value: HostKernel.version),
                .init(label: "Build", value: "preview", tone: .dim),
                .init(label: "Native plugins", value: "3",
                      trend: "about · overview · events"),
                .init(label: "Status", value: "OK", tone: .ok)
            ]))
        case "assets":
            return .assets(AssetsContent(items: [
                .init(path: "docs/v2-architecture.md",
                      label: "V2 Architecture",
                      sizeBytes: nil, mtime: nil, openWith: .auto),
                .init(path: "docs/v2-implementation-plan.md",
                      label: "V2 Implementation Plan",
                      sizeBytes: nil, mtime: nil, openWith: .auto),
                .init(path: "docs/known-issues.md",
                      label: "Known Issues",
                      sizeBytes: nil, mtime: nil, openWith: .auto)
            ]))
        default:
            return .error(PluginError(
                .fetchSchemaViolation,
                "AboutPlugin: unknown source '\(source)'"))
        }
    }
}
