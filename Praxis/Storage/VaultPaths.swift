import Foundation

/// Canonical Obsidian vault location. Confirmed with Pierre during Praxis MVP scoping:
/// `~/Documents/Obsidian` (has the obsidian-livesync plugin). A second, stale iCloud-synced
/// copy exists elsewhere on disk and must never be written to.
enum VaultPaths {
    static let root = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Documents")
        .appendingPathComponent("Obsidian")

    static var scheduleCacheURL: URL {
        root.appendingPathComponent("90_Meta/staging/schedule_cache.json")
    }

    static var coursesRoot: URL {
        root.appendingPathComponent("01_IMT")
    }

    static func transcriptionsFolder(forCourseVaultPath path: String) -> URL {
        root.appendingPathComponent(path).appendingPathComponent("Transcriptions")
    }

    /// Last path component of a vault-relative course path, e.g. "Automatique" for
    /// "01_IMT/2A/INP/Automatique".
    static func courseDisplayName(fromVaultPath path: String) -> String {
        (path as NSString).lastPathComponent
    }

    /// Best-effort course resolution for a file that happens to live inside a UE folder
    /// (e.g. an Import'd historical recording already filed under `01_IMT/...`). Returns
    /// nil for files outside the vault or not under a recognizable `01_IMT/<year>/<pole>/<course>`
    /// path — Phase 5's Import hook falls back to no course in that case, it never guesses.
    static func courseVaultPath(fromFileURL url: URL) -> String? {
        let rootPath = root.path
        guard url.path.hasPrefix(rootPath) else { return nil }
        let relative = String(url.path.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let components = relative.split(separator: "/").map(String.init)
        guard components.count >= 4, components[0] == "01_IMT" else { return nil }
        return components.prefix(4).joined(separator: "/")
    }
}
