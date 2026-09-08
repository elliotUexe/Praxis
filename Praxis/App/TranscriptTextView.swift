import SwiftUI
import AppKit

extension NSAttributedString.Key {
    /// Start time of the segment a character belongs to, carried on the text itself so a
    /// selection can be resolved back to segments without a parallel index to keep in sync
    /// with every rebuild.
    static let praxisSegmentStart = NSAttributedString.Key("praxisSegmentStart")
}

/// What is selected in the transcript, already resolved into the flags a click would apply.
///
/// The resolution happens when the selection changes rather than when the pill is clicked,
/// and that is the whole point. The text underneath keeps being rewritten by the refinement
/// pass several times a minute, so a character offset captured now and read a moment later
/// can point at different words. A (segment, wording) pair does not drift, and
/// `TranscriptMarkup.relocated` already knows what to do if that wording later disappears.
@MainActor
final class TranscriptSelectionModel: ObservableObject {
    enum Action: Equatable {
        case none
        case add
        case remove
    }

    @Published private(set) var action: Action = .none
    /// Where to float the pill, in the SwiftUI view's own top-left coordinate space.
    @Published private(set) var anchor: CGRect = .zero

    /// Flags to add, or the existing flags to remove, depending on `action`.
    private(set) var targets: [TranscriptFlag] = []

    /// Set by the text view so the pill can drop the selection once it has acted.
    var clearTextSelection: (() -> Void)?

    func present(action: Action, anchor: CGRect, targets: [TranscriptFlag]) {
        guard action != .none, !targets.isEmpty else {
            dismiss()
            return
        }
        self.targets = targets
        if self.action != action { self.action = action }
        if self.anchor != anchor { self.anchor = anchor }
    }

    func dismiss() {
        targets = []
        if action != .none { action = .none }
    }

