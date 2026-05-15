import AppKit
import HostKernel

/// Lifecycle owner for the host. Wires up the status-bar controller, the
/// platform registry (which discovers + instantiates native plugins), and
/// the dashboard panel at launch; tears them down at quit. Phase 6 will add
/// the resource sampler + real event bus here.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBar: StatusBarController?
    private var dashboard: DashboardController?
    private let platform = PlatformRegistry()
    private let settings = HostSettingsStore()

    func applicationDidFinishLaunching(_ notification: Notification) {
        platform.bootstrap()
        dashboard = DashboardController(platform: platform, settings: settings)
        statusBar = StatusBarController(
            onShowDashboard: { [weak self] in self?.dashboard?.show() },
            onQuit: { NSApp.terminate(nil) }
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusBar = nil
        dashboard = nil
    }
}
