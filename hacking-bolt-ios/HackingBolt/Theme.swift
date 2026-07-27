import SwiftUI
import UIKit

extension Color {
    /// Adaptive colour from two hex values (light, dark) — mirrors the web app's CSS variables.
    static func dyn(_ light: UInt, _ dark: UInt) -> Color {
        Color(UIColor { tc in
            let hex = tc.userInterfaceStyle == .dark ? dark : light
            return UIColor(red:   CGFloat((hex >> 16) & 0xff) / 255,
                           green: CGFloat((hex >> 8)  & 0xff) / 255,
                           blue:  CGFloat( hex        & 0xff) / 255, alpha: 1)
        })
    }
}

/// Design tokens matched to stage2/site (the web app the user likes).
enum Theme {
    static let bg        = Color.dyn(0xEEF3F3, 0x0A1216)
    static let panel     = Color.dyn(0xFFFFFF, 0x111F27)
    static let ink       = Color.dyn(0x111F26, 0xE7EFF2)
    static let muted     = Color.dyn(0x5A6D75, 0x9DB0B8)
    static let line      = Color.dyn(0xE3E9EA, 0x1E323B)
    static let accent    = Color.dyn(0x0F766E, 0x5EEAD4)   // teal
    static let available = Color.dyn(0xE19614, 0xF0B24A)   // amber "Available"
}
