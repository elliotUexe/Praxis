import Foundation
import AppKit

/// A hidden file that makes a folder a course, and keeps it that folder no matter where it
/// is moved or what it is renamed to.
///
/// Depth alone cannot decide what a course is. Measured on a real vault: a course folder is
/// never a leaf — `Automatique` contains seven subfolders — so "the leaf is the course"
/// would have produced 243 false courses and found none of the 50 real ones. And a single
/// depth misses branches shaped differently: three folders under a `TOEIC/` branch sit one
/// level shallower than the rest.
///
/// So depth only ever *proposes* candidates. The marker is what decides, and because it
/// travels with the folder it is also the answer to "this folder moved, find it again".
enum CourseMarker {
    static let fileName = ".praxis"

    struct Contents: Codable {
        let id: String
        let createdAt: Date
    }

    // MARK: - Reading and writing

    static func url(in folder: URL) -> URL {
        folder.appendingPathComponent(fileName)
    }

    static func read(in folder: URL) -> String? {
        guard let data = try? Data(contentsOf: url(in: folder)) else { return nil }
        // The date strategy has to match the one `ensure` writes with. It did not, at first,
        // and the failure was silent in the worst way: every read returned nil, so a folder
        // already marked looked unmarked — `ensure` would have replaced its identity on the
        // next call, and a moved folder could never have been found again.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let contents = try? decoder.decode(Contents.self, from: data) else { return nil }
        return contents.id
    }

    /// Writes the marker if the folder does not already carry one, and returns the id that
    /// ends up in it. An existing marker is never overwritten: it is the folder's identity,
    /// and replacing it would orphan whatever already points at it.
    @discardableResult
    static func ensure(in folder: URL, id: String = UUID().uuidString) -> String? {
        if let existing = read(in: folder) { return existing }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(Contents(id: id, createdAt: Date())) else { return nil }
        guard (try? data.write(to: url(in: folder), options: .atomic)) != nil else { return nil }
        return id
    }

    // MARK: - Finding

    /// Every folder under `root` carrying this id. Returns more than one when a course
    /// folder has been duplicated — copying a folder copies its marker — and the caller is
    /// expected to refuse to guess in that case rather than picking one.
    static func locate(id: String, under root: URL) -> [URL] {
        courseFolders(under: root).filter { read(in: $0) == id }
    }

    /// Every marked folder under `root`, at any depth.
    static func courseFolders(under root: URL) -> [URL] {
        var found: [URL] = []
        let keys: [URLResourceKey] = [.isDirectoryKey]
        guard let walker = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        for case let url as URL in walker {
            guard isEligible(url) else { continue }
            if read(in: url) != nil { found.append(url) }
        }
        return found
    }

    /// The course a file belongs to: the nearest ancestor carrying a marker.
    ///
    /// Replaces a rule that required a path of exactly four components starting with
    /// `01_IMT`, which stops meaning anything once the root and the depth are settings.
    /// Walking up is both simpler and correct whatever the tree looks like.
    static func enclosingCourse(of fileURL: URL, under root: URL) -> URL? {
        let rootPath = root.standardizedFileURL.path
        var folder = fileURL.standardizedFileURL.deletingLastPathComponent()

        while folder.path.hasPrefix(rootPath), folder.path.count >= rootPath.count {
            if read(in: folder) != nil { return folder }
            let parent = folder.deletingLastPathComponent()
            guard parent.path != folder.path else { break }
            folder = parent
        }
        return nil
    }

    // MARK: - Eligibility

    /// A folder that could reasonably be a course.
    ///
    /// Excludes hidden folders, and file packages — a `.numbers` document is a directory,
    /// and one sits at course depth in the real vault, where it would otherwise have been
    /// offered as a subject to record lectures into.
    static func isEligible(_ url: URL) -> Bool {
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { return false }
        guard !url.lastPathComponent.hasPrefix(".") else { return false }
        return !NSWorkspace.shared.isFilePackage(atPath: url.path)
    }
}
