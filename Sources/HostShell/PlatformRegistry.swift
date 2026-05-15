import Foundation
import HostKernel
import SwiftUI

/// SwiftUI-observable wrapper around the kernel `Registry` + the host's
/// `BundledPluginRegistry`. Discovers manifests from disk, matches each
/// to a Swift plugin instance, and exposes a sidebar-ready view of the
/// loaded contributions.
///
/// Phase 4 wires this minimally: bootstrap once at app launch, no
/// hot-reload, no per-plugin activation calls (the protocol's
/// `activate(host:)` exists but is invoked lazily via render).
@MainActor
public final class PlatformRegistry: ObservableObject {
    @Published public private(set) var manifests: [Manifest] = []
    @Published public private(set) var warnings: [PluginWarning] = []
    @Published public private(set) var bootstrapped: Bool = false

    private let kernel: Registry
    private let bundled: BundledPluginRegistry

    public init(kernel: Registry? = nil,
                bundled: BundledPluginRegistry? = nil) {
        self.kernel = kernel ?? Registry(hostVersion: HostKernel.semver)
        self.bundled = bundled ?? .shared
    }

    public func bootstrap() {
        guard !bootstrapped else { return }
        bundled.bootstrap()

        if let pluginsDir = PlatformRegistry.locatePluginsDir() {
            kernel.loadAll(in: pluginsDir)
        }
        manifests = Array(kernel.manifests.values).sorted { $0.id < $1.id }
        warnings = kernel.warnings
        bootstrapped = true
    }

    /// Look up the plugin instance for a manifest. Currently only native
    /// matches are returned; script-plugin dispatch arrives in Phase 5.
    public func plugin(for manifest: Manifest) -> (any Plugin)? {
        bundled.instance(forId: manifest.id)
    }

    /// Returns every `dashboard.pane` contribution from every loaded manifest,
    /// grouped by `section` (preserving insertion order within each section).
    public func dashboardSections() -> [(section: String, items: [(Manifest, DashboardPane)])] {
        var byCategory: [String: [(Manifest, DashboardPane)]] = [:]
        var order: [String] = []
        for m in manifests {
            for contribution in m.contributes.dashboardPane ?? [] {
                let key = contribution.section ?? "Plugins"
                if byCategory[key] == nil {
                    byCategory[key] = []
                    order.append(key)
                }
                byCategory[key]!.append((m, contribution))
            }
        }
        return order.map { (section: $0, items: byCategory[$0]!) }
    }

    // MARK: - Plugin directory discovery

    /// Find the `plugins/` directory at runtime. When launched as the .app
    /// bundle, manifests live under `Contents/Resources/plugins/`; build.sh
    /// copies them there. When running via `swift run` from the worktree
    /// root, they're at `./plugins/`. We try each in order.
    static func locatePluginsDir() -> URL? {
        let fm = FileManager.default

        // 1. Bundled .app
        if let resourceURL = Bundle.main.resourceURL {
            let bundled = resourceURL.appendingPathComponent("plugins", isDirectory: true)
            if fm.fileExists(atPath: bundled.path) {
                return bundled
            }
        }

        // 2. Dev: working directory
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath)
        let inCwd = cwd.appendingPathComponent("plugins", isDirectory: true)
        if fm.fileExists(atPath: inCwd.path) {
            return inCwd
        }

        // 3. Fall through: no plugins available. Host renders an empty
        // sidebar; not a fatal error.
        return nil
    }
}
