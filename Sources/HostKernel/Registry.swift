import Foundation

/// Result of loading a single plugin manifest. Either a populated `Manifest`
/// (possibly with non-fatal warnings) or a fatal `PluginError`.
public struct LoadOutcome: Sendable {
    public let manifest: Manifest?
    public let warnings: [PluginWarning]
    public let error: PluginError?

    public var ok: Bool { manifest != nil && error == nil }

    public static func success(_ m: Manifest, warnings: [PluginWarning] = []) -> LoadOutcome {
        .init(manifest: m, warnings: warnings, error: nil)
    }
    public static func failure(_ e: PluginError) -> LoadOutcome {
        .init(manifest: nil, warnings: [], error: e)
    }
}

/// The plugin registry. Phase 2 ships the loader + validator + query API;
/// later phases add lifecycle (activate/deactivate), surface routing, and
/// resource tracking.
public final class Registry {
    public let hostVersion: SemVer
    public let supportedEnvelopes: Set<Int>

    /// Closed namespace of known contribution-point keys (string form).
    /// Unknown keys in `contributes` produce warnings, not errors.
    public static let knownContributionKeys: Set<String> = Set(
        ContributionPoint.allCases.map { $0.rawValue }
    )

    private(set) public var manifests: [String: Manifest] = [:]
    private(set) public var warnings: [PluginWarning] = []
    private(set) public var failures: [String: PluginError] = [:]   // keyed by path

    public init(hostVersion: SemVer, supportedEnvelopes: Set<Int> = [1]) {
        self.hostVersion = hostVersion
        self.supportedEnvelopes = supportedEnvelopes
    }

    // MARK: - Public API

