import SwiftUI
import HostKernel

/// The dashboard's outermost SwiftUI view. Environment injection happens at
/// the NSHostingController level (DashboardController) so this view is
/// stateless — it just propagates the window-title callback into the surface.
struct DashboardRootView: View {
    let onTitleChange: (String) -> Void

    var body: some View {
        DashboardSurface(onTitleChange: onTitleChange)
    }
}
