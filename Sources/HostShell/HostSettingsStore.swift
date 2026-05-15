import Foundation
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
    }

    private static func loadOnDisk() -> HostSettings {
        HostSettingsPersistence.load()
    }

    public func update(_ mutate: (inout HostSettings) -> Void) {
        mutate(&settings)
        scheduleSave()
    }

    private func scheduleSave() {
        debounceTask?.cancel()
        let snapshot = settings
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            try? HostSettingsPersistence.save(snapshot)
            await self?.notifyListeners()
        }
    }

    private func notifyListeners() async {
        // Phase 6 will emit `host.appearance.change` on the real event bus.
        // For now this is a placeholder hook the rest of the host can wire to.
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
