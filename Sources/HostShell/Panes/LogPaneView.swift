import SwiftUI
import HostKernel

/// Monospaced log viewer with auto-scroll to bottom on content change.
struct LogPaneView: View {
    let content: LogContent
    @Environment(\.design) var design

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(content.text.isEmpty ? "(empty)" : content.text)
                    .font(design.font(DesignTokens.FontSize.label, monospaced: true))
                    .foregroundStyle(DesignTokens.TextColor.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(design.space(DesignTokens.Space.m))
                    .id("bottom")
            }
            .background(DesignTokens.Surface.raised)
            .onChange(of: content.text) { _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }
}
