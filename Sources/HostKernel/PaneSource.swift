import Foundation

/// Parsed form of a `dashboard.pane.source` string from a manifest. Sources
/// are tagged strings like `"fetch:summary"`, `"native:render"`,
/// `"event:atone.tick"`, `"static:{...}"`. The host parses once at render
/// time and dispatches accordingly.
public enum PaneSource: Sendable, Equatable {
    /// Call the manifest's exec.fetch with these argv tokens.
    case fetch(args: [String])

    /// Invoke the native plugin's render(_:) with this method name.
    case native(method: String)

    /// Subscribe to an event-bus topic (Phase 6+ delivery).
    case event(topic: String)

    /// Embed JSON inline in the manifest (rare).
    case staticData(json: String)

    public init?(_ raw: String) {
        guard let colon = raw.firstIndex(of: ":") else {
            // No scheme prefix — assume the manifest author meant a native
            // method name. Permissive on purpose.
            self = .native(method: raw)
            return
        }
        let scheme = String(raw[..<colon])
        let rest = String(raw[raw.index(after: colon)...])
        switch scheme {
        case "fetch":
            // Argv split: simple whitespace tokenization. Quoted args not
            // supported in V1 — plugin authors who need them should use
            // an exec args layer.
            let args = rest.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            self = .fetch(args: args)
        case "native":
            self = .native(method: rest)
        case "event":
            self = .event(topic: rest)
        case "static":
            self = .staticData(json: rest)
        default:
            return nil
        }
    }
}
