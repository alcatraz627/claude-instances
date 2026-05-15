import Foundation

/// Closed enum of every error code the host emits at a plugin boundary.
///
/// Renderers and log filters branch on `code`, never on `message`
/// (per the project's `rules/error-classification.md`). Adding a new
/// case is a host change; adding a new free-form `message` is not.
public enum PluginErrorCode: String, Codable, Sendable {
    case manifestInvalid              = "manifest.invalid"
    case manifestUnsupportedEnvelope  = "manifest.unsupported_envelope"
    case enginesMismatch              = "engines.mismatch"
    case requiresMissingTool          = "requires.missing_tool"
    case fetchTimeout                 = "fetch.timeout"
    case fetchHardKilled              = "fetch.hard_killed"
    case fetchExitNonzero             = "fetch.exit_nonzero"
    case fetchBadJson                 = "fetch.bad_json"
    case fetchSchemaViolation         = "fetch.schema_violation"
    case fetchPayloadTooLarge         = "fetch.payload_too_large"
    case actionTimeout                = "action.timeout"
    case actionExitNonzero            = "action.exit_nonzero"
    case eventUnknownTopic            = "event.unknown_topic"
    case eventHandlerFailed           = "event.handler_failed"
    case nativeActivationFailed       = "native.activation_failed"
    case nativeMethodThrew            = "native.method_threw"
    case budgetSpawnRateExceeded      = "budget.spawn_rate_exceeded"
    case budgetPayloadExceeded        = "budget.payload_exceeded"
    case budgetConcurrentExceeded     = "budget.concurrent_exceeded"
}

/// A single plugin error. Carries the closed `code`, a human message
/// (logs and disclosure UI only), an optional stderr tail for script
/// errors, and an actionable hint when one is known.
public struct PluginError: Error, Sendable, CustomStringConvertible {
    public let code: PluginErrorCode
    public let message: String
    public let stderrTail: String?
    public let actionable: String?

    public init(_ code: PluginErrorCode, _ message: String,
                stderrTail: String? = nil, actionable: String? = nil) {
        self.code = code
        self.message = message
        self.stderrTail = stderrTail
        self.actionable = actionable
    }

    public var description: String {
        "[\(code.rawValue)] \(message)"
    }
}

/// Non-fatal note attached to a successful load. The closed-namespace contract
/// for `contributes.*` produces these on unknown keys (preserved, not failed).
public struct PluginWarning: Sendable, CustomStringConvertible {
    public let pluginId: String
    public let message: String

    public init(pluginId: String, message: String) {
        self.pluginId = pluginId
        self.message = message
    }

    public var description: String { "[\(pluginId)] \(message)" }
}
