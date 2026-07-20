import SwiftUI

/// Brand colors from the "P + coche" icon (see Resources/Assets.xcassets/AppIcon) —
/// applied as the app's accent so buttons/toggles/selection read as Praxis, not the
/// generic system blue left over from AuTex.
extension Color {
    static let praxisAccent = Color(red: 0x2D / 255, green: 0xD4 / 255, blue: 0xBF / 255)   // #2DD4BF, teal
    static let praxisNavy = Color(red: 0x18 / 255, green: 0x28 / 255, blue: 0x36 / 255)     // #182836
}
