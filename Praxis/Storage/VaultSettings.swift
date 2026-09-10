import Foundation

/// Where Praxis looks for courses, and how deep they sit.
///
/// Both were compile-time constants until 0.4.2: the root was hardcoded to one Obsidian
/// vault, and the tree shape was hardcoded to `01_IMT/{1A,2A,3A}/{GEM,INP}/<course>` with
/// the year and pole lists written out as string literals. None of that means anything to
/// anyone else, and it means nothing to Pierre either the day the school changes how it
/// splits its years.
///
/// The app is not sandboxed — it carries only the microphone entitlement — so a stored path
/// is enough here. A security-scoped bookmark would be required if that ever changes.
enum VaultSettings {
    static let rootKey = "vaultRootPath"
    static let courseDepthKey = "courseDepth"

    /// Where the previous versions looked, plus the folder that actually held the courses.
    /// Used as the default so the first launch after upgrading finds everything without
    /// asking anything.
    static var defaultRoot: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Documents")
            .appendingPathComponent("Obsidian")
            .appendingPathComponent("01_IMT")
    }

    /// Levels between the root and a course folder: `2A/INP/Automatique` is 3.
    ///
    /// A discovery hint, not a rule. Measured on a real vault it identifies 47 course
    /// folders out of 50; the three it misses sit in a branch shaped differently, and are
    /// picked by hand instead. See `CourseMarker`, which is what actually decides.
    static let defaultCourseDepth = 3

    static var root: URL {
        get {
            UserDefaults.standard.string(forKey: rootKey).map(URL.init(fileURLWithPath:)) ?? defaultRoot
        }
        set {
            UserDefaults.standard.set(newValue.path, forKey: rootKey)
        }
    }

    static var courseDepth: Int {
        get {
            let stored = UserDefaults.standard.integer(forKey: courseDepthKey)
            return stored > 0 ? stored : defaultCourseDepth
        }
        set {
            UserDefaults.standard.set(max(1, newValue), forKey: courseDepthKey)
        }
    }

    static var isRootReachable: Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }

    /// Course folder for a path relative to the root, and the inverse. The relative form is
    /// what gets stored, so moving the whole vault only changes one setting.
    static func url(forRelativePath path: String) -> URL {
        root.appendingPathComponent(path)
    }

    static func relativePath(for url: URL) -> String? {
        let rootPath = root.standardizedFileURL.path
        let candidate = url.standardizedFileURL.path
        guard candidate.hasPrefix(rootPath) else { return nil }
        return String(candidate.dropFirst(rootPath.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// Where a course's recordings go. The name stays fixed: it is a convention shared with
    /// the vault's own folder layout, not something worth a setting.
    static func transcriptionsFolder(forRelativePath path: String) -> URL {
        url(forRelativePath: path).appendingPathComponent("Transcriptions")
    }

    static func displayName(forRelativePath path: String) -> String {
        (path as NSString).lastPathComponent
    }
}
