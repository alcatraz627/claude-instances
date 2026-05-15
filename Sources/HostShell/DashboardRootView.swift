import SwiftUI
import HostKernel

/// The dashboard's outermost SwiftUI view. Phase 3 wires it to
/// `DashboardSurface`, which renders panes via the kind-dispatched
/// `PaneRenderer`. Phase 4+ will swap demo data for registry-driven
/// `dashboard.pane` contributions.
struct DashboardRootView: View {
    var body: some View {
        DashboardSurface()
    }
}
