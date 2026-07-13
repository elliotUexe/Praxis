import Foundation

/// Enumerates real UE folders on disk under `01_IMT/{1A,2A,3A}/{GEM,INP}/` — no hardcoded
/// course list, always reflects the vault's actual current structure (including folders
/// that exist but are still empty, like 2A while Pierre is starting that year). Shared by
/// the recording destination override menu (`AppSessionStore`) and the Tâches CRUD course
/// picker (`TaskFormSheet`) so there is exactly one place that knows how to find a course.
enum CourseDirectoryScanner {
    static let years = ["1A", "2A", "3A"]
    static let poles = ["GEM", "INP"]

    static func scan() -> [CourseOption] {
        let fm = FileManager.default
        var options: [CourseOption] = []
        for year in years {
            for pole in poles {
                let poleURL = VaultPaths.coursesRoot.appendingPathComponent(year).appendingPathComponent(pole)
                guard let entries = try? fm.contentsOfDirectory(at: poleURL, includingPropertiesForKeys: [.isDirectoryKey]) else { continue }
                for entry in entries {
                    guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
                    let relativePath = "01_IMT/\(year)/\(pole)/\(entry.lastPathComponent)"
                    options.append(CourseOption(vaultPath: relativePath, year: year, pole: pole))
                }
            }
        }
        return options.sorted { $0.displayName < $1.displayName }
    }
}
