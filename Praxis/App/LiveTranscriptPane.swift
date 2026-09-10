import SwiftUI

/// The live transcript area, extracted so that it — and nothing else — re-renders while
/// someone is speaking.
///
/// It is the only view that observes `LiveTranscriptDisplay`, whose three properties change
/// several times a second. Keeping it inside `RecordingSectionView` meant that whole view,
/// and everything SwiftUI walked to reach it, was rebuilt at the same rate.
struct LiveTranscriptPane: View {
    @ObservedObject var display: LiveTranscriptDisplay
    /// Passed as closures rather than by handing over the coordinator: observing the
    /// coordinator here would put this view back on the hook for every property it owns.
    let onFlag: (Float, String?) -> Void
    let onUnflag: (Float, String?) -> Void

    @StateObject private var selection = TranscriptSelectionModel()

    /// Only the tail of the transcript is rendered. Updates fire several times per second
    /// while someone is speaking, so the cost of laying out the text grew with session
    /// length: sampling a real 1h24 course showed the app pegged at 119% CPU with the main
    /// thread almost entirely inside layout. Capping the rendered window makes it constant.
    ///
    /// `display.segments` itself stays complete on purpose — it is the source of truth for
    /// the `.txt` written next to the recording, so trimming it would silently truncate
    /// every saved transcript.
    private static let visibleSegmentLimit = 100

    private var visibleSegments: ArraySlice<DisplaySegment> {
        display.segments.suffix(Self.visibleSegmentLimit)
    }

    private var hiddenSegmentCount: Int {
        max(0, display.segments.count - Self.visibleSegmentLimit)
    }

    var body: some View {
        TranscriptTextView(
            segments: Array(visibleSegments),
            flags: display.flags,
            unconfirmedText: display.unconfirmedText,
            hiddenSegmentCount: hiddenSegmentCount,
            selection: selection
        )
        .overlay(alignment: .topLeading) { flagPill }
        .frame(minHeight: 150)
        .frame(maxHeight: .infinity)
        .background(Color.gray.opacity(0.08))
        .cornerRadius(8)
    }

    /// Floats over the selection rather than living in the toolbar: the gesture is
    /// "select the bad passage, confirm", and a button on the other side of the window
    /// would break that into two unrelated movements.
    @ViewBuilder
    private var flagPill: some View {
        if selection.action != .none {
            GeometryReader { geometry in
                let size = CGSize(width: 108, height: 22)
                let anchor = selection.anchor
                let above = anchor.minY - size.height / 2 - 6
                Button(action: applyFlagAction) {
                    Label(
                        selection.action == .add ? "Signaler" : "Retirer",
                        systemImage: selection.action == .add ? "exclamationmark.triangle" : "xmark.circle"
                    )
                    .font(.caption)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .frame(width: size.width, height: size.height)
                .position(
                    // Kept inside the transcript on both axes: a selection on the first
                    // line puts the pill below instead of off the top edge, and one at the
                    // right margin slides back in rather than being clipped.
                    x: min(max(anchor.midX, size.width / 2), max(size.width / 2, geometry.size.width - size.width / 2)),
                    y: above > size.height / 2 ? above : anchor.maxY + size.height / 2 + 6
                )
            }
        }
    }

    private func applyFlagAction() {
        switch selection.action {
        case .add:
            for target in selection.targets {
                onFlag(target.segmentStart, target.substring)
            }
        case .remove:
            for target in selection.targets {
                onUnflag(target.segmentStart, target.substring)
            }
        case .none:
            break
        }
        selection.dismissAndDeselect()
    }
}
