import SwiftUI
import AppKit

/// The live transcript, laid out by TextKit instead of by a `VStack` of `Text` views.
///
/// Two reasons for the bridge. SwiftUI can *display* a selection but never hands back the
/// range that was selected, so acting on a passage the user picked is not expressible
/// there at all. And one view per segment is the cost this view was already optimised
/// against (see `visibleSegmentLimit`); one view per *word*, which sub-segment selection
/// would otherwise need, would multiply it again. TextKit lays out a single text container
/// whatever the length.
struct TranscriptTextView: NSViewRepresentable {
    let segments: [DisplaySegment]
    let flags: [TranscriptFlag]
    let unconfirmedText: String
    let hiddenSegmentCount: Int

    /// How close to the bottom counts as "following the live edge". A transcript that was
    /// scrolled to the bottom should stay there as new speech arrives; one the user scrolled
    /// up into must not be yanked away from them.
    private static let bottomSlack: CGFloat = 24

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true

        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textStorage?.setAttributedString(attributedTranscript())
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView,
              let storage = textView.textStorage else { return }

        let updated = attributedTranscript()
        guard !storage.isEqual(to: updated) else { return }

        // Geometry and selection are read before the swap: replacing the storage resets
        // both, and restoring them is what keeps the view from jumping under the reader
        // several times a second while someone is speaking.
        let clipView = scrollView.contentView
        let wasAtBottom = clipView.bounds.maxY >= textView.frame.height - Self.bottomSlack
        let offset = clipView.bounds.origin
        let selection = textView.selectedRanges

        storage.setAttributedString(updated)

        let restored = selection.compactMap { value -> NSValue? in
            let range = value.rangeValue
            guard range.location <= storage.length else { return nil }
            return NSValue(range: NSRange(
                location: range.location,
                length: min(range.length, storage.length - range.location)
            ))
        }
        if !restored.isEmpty {
            textView.selectedRanges = restored
        }

        if wasAtBottom {
            textView.scrollToEndOfDocument(nil)
        } else {
            clipView.scroll(to: offset)
            scrollView.reflectScrolledClipView(clipView)
        }
    }

    private func attributedTranscript() -> NSAttributedString {
        let body = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = 4

        let out = NSMutableAttributedString()

        if hiddenSegmentCount > 0 {
            let plural = hiddenSegmentCount > 1 ? "s" : ""
            out.append(NSAttributedString(
                string: "\(hiddenSegmentCount) segment\(plural) plus ancien\(plural) — texte complet dans le fichier .txt\n\n",
                attributes: [
                    .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                    .foregroundColor: NSColor.tertiaryLabelColor,
                    .paragraphStyle: paragraph
                ]
            ))
        }

        let flagsBySegment = Dictionary(grouping: flags, by: \.segmentStart)
        for segment in segments {
            let segmentStart = out.length
            out.append(NSAttributedString(string: segment.text, attributes: [
                .font: body,
                // Dimmed until the refinement pass has been through, replacing the former
                // per-segment "waiting" icon: an inline symbol per line is not something a
                // text container renders without fighting it.
                .foregroundColor: segment.isRefined ? NSColor.labelColor : NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph
            ]))

            for range in TranscriptMarkup.flaggedRanges(in: segment.text, flags: flagsBySegment[segment.start] ?? []) {
                let local = NSRange(range, in: segment.text)
                out.addAttribute(
                    .backgroundColor,
                    value: NSColor.systemYellow.withAlphaComponent(0.35),
                    range: NSRange(location: segmentStart + local.location, length: local.length)
                )
            }

            out.append(NSAttributedString(string: "\n", attributes: [.font: body, .paragraphStyle: paragraph]))
        }

        if !unconfirmedText.isEmpty {
            out.append(NSAttributedString(string: unconfirmedText, attributes: [
                .font: body,
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph
            ]))
        }

        return out
    }
}
