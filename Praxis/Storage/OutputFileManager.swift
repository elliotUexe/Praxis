import Foundation

enum OutputFileManager {
    static func timestampedBaseName(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return "Enregistrement_\(formatter.string(from: date))"
    }

    static func wavURL(in folder: URL, baseName: String) -> URL {
        folder.appendingPathComponent(baseName).appendingPathExtension("wav")
    }

    static func txtURL(in folder: URL, baseName: String) -> URL {
        folder.appendingPathComponent(baseName).appendingPathExtension("txt")
    }

    /// `[H:MM:SS]` prefix used by both transcript paths. Shared so a transcript written
    /// live and one written by importing an audio file are byte-for-byte the same shape —
    /// they land in the same `Transcriptions/` folders and are read by the same eyes.
    static func transcriptTimestamp(_ seconds: Float) -> String {
        let total = Int(seconds)
        return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    static func transcriptLine(start: Float, text: String) -> String {
        "[\(transcriptTimestamp(start))] : \(text.trimmingCharacters(in: .whitespaces))"
    }
}
