import AppKit
import HostKernel

/// Owns the main NSStatusItem's NSMenu. Each plugin's `menubar.item`
/// contribution becomes a top-level submenu (or single command) item.
/// Rich rows (from "dynamic" submenu entries) are rendered via pure
/// AppKit NSView subclasses — deliberately avoiding NSHostingView/SwiftUI
/// inside NSMenuItem.view because that bridge has caused crashes in this
/// codebase (cf. FSEVENTS-001) and the visual richness we need is
/// trivially achievable with NSTextField + NSImageView.
@MainActor
final class MenubarSurface: NSObject, NSMenuDelegate {
    private let menu: NSMenu
    private let platform: PlatformRegistry
    private let onShowDashboard: () -> Void
    private let onQuit: () -> Void
    /// Per-submenu cached rows, keyed by `<plugin-id>.<submenu-id>`.
    private var dynamicCache: [String: [MenubarRow]] = [:]

    init(menu: NSMenu,
         platform: PlatformRegistry,
         onShowDashboard: @escaping () -> Void,
         onQuit: @escaping () -> Void) {
        self.menu = menu
        self.platform = platform
        self.onShowDashboard = onShowDashboard
        self.onQuit = onQuit
        super.init()
        menu.delegate = self
        rebuild()
    }

    // MARK: - Build

