import SwiftUI
import HostKernel

/// Monospaced plain-text view with ring-buffer rendering. Auto-scrolls to
/// the bottom on new content (mimicking tail -f). 10k-line cap is enforced
/// upstream by the surface router (host trims before passing in).
struct LogPaneView: View {
    let content: LogContent

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(content.text.isEmpty ? "(empty)" : content.text)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Palette.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(12)
                    .id("bottom")
            }
            .background(Palette.surface)
            .onChange(of: content.text) { _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }
}