    /// Load every `*/manifest.json` under the given root directory.
    /// Returns the per-path outcome. Side effect: populates `manifests`,
    /// `warnings`, `failures` on `self`.
    @discardableResult
    public func loadAll(in root: URL) -> [URL: LoadOutcome] {
        var results: [URL: LoadOutcome] = [:]
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil) else {
            return results
        }
        for childDir in children where (try? childDir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            let manifestURL = childDir.appendingPathComponent("manifest.json")
            guard fm.fileExists(atPath: manifestURL.path) else { continue }
            let outcome = load(manifestURL: manifestURL)
            results[manifestURL] = outcome
            switch (outcome.manifest, outcome.error) {
            case (let m?, nil):
                manifests[m.id] = m
                warnings.append(contentsOf: outcome.warnings)
            case (_, let err?):
                failures[manifestURL.path] = err
            default: break
            }
        }
        return results
    }

    /// Load a single manifest. Pure: does not mutate the registry's state.
    /// Caller decides whether to install the result.
    public func load(manifestURL: URL) -> LoadOutcome {
        let data: Data
        do { data = try Data(contentsOf: manifestURL) } catch {
            return .failure(.init(.manifestInvalid,
                "could not read \(manifestURL.lastPathComponent): \(error.localizedDescription)"))
        }
        return load(data: data, pluginDir: manifestURL.deletingLastPathComponent())
    }

    /// Load from raw bytes. Useful for tests and fixtures.
    public func load(data: Data, pluginDir: URL?) -> LoadOutcome {
        let decoder = JSONDecoder()
        var manifest: Manifest
        do {
            manifest = try decoder.decode(Manifest.self, from: data)
        } catch let DecodingError.keyNotFound(key, ctx) {
            return .failure(.init(.manifestInvalid,
                "missing required field '\(key.stringValue)' at \(prettyPath(ctx.codingPath))"))
        } catch let DecodingError.typeMismatch(_, ctx) {
            return .failure(.init(.manifestInvalid,
                "type mismatch at \(prettyPath(ctx.codingPath)): \(ctx.debugDescription)"))
        } catch let DecodingError.dataCorrupted(ctx) {
            return .failure(.init(.manifestInvalid,
                "JSON parse error: \(ctx.debugDescription)"))
        } catch {
            return .failure(.init(.manifestInvalid,
                "decode failed: \(error.localizedDescription)"))
        }

        manifest.pluginDir = pluginDir

        // Envelope version gate
        guard supportedEnvelopes.contains(manifest.manifestVersion) else {
            return .failure(.init(.manifestUnsupportedEnvelope,
                "plugin '\(manifest.id)' declares manifest_version=\(manifest.manifestVersion); host supports \(supportedEnvelopes.sorted())"))
        }

        // Engines gate
        guard let range = SemVerRange(manifest.engines.claudeInstances) else {
            return .failure(.init(.manifestInvalid,
                "engines.claude-instances is not a valid semver range: '\(manifest.engines.claudeInstances)'"))
        }
        guard range.contains(hostVersion) else {
            return .failure(.init(.enginesMismatch,
                "plugin '\(manifest.id)' wants host \(manifest.engines.claudeInstances); host is \(hostVersion)",
                actionable: "Bump plugin's engines range or upgrade the host."))
        }

        // At least one contribution required
        guard manifest.hasAnyContribution else {
            return .failure(.init(.manifestInvalid,
                "plugin '\(manifest.id)' contributes nothing — at least one entry in 'contributes' is required"))
        }

        // Unknown-key warnings on contributes (forward-compat for future contribution points)
        var pluginWarnings: [PluginWarning] = []
        if let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let contributes = raw["contributes"] as? [String: Any] {
            for key in contributes.keys where !Registry.knownContributionKeys.contains(key) {
                pluginWarnings.append(.init(pluginId: manifest.id,
                    message: "unknown contribution-point '\(key)' — preserved for forward-compat but not rendered"))
            }
        }

        // Stubbed-surface advisory warnings
        for point in ContributionPoint.allCases where !point.isShipped {
            let count = countContributions(manifest: manifest, point: point)
            if count > 0 {
                pluginWarnings.append(.init(pluginId: manifest.id,
                    message: "declares '\(point.rawValue)' (\(count) item(s)) — surface stubbed in V1, will activate in a later release"))
            }
        }

        return .success(manifest, warnings: pluginWarnings)
    }

    // MARK: - Query

    public func contributions<T>(_ point: ContributionPoint, as type: T.Type) -> [T] {
        var out: [T] = []
        for m in manifests.values {
            switch point {
            case .commands: out.append(contentsOf: (m.contributes.commands as? [T]) ?? [])
            case .dashboardPane: out.append(contentsOf: (m.contributes.dashboardPane as? [T]) ?? [])
            case .settingsSection: out.append(contentsOf: (m.contributes.settingsSection as? [T]) ?? [])
            case .eventSubscriptions: out.append(contentsOf: (m.contributes.eventSubscriptions as? [T]) ?? [])
            case .hotkey: out.append(contentsOf: (m.contributes.hotkey as? [T]) ?? [])
            case .menubarItem: out.append(contentsOf: (m.contributes.menubarItem as? [T]) ?? [])
            case .statusbarBadge: out.append(contentsOf: (m.contributes.statusbarBadge as? [T]) ?? [])
            case .quickAction: out.append(contentsOf: (m.contributes.quickAction as? [T]) ?? [])
            case .floater: out.append(contentsOf: (m.contributes.floater as? [T]) ?? [])
            case .notificationHandler: out.append(contentsOf: (m.contributes.notificationHandler as? [T]) ?? [])
            }
        }
        return out
    }

    // MARK: - Internal helpers

    private func countContributions(manifest: Manifest, point: ContributionPoint) -> Int {
        switch point {
        case .commands: return manifest.contributes.commands?.count ?? 0
        case .dashboardPane: return manifest.contributes.dashboardPane?.count ?? 0
        case .settingsSection: return manifest.contributes.settingsSection?.count ?? 0
        case .eventSubscriptions: return manifest.contributes.eventSubscriptions?.count ?? 0
        case .hotkey: return manifest.contributes.hotkey?.count ?? 0
        case .menubarItem: return manifest.contributes.menubarItem?.count ?? 0
        case .statusbarBadge: return manifest.contributes.statusbarBadge?.count ?? 0
        case .quickAction: return manifest.contributes.quickAction?.count ?? 0
        case .floater: return manifest.contributes.floater?.count ?? 0
        case .notificationHandler: return manifest.contributes.notificationHandler?.count ?? 0
        }
    }

    private func prettyPath(_ keys: [CodingKey]) -> String {
        keys.map { $0.stringValue }.joined(separator: ".")
    }
}
