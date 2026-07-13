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
}
