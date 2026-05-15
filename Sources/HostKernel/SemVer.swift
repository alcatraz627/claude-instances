import Foundation

/// A minimal semantic version + range matcher.
///
/// The kernel uses this to honor a plugin manifest's `engines.claude-instances`
/// declaration. We support exact, caret, and tilde ranges — enough for the
/// host-vs-plugin compatibility contract documented in v2-architecture.md §13.
/// Pre-release suffixes are parsed but ignored for ordering.
public struct SemVer: Equatable, Comparable, CustomStringConvertible, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public let preRelease: String?

    public init(major: Int, minor: Int, patch: Int, preRelease: String? = nil) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.preRelease = preRelease
    }

    public init?(_ s: String) {
        let mainAndPre = s.split(separator: "-", maxSplits: 1).map(String.init)
        let parts = mainAndPre[0].split(separator: ".").map(String.init)
        guard parts.count == 3,
              let major = Int(parts[0]),
              let minor = Int(parts[1]),
              let patch = Int(parts[2])
        else { return nil }
        self.major = major
        self.minor = minor
        self.patch = patch
        self.preRelease = mainAndPre.count > 1 ? mainAndPre[1] : nil
    }

    public static func < (lhs: SemVer, rhs: SemVer) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }

    public var description: String {
        let base = "\(major).\(minor).\(patch)"
        return preRelease.map { "\(base)-\($0)" } ?? base
    }
}

/// A range expression matchable against a `SemVer`. Supports the operators
/// the manifest spec actually uses; not a full npm-style grammar.
public enum SemVerRange: Equatable, Sendable {
    case exact(SemVer)
    case caret(SemVer)        // ^1.2.3  -> >=1.2.3, <2.0.0
    case tilde(SemVer)        // ~1.2.3  -> >=1.2.3, <1.3.0
    case atLeast(SemVer)      // >=1.2.3

    public init?(_ s: String) {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("^"), let v = SemVer(String(trimmed.dropFirst())) {
            self = .caret(v)
        } else if trimmed.hasPrefix("~"), let v = SemVer(String(trimmed.dropFirst())) {
            self = .tilde(v)
        } else if trimmed.hasPrefix(">="), let v = SemVer(String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)) {
            self = .atLeast(v)
        } else if let v = SemVer(trimmed) {
            self = .exact(v)
        } else {
            return nil
        }
    }

    public func contains(_ v: SemVer) -> Bool {
        switch self {
        case .exact(let target): return v == target
        case .atLeast(let lower): return v >= lower
        case .caret(let lower):
            let upper = SemVer(major: lower.major + 1, minor: 0, patch: 0)
            return v >= lower && v < upper
        case .tilde(let lower):
            let upper = SemVer(major: lower.major, minor: lower.minor + 1, patch: 0)
            return v >= lower && v < upper
        }
    }

    /// `true` if the range accepts only one specific version. Brittle for plugin
    /// authors — they meant `^X.Y.Z` for "any patch within this major" but pinned
    /// exact instead. The registry surfaces this as a warning.
    public var isExactPin: Bool {
        if case .exact = self { return true }
        return false
    }
}
