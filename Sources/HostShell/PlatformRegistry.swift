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
    @Published public private(set) var samplerTick: Int = 0   // bumped on each sample

    /// Cross-plugin runtime services. Plugins receive references to these
    /// in their HostContext on activation.
    public let bus = EventBus()
    public let sampler = ResourceSampler()
    public let hostLogger: HostLogger
    private var pluginLoggers: [String: HostLogger] = [:]
    private var minuteTimer: Timer?
    private var fiveSecondTimer: Timer?

    private let kernel: Registry
    private let bundled: BundledPluginRegistry

    public init(kernel: Registry? = nil,
                bundled: BundledPluginRegistry? = nil) {
        self.kernel = kernel ?? Registry(hostVersion: HostKernel.semver)
        self.bundled = bundled ?? .shared
        self.hostLogger = FileLogger(source: "host", baseDir: HostLogPaths.baseDir)
        self.hostLogger.info("startup", "PlatformRegistry init (host \(HostKernel.version))")
    }

    public func bootstrap() {
        guard !bootstrapped else { return }
        bundled.bootstrap()

        if let pluginsDir = PlatformRegistry.locatePluginsDir() {
            kernel.loadAll(in: pluginsDir)
            hostLogger.info("registry", "loaded \(kernel.manifests.count) manifests from \(pluginsDir.path)")
        } else {
            hostLogger.warn("registry", "no plugins/ directory found at any candidate path")
        }
        manifests = Array(kernel.manifests.values).sorted { $0.id < $1.id }
        warnings = kernel.warnings
        for w in warnings {
            hostLogger.warn("manifest", w.description)
        }

        // Start the periodic tick timers + emit host.startup.
        bus.publish(HostTopics.startup)
        startTimers()

        bootstrapped = true
    }

    /// Returns the per-plugin logger; creates one on first use.
    public func logger(for pluginId: String) -> HostLogger {
        if let l = pluginLoggers[pluginId] { return l }
        let dir = HostLogPaths.pluginLogDir()
        let l = FileLogger(source: pluginId, baseDir: dir)
        pluginLoggers[pluginId] = l
        return l
    }

    private func startTimers() {
        // 5-second tick — bumps a counter so resource-stats UI re-renders,
        // and fires host.tick.5s on the bus for any subscribers.
        fiveSecondTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.samplerTick &+= 1
                self.bus.publish(HostTopics.tickFiveSec)
            }
        }
        // 60-second tick — resets minute counters + fires host.tick.minute.
        minuteTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.sampler.resetMinuteCounters()
                self.bus.publish(HostTopics.tickMinute)
            }
        }
    }

    deinit {
        minuteTimer?.invalidate()
        fiveSecondTimer?.invalidate()
    }

    /// Look up the plugin instance for a manifest. Currently only native
    /// matches are returned; script-plugin dispatch arrives in Phase 5.
    public func plugin(for manifest: Manifest) -> (any Plugin)? {
        bundled.instance(forId: manifest.id)
    }

    /// Returns every `dashboard.pane` contribution from every loaded manifest,
    /// grouped by `section` (preserving insertion order within each section).
    public func dashboardSections(disabledIds: Set<String> = []) -> [(section: String, items: [(Manifest, DashboardPane)])] {
        var byCategory: [String: [(Manifest, DashboardPane)]] = [:]
        var order: [String] = []
        for m in manifests where !disabledIds.contains(m.id) {
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
