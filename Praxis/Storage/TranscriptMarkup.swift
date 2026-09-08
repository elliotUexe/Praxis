import Foundation

/// A passage marked as unreliable while the lecture was being transcribed.
///
/// A flag is deliberately *not* an edit. The text underneath keeps being improved by the
/// refinement pass, which is exactly what a flagged passage needs most: flagging is the
/// gesture you make when the words are wrong, so freezing them would throw away the only
/// thing able to fix them.
///
/// That means the flag has to survive its own text being rewritten. It anchors to a segment
/// by start time — stable, since `DisplaySegment.id` is that same start — and remembers the
/// exact wording it covered so it can find itself again afterwards.
struct TranscriptFlag: Equatable {
    let segmentStart: Float
    /// The exact text this flag covers, or nil when it covers the whole segment: either
    /// because that is what was marked, or because a rewrite made the original wording
    /// disappear and `TranscriptMarkup.relocated` fell the flag back onto the segment.
    var substring: String?
}

/// One transcript line, reduced to what the file writer needs from a segment.
struct TranscriptEntry: Equatable {
    let start: Float
    let text: String
}

/// Turns flags into the marks that reach the `.txt`, and the `.txt` is the document that
/// matters — nobody rereads a lecture inside Praxis. Whatever is not written here is lost
/// the moment the window closes.
enum TranscriptMarkup {
    /// Obsidian's highlight syntax, so a transcript that ever becomes a `.md` renders these
    /// passages without a plugin or a convention to remember.
    static let openMark = "=="
    static let closeMark = "=="

    /// Written once at the top of a transcript that has at least one flag. A highlight on
    /// its own says "look here" without saying why, and the reader of these files is a
    /// language model rather than a human who remembers what they marked in class.
    static let legend = "# Les passages encadrés par == == ont été signalés comme peu fiables pendant le cours : à vérifier avant de s'y fier."

    /// The character ranges a segment's flags cover, sorted and with overlaps merged.
    /// Shared by the file writer and the on-screen highlight so the two can never disagree
    /// about what is marked.
    ///
    /// A flag records wording rather than an offset, so when the same wording appears twice
    /// in one segment the mark lands on the first occurrence. Distinguishing the two would
    /// mean an anchor that survives the refinement pass rewriting the segment, which is the
    /// very thing offsets cannot do.
    static func flaggedRanges(in text: String, flags: [TranscriptFlag]) -> [Range<String.Index>] {
        guard !flags.isEmpty, !text.isEmpty else { return [] }
        // A whole-segment flag subsumes every partial one on the same segment.
        if flags.contains(where: { ($0.substring ?? "").isEmpty }) {
            return [text.startIndex..<text.endIndex]
        }

        var found: [Range<String.Index>] = []
        for substring in Set(flags.compactMap(\.substring)) {
            if let range = text.range(of: substring) {
                found.append(range)
            }
        }
        guard !found.isEmpty else { return [] }

        found.sort { $0.lowerBound < $1.lowerBound }
        var merged = [found[0]]
        for range in found.dropFirst() {
            let last = merged[merged.count - 1]
            if range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<Swift.max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    /// Wraps the flagged ranges of a segment in `==…==`. Builds the result forward from the
    /// source rather than mutating it in place, so no index is invalidated by an earlier
    /// insertion.
    static func mark(_ text: String, flags: [TranscriptFlag]) -> String {
        let ranges = flaggedRanges(in: text, flags: flags)
        guard !ranges.isEmpty else { return text }

        var out = ""
        var cursor = text.startIndex
        for range in ranges {
            out += text[cursor..<range.lowerBound]
            out += openMark + text[range] + closeMark
            cursor = range.upperBound
        }
        out += text[cursor...]
        return out
    }

    /// Re-anchors a flag after its segment was rewritten by the refinement pass. If the
    /// flagged wording is gone — the likely case, since refinement changes precisely the
    /// words that were wrong — the flag falls back to covering the whole segment. It loses
    /// precision, never existence.
    static func relocated(_ flag: TranscriptFlag, in newText: String) -> TranscriptFlag {
        guard let substring = flag.substring, !substring.isEmpty else { return flag }
        guard !newText.contains(substring) else { return flag }
        var fallback = flag
        fallback.substring = nil
        return fallback
    }

    /// The complete contents of a transcript file. Kept as one pure function so the format
    /// lives in a single place and can be checked without a recording, a model or a window.
    static func document(entries: [TranscriptEntry], flags: [TranscriptFlag]) -> String {
        // Grouped once instead of scanning `flags` per entry: this runs over the whole
        // transcript every ten seconds, and this path has already paid for one accidentally
        // quadratic loop (see `ingestedStarts` in LiveTranscriptionCoordinator).
        let flagsBySegment = Dictionary(grouping: flags, by: \.segmentStart)
        var lines = entries.map { entry in
            OutputFileManager.transcriptLine(
                start: entry.start,
                text: mark(entry.text, flags: flagsBySegment[entry.start] ?? [])
            )
        }
        // Only when there is something to explain, so an unflagged transcript stays clean.
        if !flags.isEmpty, !lines.isEmpty {
            lines.insert(contentsOf: [legend, ""], at: 0)
        }
        return lines.joined(separator: "\n")
    }
}
