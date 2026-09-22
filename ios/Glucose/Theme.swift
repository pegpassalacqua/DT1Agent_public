import SwiftUI
import UIKit

/// App palette. Light mode uses the system grouped colors; dark mode uses a
/// softened, elevated dark (warm grays) instead of iOS's near-black.
extension Color {
    // Dark-mode tones: bg 0.13/0.14/0.17 · card 0.19/0.20/0.24. A lighter
    // variant and the icon palette were tried and reverted.
    static let appBackground = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.13, green: 0.14, blue: 0.17, alpha: 1)
            : UIColor.systemGroupedBackground
    })

    static let cardBackground = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.19, green: 0.20, blue: 0.24, alpha: 1)
            : UIColor.secondarySystemGroupedBackground
    })
}

/// Tint opacities need a boost in dark mode to stay visible on gray.
struct TintLevel {
    let scheme: ColorScheme
    var subtle: Double { scheme == .dark ? 0.22 : 0.12 }
    var medium: Double { scheme == .dark ? 0.30 : 0.18 }
}
