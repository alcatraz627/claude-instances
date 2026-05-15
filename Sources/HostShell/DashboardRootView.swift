import SwiftUI
import HostKernel

/// The dashboard's outermost SwiftUI view. Environment injection happens at
/// the NSHostingController level (DashboardController) so this view is
/// stateless — it just lays out the surface.
struct DashboardRootView: View {
    var body: some View {
        DashboardSurface()
    }
}
