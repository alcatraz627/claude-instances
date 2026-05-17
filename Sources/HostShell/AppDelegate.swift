import AppKit
import HostKernel

/// Lifecycle owner for the host. Installs crash reporting, wires up the
/// platform registry (which discovers + instantiates plugins, owns the
/// event bus + resource sampler), the status-bar controller, the
/// menubar / badge surfaces (Phase 12), and the dashboard panel.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBar: StatusBarController?
    private var dashboard: DashboardController?
    private var menubar: MenubarSurface?
    private var badgeSurface: StatusbarBadgeSurface?
    private let platform = PlatformRegistry()
    private let settings = HostSettingsStore()

    func applicationDidFinishLaunching(_ notification: Notification) {
        CrashReporter.install(logger: platform.hostLogger)
        platform.hostLogger.info("lifecycle",
            "applicationDidFinishLaunching (pid=\(getpid()))")

        // Bridge settings + design into PlatformRegistry so surface code
        // can query them without dragging the store around.
        platform.settingsBridge = { [unowned settings = self.settings] in settings.settings }
        platform.designBridge = { [unowned settings = self.settings] in settings.design }

        platform.bootstrap()
        dashboard = DashboardController(platform: platform, settings: settings)
        statusBar = StatusBarController()

        // Phase 12 surfaces: menubar.item + statusbar.badge.
        if let menu = statusBar?.menu {
            menubar = MenubarSurface(
                menu: menu,
                platform: platform,
                onShowDashboard: { [weak self] in
                    self?.platform.hostLogger.info("user.action", "menu.show-dashboard")
                    self?.dashboard?.show()
                },
                onQuit: { [weak self] in
                    self?.platform.hostLogger.info("user.action", "menu.quit")
                    NSApp.terminate(nil)
                }
            )
        }
        badgeSurface = StatusbarBadgeSurface(platform: platform)

        // User-action observers — convert NotificationCenter posts to
        // host.log lines and reconcile surfaces on plugin toggle.
        NotificationCenter.default.addObserver(
            forName: .hostPluginToggled, object: nil, queue: .main
        ) { [weak self] note in
            if let pair = note.object as? (id: String, enabled: Bool) {
                self?.platform.hostLogger.info(
                    "user.action",
                    "plugin.toggle id=\(pair.id) enabled=\(pair.enabled)")
                self?.menubar?.rebuild()
                self?.badgeSurface?.reconcile()
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
        menubar = nil
        badgeSurface = nil
    }
}