    /// Top-level menu layout:
    ///   - "claude-instances V2"  (disabled header)
    ///   - separator
    ///   - Per-plugin menubar.item contributions (enabled plugins only)
    ///   - separator
    ///   - "Show Dashboard…" (⌘D)
    ///   - "Quit" (⌘Q)
    func rebuild() {
        menu.removeAllItems()
        menu.addItem(disabled(title: "claude-instances V2"))
        menu.addItem(.separator())

        var any = false
        for manifest in platform.manifests {
            guard platform.isEnabled(manifest.id) else { continue }
            for item in manifest.contributes.menubarItem ?? [] {
                addMenubarItem(manifest: manifest, item: item)
                any = true
            }
        }
        if any { menu.addItem(.separator()) }

        let dashItem = NSMenuItem(title: "Show Dashboard…",
            action: #selector(handleDashboard), keyEquivalent: "d")
        dashItem.target = self
        menu.addItem(dashItem)

        let quitItem = NSMenuItem(title: "Quit",
            action: #selector(handleQuit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    // MARK: - Per-plugin item construction

    private func addMenubarItem(manifest: Manifest, item: MenubarItem) {
        let title = item.title ?? manifest.name
        let topItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        // HotkeyAwareMenu lets ⌘<digit>/etc on rich (view-based) rows
        // actually fire — AppKit's default NSMenu ignores keyEquivalent
        // on items with a custom view.
        let submenu = HotkeyAwareMenu()
        submenu.delegate = self
        submenu.identifier = NSUserInterfaceItemIdentifier("ci.menu.\(manifest.id).\(item.id)")
        topItem.submenu = submenu
        menu.addItem(topItem)
        populate(submenu: submenu, manifest: manifest, item: item)
    }

    /// Build (or rebuild) a submenu's items from the manifest spec.
    private func populate(submenu: NSMenu, manifest: Manifest, item: MenubarItem) {
        submenu.removeAllItems()
        for entry in item.submenu ?? [] {
            switch entry.kind {
            case "separator":
                submenu.addItem(.separator())
            case "command":
                guard let cmdId = entry.command,
                      let cmd = manifest.contributes.commands?.first(where: { $0.id == cmdId })
                else {
                    submenu.addItem(disabled(title: "missing command: \(entry.command ?? "?")"))
                    continue
                }
                let mi = NSMenuItem(title: cmd.title,
                    action: #selector(handleCommand(_:)), keyEquivalent: "")
                mi.target = self
                mi.representedObject = PendingCommand(
                    pluginId: manifest.id, commandId: cmdId, args: nil)
                submenu.addItem(mi)
            case "link":
                if let label = entry.label, let url = entry.url, !url.isEmpty {
                    let mi = NSMenuItem(title: label,
                        action: #selector(handleLink(_:)), keyEquivalent: "")
                    mi.target = self
                    mi.representedObject = url
                    submenu.addItem(mi)
                }
            case "static":
                submenu.addItem(disabled(title: entry.label ?? "(unlabeled)"))
            case "dynamic":
                // Lazy: render a placeholder; the delegate's menuWillOpen
                // populates with real rows from the plugin.
                let placeholder = NSMenuItem(title: "(loading…)",
                    action: nil, keyEquivalent: "")
                placeholder.isEnabled = false
                placeholder.identifier = NSUserInterfaceItemIdentifier("ci.placeholder")
                submenu.addItem(placeholder)
                // Remember the contribution + source so menuWillOpen can fetch.
                submenu.title = "ci.dynamic|\(manifest.id)|\(item.id)|\(entry.source ?? "")"
            default:
                submenu.addItem(disabled(title: "unknown submenu kind: \(entry.kind)"))
            }
        }
    }

    // MARK: - Dynamic fetch (on submenu open)

    nonisolated func menuWillOpen(_ menu: NSMenu) {
        Task { @MainActor in
            await refreshDynamic(in: menu)
        }
    }

    @MainActor
    private func refreshDynamic(in submenu: NSMenu) async {
        // Title encodes "ci.dynamic|<pluginId>|<itemId>|<source>"
        let title = submenu.title
        guard title.hasPrefix("ci.dynamic|") else { return }
        let parts = title.split(separator: "|").map(String.init)
        guard parts.count == 4 else { return }
        let pluginId = parts[1], itemId = parts[2], source = parts[3]

        let rows = await fetchRows(pluginId: pluginId, itemId: itemId, source: source)
        // Replace placeholder rows with rich rows
        submenu.removeAllItems()
        if rows.isEmpty {
            submenu.addItem(disabled(title: "(no items)"))
            return
        }
        for row in rows {
            let mi = NSMenuItem()
            mi.view = RichMenuRowView(row: row, design: platform.currentDesign())
            if let ke = row.keyEquivalent, !ke.isEmpty {
                mi.keyEquivalent = ke
            }
            if let cmd = row.commandId {
                mi.target = self
                mi.action = #selector(handleCommand(_:))
                mi.representedObject = PendingCommand(
                    pluginId: pluginId, commandId: cmd, args: row.commandArgs)
            }
            submenu.addItem(mi)
        }
    }

    private func fetchRows(pluginId: String, itemId: String, source: String) async -> [MenubarRow] {
        let cacheKey = "\(pluginId).\(itemId)"
        guard let manifest = platform.manifests.first(where: { $0.id == pluginId })
        else { return [] }

        // Native: invoke plugin.menubarRows.
        if let plugin = platform.plugin(for: manifest) {
            if let rows = try? await plugin.menubarRows(submenuId: source) {
                dynamicCache[cacheKey] = rows
                return rows
            }
        }
        // Script: invoke fetch.sh with the source argv tokens.
        if manifest.exec.kind == .script,
           let fetch = manifest.exec.fetch,
           let dir = manifest.pluginDir {
            let exec = URL(fileURLWithPath: fetch, relativeTo: dir).standardizedFileURL
            let args = source.split(separator: " ").map(String.init)
            if FileManager.default.isExecutableFile(atPath: exec.path),
               let result = try? await ScriptExec.run(
                   executable: exec, args: args, cwd: dir,
                   env: ["CLAUDE_PLUGIN_ID": pluginId,
                         "CLAUDE_HOST_VERSION": HostKernel.version],
                   timeoutMs: 2000, maxPayloadBytes: 65_536),
               result.exitCode == 0,
               let parsed = try? JSONDecoder().decode(MenubarResponse.self, from: result.stdout) {
                dynamicCache[cacheKey] = parsed.rows
                return parsed.rows
            }
        }
        return dynamicCache[cacheKey] ?? []
    }

    // MARK: - Actions

    @objc private func handleDashboard() { onShowDashboard() }
    @objc private func handleQuit() { onQuit() }

    @objc private func handleCommand(_ sender: NSMenuItem) {
        guard let pending = sender.representedObject as? PendingCommand else { return }
        platform.hostLogger.info("user.action",
            "menubar.command id=\(pending.commandId) plugin=\(pending.pluginId)")
        Task { @MainActor in
            await platform.runCommand(pluginId: pending.pluginId,
                                       commandId: pending.commandId,
                                       args: pending.args)
        }
    }

    @objc private func handleLink(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? String,
              let parsed = URL(string: url) else { return }
        NSWorkspace.shared.open(parsed)
    }

    // MARK: - Helpers

    private func disabled(title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }
}

/// Carries the click context from a menu item to its action handler.
/// Class so it can sit in NSMenuItem.representedObject (Obj-C boxed).
@MainActor
private final class PendingCommand: NSObject {
    let pluginId: String
    let commandId: String
    let args: [String: AnyCodable]?
    init(pluginId: String, commandId: String, args: [String: AnyCodable]?) {
        self.pluginId = pluginId
        self.commandId = commandId
        self.args = args
    }
}
