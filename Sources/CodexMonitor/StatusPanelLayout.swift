import CoreGraphics

enum StatusPanelLayout {
    static let width: CGFloat = 390
    static let initialHeight: CGFloat = 840
    static let minimumHeight: CGFloat = 240
    static let screenEdgeMargin: CGFloat = 24

    static func clampedHeight(_ preferredHeight: CGFloat, visibleScreenHeight: CGFloat) -> CGFloat {
        let maximumHeight = max(minimumHeight, visibleScreenHeight - screenEdgeMargin)
        return min(max(preferredHeight, minimumHeight), maximumHeight)
    }
}
