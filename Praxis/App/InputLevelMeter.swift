import SwiftUI

/// Live capture level, so "the transcript is bad" can become a number.
///
/// The three possible causes of a poor transcript — a signal too weak, a room too loud, a
/// model that lost the thread — call for opposite fixes, and turning the gain up when the
/// real problem is noise only amplifies the room. This says which one you are looking at: a
/// lecturer who never lifts the bar off the floor is a capture problem, one who registers
/// clearly is not.
///
/// Observes `LiveTranscriptDisplay` and nothing else, for the same reason the transcript
/// pane does: its value changes several times a second, and everything that watches it
/// re-renders at that rate.
struct InputLevelMeter: View {
    @ObservedObject var display: LiveTranscriptDisplay

    /// Loudest moment of the last couple of seconds, kept so speech pauses do not make the
    /// meter look dead. An instantaneous bar alone flickers too fast to read in a lecture.
    @State private var heldPeak: Float = 0
    @State private var heldAt = Date()

    /// Quiet speech in a lecture hall lands well down the scale, so the meter starts at
    /// -60 dBFS rather than at the -20 or so a music meter would use.
    private static let floorDecibels: Float = -60
    private static let peakHold: TimeInterval = 2

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "mic")
                .font(.caption2)
                .foregroundStyle(.secondary)

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.15))
                    Capsule()
                        .fill(color(for: display.inputPeak))
                        .frame(width: geometry.size.width * CGFloat(normalised(display.inputPeak)))
                    // Peak-hold marker: the loudest thing heard recently, which is what you
                    // actually want to judge a lecturer's level by.
                    Capsule()
                        .fill(Color.primary.opacity(0.35))
                        .frame(width: 2)
                        .offset(x: geometry.size.width * CGFloat(normalised(heldPeak)) - 1)
                }
            }
            .frame(height: 6)

            Text(label)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .trailing)
        }
        .onChange(of: display.inputPeak) {
            let now = Date()
            if display.inputPeak >= heldPeak || now.timeIntervalSince(heldAt) > Self.peakHold {
                heldPeak = display.inputPeak
                heldAt = now
            }
        }
    }

    private var label: String {
        let decibels = Self.decibels(display.inputPeak)
        guard decibels > Self.floorDecibels else { return "silence" }
        return String(format: "%.0f dB", decibels)
    }

    /// Below -40 dBFS a voice is close enough to the noise floor that Whisper starts
    /// discarding it as silence; above -3 it is about to clip. Between the two is where a
    /// lecture wants to sit.
    private func color(for peak: Float) -> Color {
        let decibels = Self.decibels(peak)
        if decibels > -3 { return .red }
        if decibels < -40 { return .orange }
        return .praxisAccent
    }

    private func normalised(_ peak: Float) -> Float {
        let decibels = Self.decibels(peak)
        guard decibels > Self.floorDecibels else { return 0 }
        return min(1, (decibels - Self.floorDecibels) / -Self.floorDecibels)
    }

    private static func decibels(_ peak: Float) -> Float {
        guard peak > 0 else { return floorDecibels }
        return 20 * log10(peak)
    }
}