    func dismissAndDeselect() {
        clearTextSelection?()
        dismiss()
    }
}

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
    @ObservedObject var selection: TranscriptSelectionModel

    /// How close to the bottom counts as "following the live edge". A transcript that was
    /// scrolled to the bottom should stay there as new speech arrives; one the user scrolled
    /// up into must not be yanked away from them.
    private static let bottomSlack: CGFloat = 24

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: selection)
    }

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
        textView.delegate = context.coordinator

        let built = attributedTranscript()
        textView.textStorage?.setAttributedString(built.text)
        context.coordinator.flagRanges = built.flagRanges
        context.coordinator.attach(scrollView: scrollView, textView: textView)

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView,
              let storage = textView.textStorage else { return }

        context.coordinator.attach(scrollView: scrollView, textView: textView)

        let built = attributedTranscript()
        context.coordinator.flagRanges = built.flagRanges
        guard !storage.isEqual(to: built.text) else { return }

        // Geometry and selection are read before the swap: replacing the storage resets
        // both, and restoring them is what keeps the view from jumping under the reader
        // several times a second while someone is speaking.
        let clipView = scrollView.contentView
        // Following the live edge is suspended while something is selected: pushing the
        // view down under a passage the user is about to act on is exactly the kind of
        // moving ground that makes a feature like this untrustworthy.
        let wasAtBottom = selection.action == .none
            && clipView.bounds.maxY >= textView.frame.height - Self.bottomSlack
        let offset = clipView.bounds.origin
        context.coordinator.isRestoringSelection = true
        storage.setAttributedString(built.text)

        // Restored from the resolved targets, not from raw offsets: a refinement pass may
        // have made every offset above the selection shift. Re-finding the wording is the
        // only way the highlight can still be on the words the pill will act on — and the
        // caret case matters as much as the drag case, since a caret dropped inside a
        // marked passage is what offers to remove it.
        if selection.action != .none,
           let restored = context.coordinator.rangeMatching(selection.targets, in: storage) {
            textView.setSelectedRange(restored)
        }
        context.coordinator.isRestoringSelection = false

        if wasAtBottom {
            textView.scrollToEndOfDocument(nil)
        } else {
            clipView.scroll(to: offset)
            scrollView.reflectScrolledClipView(clipView)
        }

        // Deferred: publishing from inside `updateNSView` mutates observed state in
        // the middle of SwiftUI's own update pass.
        context.coordinator.scheduleAnchorRefresh()
    }

    // MARK: - Building the text

    private struct BuiltTranscript {
        let text: NSAttributedString
        /// One entry per flag, unmerged, so a click can be traced back to the flag it hit.
        let flagRanges: [(range: NSRange, flag: TranscriptFlag)]
    }

    private func attributedTranscript() -> BuiltTranscript {
        let body = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = 4

        let out = NSMutableAttributedString()
        var flagRanges: [(range: NSRange, flag: TranscriptFlag)] = []

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
            let segmentOrigin = out.length
            out.append(NSAttributedString(string: segment.text + "\n", attributes: [
                .font: body,
                // Dimmed until the refinement pass has been through, replacing the former
                // per-segment "waiting" icon: an inline symbol per line is not something a
                // text container renders without fighting it.
                .foregroundColor: segment.isRefined ? NSColor.labelColor : NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph,
                .praxisSegmentStart: NSNumber(value: segment.start)
            ]))

            for flag in flagsBySegment[segment.start] ?? [] {
                guard let local = Self.localRange(of: flag, in: segment.text) else { continue }
                let range = NSRange(location: segmentOrigin + local.location, length: local.length)
                out.addAttribute(
                    .backgroundColor,
                    value: NSColor.systemYellow.withAlphaComponent(0.35),
                    range: range
                )
                flagRanges.append((range, flag))
            }
        }

        if !unconfirmedText.isEmpty {
            out.append(NSAttributedString(string: unconfirmedText, attributes: [
                .font: body,
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph
            ]))
        }

        return BuiltTranscript(text: out, flagRanges: flagRanges)
    }

    /// Where a flag sits inside its own segment. A nil substring covers the segment whole,
    /// which is also where a flag lands once refinement has rewritten its wording away.
    private static func localRange(of flag: TranscriptFlag, in text: String) -> NSRange? {
        guard let substring = flag.substring, !substring.isEmpty else {
            return text.isEmpty ? nil : NSRange(location: 0, length: (text as NSString).length)
        }
        let found = (text as NSString).range(of: substring)
        return found.location == NSNotFound ? nil : found
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        private let selection: TranscriptSelectionModel
        private weak var scrollView: NSScrollView?
        private weak var textView: NSTextView?
        private var scrollObserver: NSObjectProtocol?

        var flagRanges: [(range: NSRange, flag: TranscriptFlag)] = []
        /// Suppresses the delegate callback fired by our own selection restore, which would
        /// otherwise re-resolve targets from a selection we just recomputed from them.
        var isRestoringSelection = false

        init(selection: TranscriptSelectionModel) {
            self.selection = selection
            super.init()
        }

        deinit {
            if let scrollObserver {
                NotificationCenter.default.removeObserver(scrollObserver)
            }
        }

        func attach(scrollView: NSScrollView, textView: NSTextView) {
            self.textView = textView
            guard self.scrollView !== scrollView else { return }
            self.scrollView = scrollView

            selection.clearTextSelection = { [weak self, weak textView] in
                guard let textView else { return }
                // Collapsing the selection drops the caret inside the passage that was just
                // marked, which the delegate would resolve straight back into a "Retirer"
                // pill under the cursor. The gesture is finished: stay quiet.
                self?.isRestoringSelection = true
                textView.setSelectedRange(NSRange(location: textView.selectedRange().location, length: 0))
                self?.isRestoringSelection = false
            }

            // The pill has to follow the text it points at, or it ends up hovering over an
            // unrelated line the moment anything moves.
            scrollView.contentView.postsBoundsChangedNotifications = true
            if let scrollObserver {
                NotificationCenter.default.removeObserver(scrollObserver)
            }
            scrollObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self] _ in
                self?.scheduleAnchorRefresh()
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !isRestoringSelection else { return }
            resolveSelection()
        }

        // MARK: Resolving

        private func resolveSelection() {
            guard let textView, let storage = textView.textStorage else {
                selection.dismiss()
                return
            }
            let range = textView.selectedRange()

            // An empty caret only offers something when it landed inside a marked passage;
            // otherwise every click in the transcript would pop a button up.
            guard range.length > 0 else {
                let hit = flagRanges.filter { NSLocationInRange(range.location, $0.range) }
                guard !hit.isEmpty else {
                    selection.dismiss()
                    return
                }
                present(.remove, targets: hit.map(\.flag), at: range)
                return
            }

            let overlapping = flagRanges.filter { NSIntersectionRange($0.range, range).length > 0 }
            if !overlapping.isEmpty {
                present(.remove, targets: overlapping.map(\.flag), at: range)
                return
            }

            let candidates = resolveFlags(in: storage, range: range)
            guard !candidates.isEmpty else {
                selection.dismiss()
                return
            }
            present(.add, targets: candidates, at: range)
        }

        /// Splits a selection into one flag per segment it touches. A segment covered end to
        /// end gets a nil substring rather than its own text: it is both shorter to write and
        /// immune to the refinement pass rewriting the words.
        private func resolveFlags(in storage: NSTextStorage, range: NSRange) -> [TranscriptFlag] {
            let whole = NSRange(location: 0, length: storage.length)
            let text = storage.string as NSString
            var result: [TranscriptFlag] = []

            storage.enumerateAttribute(.praxisSegmentStart, in: range, options: []) { value, subrange, _ in
                guard let start = (value as? NSNumber)?.floatValue else { return }

                var segmentRange = NSRange(location: NSNotFound, length: 0)
                _ = storage.attribute(
                    .praxisSegmentStart,
                    at: subrange.location,
                    longestEffectiveRange: &segmentRange,
                    in: whole
                )
                guard segmentRange.location != NSNotFound else { return }

                let covered = text.substring(with: subrange).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !covered.isEmpty else { return }
                let full = text.substring(with: segmentRange).trimmingCharacters(in: .whitespacesAndNewlines)

                result.append(TranscriptFlag(
                    segmentStart: start,
                    substring: covered == full ? nil : covered
                ))
            }
            return result
        }

        /// The character range the given flags occupy now, used to put the highlight back
        /// where it belongs after the storage was replaced.
        func rangeMatching(_ targets: [TranscriptFlag], in storage: NSTextStorage) -> NSRange? {
            let matches = flagRangesIgnoringState(for: targets, in: storage)
            guard let first = matches.first else { return nil }
            return matches.dropFirst().reduce(first) { NSUnionRange($0, $1) }
        }

        private func flagRangesIgnoringState(for targets: [TranscriptFlag], in storage: NSTextStorage) -> [NSRange] {
            let whole = NSRange(location: 0, length: storage.length)
            let text = storage.string as NSString
            var found: [NSRange] = []

            for target in targets {
                var cursor = 0
                while cursor < storage.length {
                    var effective = NSRange(location: NSNotFound, length: 0)
                    let value = storage.attribute(
                        .praxisSegmentStart,
                        at: cursor,
                        longestEffectiveRange: &effective,
                        in: whole
                    )
                    guard effective.location != NSNotFound, effective.length > 0 else { break }

                    if (value as? NSNumber)?.floatValue == target.segmentStart {
                        if let substring = target.substring, !substring.isEmpty {
                            let hit = text.range(of: substring, options: [], range: effective)
                            if hit.location != NSNotFound { found.append(hit) }
                        } else {
                            found.append(effective)
                        }
                        break
                    }
                    cursor = effective.upperBound
                }
            }
            return found
        }

        // MARK: Positioning

        private func present(_ action: TranscriptSelectionModel.Action, targets: [TranscriptFlag], at range: NSRange) {
            guard let anchor = anchorRect(for: range) else {
                selection.dismiss()
                return
            }
            selection.present(action: action, anchor: anchor, targets: targets)
        }

        func scheduleAnchorRefresh() {
            DispatchQueue.main.async { [weak self] in
                self?.refreshAnchor()
            }
        }

        func refreshAnchor() {
            guard selection.action != .none, let textView else { return }
            guard let anchor = anchorRect(for: textView.selectedRange()) else {
                selection.dismiss()
                return
            }
            selection.present(action: selection.action, anchor: anchor, targets: selection.targets)
        }

        /// The selection's rect in the SwiftUI view's coordinate space. Goes through screen
        /// coordinates because `firstRect(forCharacterRange:)` is the one API that answers
        /// the same way under TextKit 1 and TextKit 2.
        private func anchorRect(for range: NSRange) -> CGRect? {
            guard let textView, let scrollView, let window = textView.window else { return nil }
            let onScreen = textView.firstRect(forCharacterRange: range, actualRange: nil)
            guard onScreen.width.isFinite, onScreen.height.isFinite else { return nil }

            let inWindow = window.convertFromScreen(onScreen)
            let inScroll = scrollView.convert(inWindow, from: nil)

            // The clip view hides anything scrolled out; a pill pointing off-view is worse
            // than no pill.
            let visible = scrollView.contentView.frame
            guard inScroll.maxY > visible.minY, inScroll.minY < visible.maxY else { return nil }

            // NSScrollView is not flipped, SwiftUI overlays are: y has to be turned over.
            return CGRect(
                x: inScroll.minX,
                y: scrollView.bounds.height - inScroll.maxY,
                width: inScroll.width,
                height: inScroll.height
            )
        }
    }
}
