import AppKit

/// Owns the `NSStatusItem` and its dropdown menu. Phase 1 ships the minimum: app
/// title, "Show Dashboard…", and "Quit". Plugin contributions to `menubar.item`
/// will compose into this menu in Phase 12.
final class StatusBarController {
    private let statusItem: NSStatusItem
    private let menu: NSMenu
    private let onShowDashboard: () -> Void
    private let onQuit: () -> Void

    init(onShowDashboard: @escaping () -> Void, onQuit: @escaping () -> Void) {
        self.onShowDashboard = onShowDashboard
        self.onQuit = onQuit

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "puzzlepiece.extension.fill",
                accessibilityDescription: "claude-instances V2"
            )
            button.image?.isTemplate = true
        }

        menu = NSMenu()
        menu.addItem(headerItem(title: "claude-instances V2 (preview)"))
        menu.addItem(.separator())

        let dashboardItem = NSMenuItem(
            title: "Show Dashboard…",
            action: #selector(handleShowDashboard),
            keyEquivalent: "d"
        )
        dashboardItem.target = self
        menu.addItem(dashboardItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit",
            action: #selector(handleQuit),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func headerItem(title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func handleShowDashboard() {
        onShowDashboard()
    }

    @objc private func handleQuit() {
        onQuit()
    }
}
