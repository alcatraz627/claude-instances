import SwiftUI
import HostKernel

/// Type-switch from runtime `PaneContent` → the right SwiftUI view. The
/// surface router calls this for every pane spec in a dashboard contribution.
struct PaneRenderer: View {
    let content: PaneContent
    let title: String?
    let subtitle: String?
    let fetchedAt: Date?
    var onRefresh: (() -> Void)? = nil
    var onRowAction: ((TableContent.RowAction) -> Void)? = nil
    var onOpenAsset: ((AssetsContent.Item) -> Void)? = nil
    var onOpenLog: ((String) -> Void)? = nil

    var body: some View {
        PaneFrame(title: title, subtitle: subtitle, fetchedAt: fetchedAt, onRefresh: onRefresh) {
            switch content {
            case .summary(let c):  SummaryPaneView(content: c)
            case .table(let c):    TablePaneView(content: c, onAction: onRowAction)
            case .schedule(let c): SchedulePaneView(content: c, onOpenLog: onOpenLog)
            case .assets(let c):   AssetsPaneView(content: c, onOpen: onOpenAsset)
            case .log(let c):      LogPaneView(content: c)
            case .error(let e):    ErrorPaneView(error: e)
            }
        }
    }
}
