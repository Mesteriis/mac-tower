import Foundation
import MacTowerCore

enum WindowGeometry {
    static func accessibilityRect(_ rect: WindowRect, primaryFrame: WindowRect) -> WindowRect {
        WindowRect(
            x: rect.x,
            y: primaryFrame.y + primaryFrame.height - rect.y - rect.height,
            width: rect.width,
            height: rect.height
        )
    }

    static func matches(_ lhs: WindowRect, _ rhs: WindowRect) -> Bool {
        abs(lhs.x - rhs.x) <= 2 && abs(lhs.y - rhs.y) <= 2
            && abs(lhs.width - rhs.width) <= 2 && abs(lhs.height - rhs.height) <= 2
    }
}
