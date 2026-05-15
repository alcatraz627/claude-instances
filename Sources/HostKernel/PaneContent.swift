import Foundation

/// The runtime payload a `dashboard.pane` produces. This is what `fetch.sh`
/// emits as JSON, what a native plugin's `render(_:)` returns, and what the
/// surface router passes to the SwiftUI pane views.
///
/// Each case carries the kind-specific shape. Unknown kinds at runtime
/// degrade to `.error(.fetchSchemaViolation, ...)`.
public enum PaneContent: Sendable {
    case summary(SummaryContent)
    case table(TableContent)
    case schedule(ScheduleContent)
    case assets(AssetsContent)
    case log(LogContent)
    case error(PluginError)
}

// MARK: - Summary

public struct SummaryContent: Codable, Sendable, Equatable {
    public var tiles: [Tile]

    public struct Tile: Codable, Sendable, Equatable {
        public var label: String
        public var value: String
        public var trend: String?
        public var badge: String?
        public var tone: Tone?
        public var progressPct: Double?

        enum CodingKeys: String, CodingKey {
            case label, value, trend, badge, tone
            case progressPct = "progress_pct"
        }

        public init(label: String, value: String, trend: String? = nil,
                    badge: String? = nil, tone: Tone? = nil, progressPct: Double? = nil) {
            self.label = label; self.value = value; self.trend = trend
            self.badge = badge; self.tone = tone; self.progressPct = progressPct
        }
    }
}

public enum Tone: String, Codable, Sendable, CaseIterable {
    case ok, warn, error, dim, none
}

// MARK: - Table

public struct TableContent: Codable, Sendable, Equatable {
    public var columns: [Column]
    public var rows: [Row]
    public var empty: String?
    public var truncatedAt: Int?
    public var hasMore: Bool?

    public struct Column: Codable, Sendable, Equatable {
        public var id: String
        public var label: String
        public var width: WidthSpec?
        public var align: Alignment?

        public enum Alignment: String, Codable, Sendable {
            case leading, trailing, center
        }
    }

    public enum WidthSpec: Codable, Sendable, Equatable {
        case fixed(Double)      // points
        case flex               // takes remaining space

        public init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let d = try? c.decode(Double.self) {
                self = .fixed(d)
            } else if let s = try? c.decode(String.self), s == "flex" {
                self = .flex
            } else {
                throw DecodingError.dataCorruptedError(
                    in: c, debugDescription: "width must be a number or 'flex'")
            }
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .fixed(let d): try c.encode(d)
            case .flex: try c.encode("flex")
            }
        }
    }

    /// A row is column-id → cell value. Cells may also carry a `row_actions`
    /// list of command-id chips on the trailing edge.
    public struct Row: Codable, Sendable, Equatable {
        public var cells: [String: String]    // column id -> rendered cell
        public var rowActions: [RowAction]?

        public init(cells: [String: String], rowActions: [RowAction]? = nil) {
            self.cells = cells; self.rowActions = rowActions
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            var cells: [String: String] = [:]
            var actions: [RowAction]? = nil
            for key in c.allKeys {
                if key.stringValue == "row_actions" {
                    actions = try c.decodeIfPresent([RowAction].self, forKey: key)
                } else if let s = try? c.decode(String.self, forKey: key) {
                    cells[key.stringValue] = s
                } else if let i = try? c.decode(Int.self, forKey: key) {
                    cells[key.stringValue] = String(i)
                } else if let d = try? c.decode(Double.self, forKey: key) {
                    cells[key.stringValue] = String(d)
                } else if let b = try? c.decode(Bool.self, forKey: key) {
                    cells[key.stringValue] = b ? "yes" : "no"
                }
            }
            self.cells = cells
            self.rowActions = actions
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: AnyKey.self)
            for (k, v) in cells {
                try c.encode(v, forKey: AnyKey(stringValue: k)!)
            }
            if let a = rowActions {
                try c.encode(a, forKey: AnyKey(stringValue: "row_actions")!)
            }
        }
    }

    public struct RowAction: Codable, Sendable, Equatable {
        public var label: String
        public var command: String
        public var args: [String: AnyCodable]?
        public var destructive: Bool?
    }

    enum CodingKeys: String, CodingKey {
        case columns, rows, empty
        case truncatedAt = "truncated_at"
        case hasMore     = "has_more"
    }
}

// MARK: - Schedule

public struct ScheduleContent: Codable, Sendable, Equatable {
    public var items: [Item]

    public struct Item: Codable, Sendable, Equatable {
        public var id: String
        public var source: String         // "cron" | "launchd" | etc.
        public var when: String           // human-readable
        public var nextRun: String?       // ISO-8601
        public var command: String
        public var enabled: Bool
        public var logPath: String?

        enum CodingKeys: String, CodingKey {
            case id, source, when, command, enabled
            case nextRun = "next_run"
            case logPath = "log_path"
        }
    }
}

// MARK: - Assets

public struct AssetsContent: Codable, Sendable, Equatable {
    public var items: [Item]

    public struct Item: Codable, Sendable, Equatable {
        public var path: String
        public var label: String
        public var sizeBytes: Int?
        public var mtime: String?
        public var openWith: OpenWith?

        public enum OpenWith: String, Codable, Sendable {
            // Raw value stays "default" so manifest JSON is unchanged; we rename
            // the Swift case to dodge the keyword conflict at use sites.
            case auto = "default"
            case browser, vscode, terminal
        }

        enum CodingKeys: String, CodingKey {
            case path, label, mtime
            case sizeBytes = "size_bytes"
            case openWith  = "open_with"
        }
    }
}

// MARK: - Log

public struct LogContent: Sendable, Equatable {
    public var label: String?
    public var text: String

    public init(label: String? = nil, text: String) {
        self.label = label; self.text = text
    }
}

// MARK: - Helper coding key for dynamic dicts

struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
