import SwiftUI

/// Neutral launcher-like surfaces, clear text hierarchy and a restrained coral accent.
struct WheelPalette {
    let isDark: Bool

    var ink: Color {
        isDark ? Color(red: 0.96, green: 0.96, blue: 0.97) : Color(red: 0.13, green: 0.13, blue: 0.15)
    }

    var secondaryInk: Color {
        isDark ? Color(red: 0.65, green: 0.65, blue: 0.68) : Color(red: 0.4, green: 0.4, blue: 0.44)
    }

    var accent: Color {
        isDark ? Color(red: 0.97, green: 0.5, blue: 0.4) : Color(red: 0.74, green: 0.25, blue: 0.19)
    }

    /// A mostly matte surface keeps desktop colors from tinting the interface.
    var surfaceTint: Color {
        isDark ? Color(red: 0.085, green: 0.085, blue: 0.095).opacity(0.82)
               : Color(red: 0.98, green: 0.98, blue: 0.985).opacity(0.78)
    }

    var border: Color { ink.opacity(isDark ? 0.11 : 0.09) }

    var selectionFill: Color { ink.opacity(isDark ? 0.1 : 0.065) }

    var separator: Color { ink.opacity(0.09) }

    var fanSurface: Color {
        isDark ? Color(red: 0.14, green: 0.14, blue: 0.155).opacity(0.96) : .white.opacity(0.96)
    }

    var previewShadow: Double { isDark ? 0.16 : 0.10 }
}
