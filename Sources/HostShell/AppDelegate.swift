import AppKit
import HostKernel

/// Lifecycle owner for the host. Wires up the status-bar controller and the dashboard
/// panel at launch; tears them down at quit. Plugin registry + event bus will be
/// instantiated here in later phases.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBar: StatusBarController?
    private var dashboard: DashboardController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        dashboard = DashboardController()
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
