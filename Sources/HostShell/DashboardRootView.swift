import SwiftUI
import HostKernel

/// The dashboard's outermost SwiftUI view. Injects the host settings store
/// + resolved design tokens into the environment, applies the user's
/// preferred color scheme override, and delegates to `DashboardSurface`.
struct DashboardRootView: View {
    @StateObject private var store = HostSettingsStore()

    var body: some View {
        DashboardSurface()
            .environmentObject(store)
            .environment(\.design, store.design)
            .preferredColorScheme(store.preferredColorScheme)
    }
}
