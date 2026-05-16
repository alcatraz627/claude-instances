import AppKit
import SwiftUI

/// Owns the dashboard NSPanel. NSPanel is the right primitive for a status-
/// icon-driven dashboard: lightweight, non-key-activating by default, can be
/// shown/hidden without participating in normal window cycling. The SwiftUI
/// root lives inside an NSHostingController; the platform + settings stores
/// are injected via Environment so plugins below see the same registry the
/// AppDelegate owns.
@MainActor
final class DashboardController {
    private let platform: PlatformRegistry
    private let settings: HostSettingsStore
    private var panel: NSPanel?

    init(platform: PlatformRegistry, settings: HostSettingsStore) {
        self.platform = platform
        self.settings = settings
    }

    func show() {
        if panel == nil {
            panel = makePanel()
        }
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 560),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Dashboard"
        // SwiftUI -> NSPanel title bridge. NSPanel ignores SwiftUI's
        // .navigationTitle modifier, so child views call this closure when
        // the selected page changes. The title bar is narrow, so we put
        // ONLY the page name there — Activity-Monitor / System-Settings
        // pattern. App identity is conveyed by the menu-bar icon + window
        // existence.
        let root = DashboardRootView(onTitleChange: { [weak panel] page in
            panel?.title = page.isEmpty ? "Dashboard" : page
        })
            .environmentObject(platform)
            .environmentObject(settings)
            .environment(\.design, settings.design)
            .preferredColorScheme(settings.preferredColorScheme)
        panel.contentViewController = NSHostingController(rootView: root)
        panel.center()
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        return panel
    }
}
