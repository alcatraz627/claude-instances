import AppKit
import HostKernel

/// Lifecycle owner for the host. Installs crash reporting, wires up the
/// platform registry (which discovers + instantiates plugins, owns the
/// FSEvents watchers + event bus + resource sampler), the status-bar
/// controller, and the dashboard panel.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBar: StatusBarController?
    private var dashboard: DashboardController?
    private let platform = PlatformRegistry()
    private let settings = HostSettingsStore()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // FIRST so any subsequent setup failure is captured to crash.log.
        CrashReporter.install(logger: platform.hostLogger)
        platform.hostLogger.info("lifecycle",
            "applicationDidFinishLaunching (pid=\(getpid()))")

        platform.bootstrap()
        dashboard = DashboardController(platform: platform, settings: settings)
        statusBar = StatusBarController(
            onShowDashboard: { [weak self] in
                self?.platform.hostLogger.info("user.action", "menu.show-dashboard")
                self?.dashboard?.show()
            },
            onQuit: { [weak self] in
                self?.platform.hostLogger.info("user.action", "menu.quit")
                NSApp.terminate(nil)
            }
        )

        // User-action observers: settings changes + plugin toggles are
        // posted via NotificationCenter; convert each to a host.log line.
        NotificationCenter.default.addObserver(
            forName: .hostPluginToggled, object: nil, queue: .main
        ) { [weak self] note in
            if let pair = note.object as? (id: String, enabled: Bool) {
                self?.platform.hostLogger.info(
                    "user.action",
                    "plugin.toggle id=\(pair.id) enabled=\(pair.enabled)")
            }
        }
        NotificationCenter.default.addObserver(
            forName: .hostSettingsChanged, object: nil, queue: .main
        ) { [weak self] _ in
            self?.platform.hostLogger.info("user.action", "settings.change")
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        platform.hostLogger.info("lifecycle", "active")
    }

    func applicationDidResignActive(_ notification: Notification) {
        platform.hostLogger.info("lifecycle", "resigned-active")
    }

    func applicationWillTerminate(_ notification: Notification) {
        platform.hostLogger.info("lifecycle", "applicationWillTerminate")
        platform.bus.publish(HostTopics.shutdown)
        statusBar = nil
        dashboard = nil
    }
}
