import SwiftUI
import HostKernel

/// The dashboard's outermost SwiftUI view. Phase 1 stub — sidebar + content area
/// frames will arrive in Phase 3 once the surface router exists. For now it shows
/// a banner so we can verify the panel opens.
struct DashboardRootView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "puzzlepiece.extension.fill")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.tint)
            Text("claude-instances V2")
                .font(.system(size: 22, weight: .semibold))
            Text("Plugin platform — preview build · HostKernel \(HostKernel.version)")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text("Sidebar + plugin panes arrive in Phase 3.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}
