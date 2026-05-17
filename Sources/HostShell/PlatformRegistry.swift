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
    /// FSEvents watchers, one per plugin that declared `refresh.on_fs_change`.
    /// Owned by the registry so their lifetime doesn't depend on transient
    /// SwiftUI views — a callback firing after a view is destroyed used to
    /// crash via dangling environment references (see PaneHolder Phase-6
    /// crash report). Now watchers publish to the bus; views subscribe via
    /// SwiftUI .onReceive which handles its own teardown.
    private var watchers: [String: FSEventsWatcher] = [:]

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
        installWatchers()

        // Check for + log any pre-session crash artifacts.
        if let prev = CrashReporter.consumePrevious() {
            for line in prev.split(separator: "\n") {
                hostLogger.error("prev-session-crash", String(line))
            }
        }

        bootstrapped = true
    }

    /// **DISABLED 2026-05-17** — FSEvents has caused 3 SIGSEGVs in
    /// `objc_msgSend_uncached` from inside the FSEventStreamCallback,
    /// even after correct retain/release lifetime + PlatformRegistry-owned
    /// watchers. The crash signature is identical across attempts; the
    /// macOS Tahoe runtime appears to have an issue with our wrapping
    /// pattern that I can't reproduce reliably enough to fix.
    ///
    /// Replaced with safety-net polling on PaneHolder side. Plugins that
    /// declared `refresh.on_fs_change` now refresh on their `poll_seconds`
    /// cadence instead of on-change. Tradeoff: a few seconds of staleness
    /// in exchange for stability. Per architecture §17 PERF-001 (TBD,
    /// stability wins over "lightweight" when the latter crashes).
    ///
    /// Re-enable when we have a proper Swift wrapper (e.g.
    /// FilesProvider-style or DispatchSource-based) that survives the
    /// crash conditions.
    private func installWatchers() {
        let total = manifests.compactMap { $0.refresh?.onFsChange }.filter { !$0.isEmpty }.count
        if total > 0 {
            hostLogger.warn("watchers",
                "FSEvents disabled (KNOWN-ISSUE FSEVENTS-001); \(total) plugin(s) " +
                "would have used FSEvents — falling back to poll_seconds cadence")
        }
    }

    /// Returns the per-plugin logger; creates one on first use.
    public func logger(for pluginId: String) -> HostLogger {
        if let l = pluginLoggers[pluginId] { return l }
        let dir = HostLogPaths.pluginLogDir()
        let l = FileLogger(source: pluginId, baseDir: dir)
        pluginLoggers[pluginId] = l
        return l
    }

    /// Settings + design bridge so surface code doesn't have to pass
    /// HostSettingsStore around separately. AppDelegate sets this once
    /// at bootstrap.
    public var settingsBridge: (() -> HostSettings)?
    public var designBridge: (() -> ResolvedDesign)?

    public func isEnabled(_ pluginId: String) -> Bool {
        settingsBridge?().isPluginEnabled(pluginId) ?? true
    }

    public func currentDesign() -> ResolvedDesign {
        designBridge?() ?? ResolvedDesign(settings: HostSettings())
    }

    /// Generic command dispatch. Native plugins handle via runCommand;
    /// script plugins via actions.sh invocation. Used by menubar items,
    /// hotkeys, and row actions.
    public func runCommand(pluginId: String,
                            commandId: String,
                            args: [String: AnyCodable]?) async {
        guard let manifest = manifests.first(where: { $0.id == pluginId }) else {
            hostLogger.warn("runCommand", "unknown plugin id: \(pluginId)")
            return
        }
        let argsDict = args ?? [:]
        let logger = self.logger(for: pluginId)
        logger.info("command", "invoke \(commandId)")

        // Native path
        if let plugin = plugin(for: manifest) {
            do {
                let result = try await plugin.runCommand(commandId, args: argsDict)
                logger.info("command", "ok exit=\(result.exitCode)")
            } catch {
                logger.error("command", "threw: \(error.localizedDescription)")
            }
            return
        }

        // Script path
        if let action = manifest.exec.action, let dir = manifest.pluginDir {
            let exec = URL(fileURLWithPath: action, relativeTo: dir).standardizedFileURL
            guard FileManager.default.isExecutableFile(atPath: exec.path) else {
                logger.warn("command", "actions.sh not executable: \(exec.path)")
                return
            }
            do {
                let result = try await ScriptExec.run(
                    executable: exec, args: [commandId], cwd: dir,
                    env: [
                        "CLAUDE_PLUGIN_ID": pluginId,
                        "CLAUDE_HOST_VERSION": HostKernel.version,
                    ],
                    timeoutMs: 5000)
                logger.info("command",
                    "exit=\(result.exitCode) elapsed=\(result.elapsedMs)ms")
            } catch {
                logger.error("command", "spawn failed: \(error.localizedDescription)")
            }
        } else {
            logger.warn("command",
                "no native plugin and no exec.action — command \(commandId) ignored")
        }
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
