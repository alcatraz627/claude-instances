import Foundation

/// Minimal JSON Schema (draft 2020-12 subset) used to describe per-plugin
/// settings. The host renders a form from this; the plugin reads back the
/// resolved values via HostContext.
///
/// Supported types: `boolean`, `integer`, `number`, `string` (plain + enum).
/// Supported keywords per property: `title`, `description`, `default`,
/// `enum`, `minimum`, `maximum`. Anything outside this surface is
/// preserved-but-ignored.
public struct SettingsSchema: Codable, Sendable {
    public let type: String           // expected: "object"
    public let title: String?
    public let properties: [String: Property]
    public let order: [String]?       // optional rendering order; falls back to alpha

    public struct Property: Codable, Sendable {
        public let type: String        // boolean | integer | number | string
        public let title: String?
        public let description: String?
        public let `default`: AnyCodable?
        public let `enum`: [AnyCodable]?
        public let minimum: Double?
        public let maximum: Double?
    }

    public init?(jsonData: Data) {
        guard let decoded = try? JSONDecoder().decode(SettingsSchema.self, from: jsonData) else {
            return nil
        }
        self = decoded
    }

    /// Read a schema from disk. Path is resolved relative to the plugin's
    /// directory if not absolute.
    public static func load(from url: URL) -> SettingsSchema? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return SettingsSchema(jsonData: data)
    }
}
