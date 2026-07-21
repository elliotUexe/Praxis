import SwiftUI

/// Brand colors from the "P + coche" icon (see Resources/Assets.xcassets/AppIcon) —
/// applied as the app's accent so buttons/toggles/selection read as Praxis, not the
/// generic system blue left over from AuTex.
extension Color {
    static let praxisAccent = Color(red: 0x2D / 255, green: 0xD4 / 255, blue: 0xBF / 255)   // #2DD4BF, teal
    static let praxisNavy = Color(red: 0x18 / 255, green: 0x28 / 255, blue: 0x36 / 255)     // #182836
}

extension TaskType {
    /// Centralizes the per-type colors that used to be scattered as ad hoc system Colors
    /// in `TaskRowView.typeIcon` (`.red`/`.blue`/`.indigo`/`.orange.opacity(0.7)`/`.gray`)
    /// — same hues, named once so every view (rows, triage cards, the future dashboard)
    /// agrees on what "Rendu" looks like.
    var color: Color {
        switch self {
        case .rendu: return .red
        case .revisionFond: return .blue
        case .revisionDS: return .indigo
        case .blocage: return .orange
        case .anticipation: return .gray
        }
    }

    /// Short label for the 5-equal-segment type control in `TaskFormSheet` — the full
    /// `displayName` ("Révision de fond", "Point de blocage"…) doesn't fit 5-across in a
    /// 420pt sheet; icon + color already carry most of the meaning.
    var shortLabel: String {
        switch self {
        case .rendu: return "Rendu"
        case .revisionFond: return "Fond"
        case .revisionDS: return "DS"
        case .blocage: return "Blocage"
        case .anticipation: return "Plus tard"
        }
    }

    /// SF Symbols per the design handoff — replaces the emoji placeholders used in the
    /// HTML mockups (⌂/〜/☑/▤/❗/📘/📗/⛔/🕒/✨/🌱), which were explicitly temporary.
    var iconName: String {
        switch self {
        case .rendu: return "exclamationmark.circle.fill"
        case .revisionFond: return "book.fill"
        case .revisionDS: return "book.closed.fill"
        case .blocage: return "exclamationmark.octagon.fill"
        case .anticipation: return "clock.fill"
        }
    }
}
