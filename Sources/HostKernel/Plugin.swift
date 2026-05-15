import Foundation

/// The contract a native plugin implements. Plugins compile into the host
/// binary as separate SPM targets (one per plugin folder under `plugins/`)
/// and register at startup via `BundledPluginRegistry`.
///
/// Lifecycle: host calls `activate(host:)` once when the plugin's first
/// contribution is requested; `deactivate()` when the plugin is disabled or
/// the host shuts down. `render(_:)` is called per pane refresh.
@MainActor
public protocol Plugin: AnyObject {
    /// Must match `manifest.json`'s `id` field. The registry matches a loaded
    /// manifest to its plugin instance by this string.
    static var id: String { get }

    /// Host instantiates the plugin via the bare init at registration time.
    init()

    /// Called when the plugin transitions from `discovered` to `active`.
    /// Default no-op for plugins that don't need setup.
    func activate(host: HostContext) async throws

    /// Called when the plugin is being torn down.
    func deactivate() async throws

    /// Render the contribution identified by `source` to a typed `PaneContent`.
    /// `source` is the manifest's pane-spec source string with the `native:`
    /// prefix stripped — e.g. for `"source": "native:summary"`, this method
    /// receives `"summary"`.
    func render(_ source: String) async throws -> PaneContent

    /// Run a contributed command. `id` matches manifest `contributes.commands[].id`;
    /// `args` carry whatever the call site passed (row action args, hotkey args).
    /// Default returns "not implemented".
    func runCommand(_ id: String, args: [String: AnyCodable]) async throws -> CommandResult
}

public extension Plugin {
    func activate(host: HostContext) async throws {}
    func deactivate() async throws {}
    func runCommand(_ id: String, args: [String: AnyCodable]) async throws -> CommandResult {
        CommandResult(exitCode: 1, output: "command not implemented: \(id)")
    }
}

/// Outcome of a command invocation. `exitCode == 0` is success; any other
/// value renders as an error. `output` streams into the transient log pane
/// the UI shows below the panes when an action runs.
public struct CommandResult: Sendable {
    public let exitCode: Int
    public let output: String

    public init(exitCode: Int = 0, output: String = "") {
        self.exitCode = exitCode
        self.output = output
    }
}
