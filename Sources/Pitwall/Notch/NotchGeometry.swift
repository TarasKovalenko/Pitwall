import AppKit

/// Where the notch is on a given screen. Macs without a notch get a
/// pill of similar size centered under the menu bar's top edge.
struct NotchGeometry: Equatable {
    let screenFrame: NSRect
    let notchSize: CGSize
    let hasNotch: Bool

    static let wingWidth: CGFloat = 74
    static let expandedWidth: CGFloat = 460
    static let maxExpandedHeight: CGFloat = 340

    /// Size of the black shape when collapsed (notch plus a wing on each side).
    var collapsedSize: CGSize {
        CGSize(width: notchSize.width + Self.wingWidth * 2, height: notchSize.height)
    }

    /// The panel is sized once for the largest state; SwiftUI draws inside it.
    var panelFrame: NSRect {
        let width = max(Self.expandedWidth, collapsedSize.width) + 40
        let height = Self.maxExpandedHeight + 20
        return NSRect(x: screenFrame.midX - width / 2, y: screenFrame.maxY - height, width: width, height: height)
    }

    /// Screen-space rect of the collapsed shape, used for hover detection.
    var collapsedRect: NSRect {
        let size = collapsedSize
        return NSRect(x: screenFrame.midX - size.width / 2, y: screenFrame.maxY - size.height - 4,
                      width: size.width, height: size.height + 4)
    }

    func expandedRect(height: CGFloat) -> NSRect {
        let w = Self.expandedWidth
        return NSRect(x: screenFrame.midX - w / 2, y: screenFrame.maxY - height, width: w, height: height)
    }

    static func current() -> NotchGeometry? {
        let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
        guard let screen else { return nil }
        let top = screen.safeAreaInsets.top
        if top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            let width = screen.frame.width - left.width - right.width
            return NotchGeometry(screenFrame: screen.frame, notchSize: CGSize(width: width, height: top), hasNotch: true)
        }
        let menuBar = max(screen.frame.maxY - screen.visibleFrame.maxY, 24)
        return NotchGeometry(screenFrame: screen.frame, notchSize: CGSize(width: 120, height: menuBar), hasNotch: false)
    }
}
