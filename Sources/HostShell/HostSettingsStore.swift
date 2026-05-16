import AppKit
import SwiftUI
import HostKernel

/// Observable wrapper around `HostSettings` for SwiftUI. The single
/// instance is owned by the AppDelegate and injected into the dashboard
/// root as an `@EnvironmentObject`. Plugins do NOT see this type — they
/// receive a read-only `HostSettings` snapshot via HostContext (Phase 4+).
///
/// Writes are debounced (200ms) so dragging a slider doesn't hammer disk.
@MainActor
public final class HostSettingsStore: ObservableObject {
    @Published public var settings: HostSettings

    private var debounceTask: Task<Void, Never>?

    public init() {
        self.settings = HostSettingsStore.loadOnDisk()
        applyAppearanceToNSApp()
    }

    private static func loadOnDisk() -> HostSettings {
        HostSettingsPersistence.load()
    }

    public func update(_ mutate: (inout HostSettings) -> Void) {
        let before = settings
        mutate(&settings)
        applyAppearanceToNSApp()
        scheduleSave()
        // Notify observers (host logger, plugins via bus later) that
        // something changed. Diff at JSON-encoded level to stay
        // forward-compat with new fields.
        if let beforeData = try? JSONEncoder().encode(before),
           let afterData = try? JSONEncoder().encode(settings),
           beforeData != afterData {
            NotificationCenter.default.post(name: .hostSettingsChanged, object: settings)
        }
    }

    /// Convenience: flip a plugin's enabled state. Defaults are true, so
    /// the first toggle creates a new dict entry. Posts a structured
    /// notification so AppDelegate can log the action.
    public func setPluginEnabled(_ id: String, _ enabled: Bool) {
        update { settings in
            var ps = settings.plugins[id] ?? .init(enabled: true)
            ps.enabled = enabled
            settings.plugins[id] = ps
        }
        NotificationCenter.default.post(
            name: .hostPluginToggled,
            object: (id: id, enabled: enabled))
    }

    /// Bridge the SwiftUI-level setting to AppKit. SwiftUI's
    /// `.preferredColorScheme(nil)` only clears the override for SwiftUI
    /// content — NSPanel/NSMenu chrome stays at whatever was last forced.
    /// Setting `NSApp.appearance` propagates the choice to the whole app
    /// including the menu-bar dropdown.
    private func applyAppearanceToNSApp() {
        switch settings.appearance.colorScheme {
        case .system: NSApp.appearance = nil
        case .light:  NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:   NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    private func scheduleSave() {
        debounceTask?.cancel()
        let snapshot = settings
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            try? HostSettingsPersistence.save(snapshot)
            _ = self
        }
    }

    /// Resolved tokens for the current settings. Recomputed when settings change.
    public var design: ResolvedDesign {
        ResolvedDesign(settings: settings)
    }

    /// SwiftUI ColorScheme override, or nil to follow the system.
    public var preferredColorScheme: SwiftUI.ColorScheme? {
        switch settings.appearance.colorScheme {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}

public extension Notification.Name {
    static let hostSettingsChanged = Notification.Name("ci.host.settings.changed")
    static let hostPluginToggled = Notification.Name("ci.host.plugin.toggled")
}
