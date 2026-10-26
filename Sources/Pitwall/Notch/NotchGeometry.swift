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

    /// Size of the black shape when collapsed and idle: exactly the notch, so it
    /// disappears into it. Without a notch, the pill always shows its wings.
    var collapsedSize: CGSize { hasNotch ? notchSize : peekSize }

    /// The notch plus a wing on each side, shown on first hover.
    var peekSize: CGSize {
        CGSize(width: notchSize.width + Self.wingWidth * 2, height: notchSize.height)
    }

    /// The panel is sized once for the largest state; SwiftUI draws inside it.
    var panelFrame: NSRect {
        let width = max(Self.expandedWidth, peekSize.width) + 40
        let height = Self.maxExpandedHeight + 20
        return NSRect(x: screenFrame.midX - width / 2, y: screenFrame.maxY - height, width: width, height: height)
    }

    /// Screen-space rects of the collapsed and peeking shapes, used for hover detection.
    var collapsedRect: NSRect { topRect(collapsedSize) }
    var peekRect: NSRect { topRect(peekSize) }

    private func topRect(_ size: CGSize) -> NSRect {
        NSRect(x: screenFrame.midX - size.width / 2, y: screenFrame.maxY - size.height - 4,
               width: size.width, height: size.height + 4)
    }

    func expandedRect(height: CGFloat) -> NSRect {
        let w = Self.expandedWidth
        return NSRect(x: screenFrame.midX - w / 2, y: screenFrame.maxY - height, width: w, height: height)
    }

    static func current() -> NotchGeometry? {
        let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
        guard let screen else { return nil }
        return make(frame: screen.frame, visibleFrame: screen.visibleFrame, safeAreaTop: screen.safeAreaInsets.top,
                    leftArea: screen.auxiliaryTopLeftArea, rightArea: screen.auxiliaryTopRightArea)
    }

    /// The notch sits between the two auxiliary areas. Without one, a pill
    /// as tall as the menu bar.
    static func make(frame: NSRect, visibleFrame: NSRect, safeAreaTop top: CGFloat, leftArea: NSRect?, rightArea: NSRect?) -> NotchGeometry {
        if top > 0, let left = leftArea, let right = rightArea {
            let width = frame.width - left.width - right.width
            return NotchGeometry(screenFrame: frame, notchSize: CGSize(width: width, height: top), hasNotch: true)
        }
        let menuBar = max(frame.maxY - visibleFrame.maxY, 24)
        return NotchGeometry(screenFrame: frame, notchSize: CGSize(width: 120, height: menuBar), hasNotch: false)
    }
}
