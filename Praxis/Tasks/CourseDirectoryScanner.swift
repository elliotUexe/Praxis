import Foundation

/// Finds the course folders under the configured root.
///
/// Two sources, merged. Every folder sitting at the configured depth is *proposed* as a
/// course, which covers a regularly shaped vault without asking anything. And every folder
/// carrying a `CourseMarker` is a course wherever it sits, which covers the exceptions — a
/// branch one level shallower than the rest, a folder picked by hand from the cascade.
///
/// Neither rule alone is enough. Measured on a real vault, depth alone finds 47 of 50 and
/// invents one from a `.numbers` package; markers alone would find nothing until every
/// folder had been visited once.
enum CourseDirectoryScanner {
    static func scan(
        root: URL = VaultSettings.root,
        depth: Int = VaultSettings.courseDepth
    ) -> [CourseOption] {
        var byPath: [String: CourseOption] = [:]

        for folder in foldersAtDepth(depth, under: root) {
            if let option = option(for: folder, root: root) {
                byPath[option.vaultPath] = option
            }
        }
        for folder in CourseMarker.courseFolders(under: root) {
            if let option = option(for: folder, root: root) {
                byPath[option.vaultPath] = option
            }
        }

        return byPath.values.sorted { $0.vaultPath.localizedStandardCompare($1.vaultPath) == .orderedAscending }
    }

    /// The folders exactly `depth` levels below `root`, skipping hidden folders and file
    /// packages at every level so the walk never descends into a document bundle.
    static func foldersAtDepth(_ depth: Int, under root: URL) -> [URL] {
        var level = [root]
        for _ in 0..<max(0, depth) {
            level = level.flatMap { children(of: $0) }
            if level.isEmpty { break }
        }
        return level
    }

    static func children(of folder: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return contents.filter(CourseMarker.isEligible)
    }

    private static func option(for folder: URL, root: URL) -> CourseOption? {
        let rootPath = root.standardizedFileURL.path
        let path = folder.standardizedFileURL.path
        guard path.hasPrefix(rootPath) else { return nil }
        let relative = String(path.dropFirst(rootPath.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !relative.isEmpty else { return nil }
        return CourseOption(vaultPath: relative)
    }
}
