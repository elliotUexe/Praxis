import Foundation
import SwiftData

/// Re-anchors courses onto stable identities, and does it again whenever the vault root
/// changes underneath them.
///
/// A course used to *be* its path. Moving a folder — or, as of 0.4.2, pointing Praxis at a
/// different root — meant `findOrCreateCourse` no longer recognised it and quietly made a
/// second one: the old row kept the tasks and pointed at nothing, the new row was empty.
///
/// Everything here is additive. `Course.id` is never rewritten, so a rolled-back build
/// still opens the store and still reads the paths it expects; `stableID` and
/// `relativePath` are simply invisible to it. That matters because
/// `TaskStoreCoordinator` calls `fatalError` when the container refuses to open — a
/// destructive migration would have turned "reinstall the previous version" into "the
/// previous version no longer launches".
enum CourseMigration {
    struct Outcome {
        var resolved: [Course] = []
        var unresolved: [Course] = []
        var backupURL: URL?
    }

    /// Copies the store next to itself before anything is written. Cheap insurance: the
    /// file is under a megabyte, and it is the only way back if a re-anchoring goes wrong.
    @discardableResult
    static func backupStore(at storeURL: URL) -> URL? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let destination = storeURL
            .deletingLastPathComponent()
            .appendingPathComponent("Backups", isDirectory: true)
            .appendingPathComponent("PraxisTasks_\(formatter.string(from: Date())).store")

        try? FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard (try? FileManager.default.copyItem(at: storeURL, to: destination)) != nil else { return nil }
        return destination
    }

    /// Gives every course a stable identity and a path relative to the current root.
    ///
    /// Idempotent by construction: a course that already carries a `stableID` whose folder
    /// still resolves is left alone, so running this at every launch costs a few file
    /// checks and changes nothing.
    static func run(context: ModelContext, root: URL) -> Outcome {
        var outcome = Outcome()
        guard let courses = try? context.fetch(FetchDescriptor<Course>()) else { return outcome }

        for course in courses {
            if let stableID = course.stableID {
                if relocate(course, stableID: stableID, root: root) {
                    outcome.resolved.append(course)
                } else {
                    outcome.unresolved.append(course)
                }
                continue
            }

            guard let folder = anchor(for: course, root: root) else {
                outcome.unresolved.append(course)
                continue
            }
            // Marker first, database second. A crash between the two leaves a folder
            // carrying an id nothing points at yet, which the next run simply adopts —
            // the reverse order would leave a row pointing at a marker that never existed.
            guard let id = CourseMarker.ensure(in: folder) else {
                outcome.unresolved.append(course)
                continue
            }
            course.stableID = id
            course.relativePath = VaultSettings.relativePath(for: folder)
            outcome.resolved.append(course)
        }

        return outcome
    }

    /// Folds rows that share a `stableID` into one.
    ///
    /// Seen in the field two days after 0.4.2: two `Automatique` rows carrying the same
    /// marker id, one legacy with seven tasks, one created since with two. It can only
    /// arise from `findOrCreateCourse` running at a moment the legacy row had not yet been
    /// anchored — whatever the exact trigger was, a client asking for the course list
    /// would have been handed two ids for one subject. The legacy row wins, its tasks are
    /// preserved and the newer row's tasks move over; nothing is deleted but the empty row.
    static func mergeDuplicates(context: ModelContext) -> Int {
        guard let courses = try? context.fetch(FetchDescriptor<Course>()) else { return 0 }
        let grouped = Dictionary(grouping: courses.filter { $0.stableID != nil }, by: { $0.stableID! })
        var merged = 0
        for (_, group) in grouped where group.count > 1 {
            // A legacy row is one whose frozen `id` still carries the old root prefix and
            // so differs from its current relative path. Prefer it: it is the older row.
            let keeper = group.first { $0.id != $0.resolvedRelativePath } ?? group[0]
            for duplicate in group where duplicate !== keeper {
                for task in duplicate.tasks { task.course = keeper }
                context.delete(duplicate)
                merged += 1
            }
        }
        return merged
    }

    /// Confirms a known course is still where it says, and follows it if it moved.
    ///
    /// The marker search covers the ordinary case — a folder dragged elsewhere inside the
    /// vault — without asking anything. It refuses to choose when two folders carry the same
    /// id, which happens the moment a course folder is duplicated: picking one would silently
    /// point a term's worth of tasks at a copy.
    static func relocate(_ course: Course, stableID: String, root: URL) -> Bool {
        if let path = course.relativePath {
            let expected = VaultSettings.url(forRelativePath: path)
            if CourseMarker.read(in: expected) == stableID { return true }
        }

        let matches = CourseMarker.locate(id: stableID, under: root)
        guard matches.count == 1, let found = matches.first else { return false }
        course.relativePath = VaultSettings.relativePath(for: found)
        course.displayName = found.lastPathComponent
        return true
    }

    /// Finds the folder a pre-0.4.2 course refers to.
    ///
    /// Its stored path is relative to whatever root was configured when it was created, and
    /// the root has very likely just changed — Pierre's courses were stored as
    /// `01_IMT/2A/INP/Automatique` under a vault root, and the natural new root *is* that
    /// `01_IMT` folder. So the longest suffix of the stored path that resolves under the
    /// current root is taken, which turns the example into `2A/INP/Automatique`.
    ///
    /// Never falls back to matching on name alone: a real vault has two `Electronique`
    /// folders and two `SupplyChain`, and a wrong guess here attaches a term of work to the
    /// wrong subject.
    static func anchor(for course: Course, root: URL) -> URL? {
        var components = course.resolvedRelativePath.split(separator: "/").map(String.init)
        while !components.isEmpty {
            let candidate = root.appendingPathComponent(components.joined(separator: "/"))
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return candidate
            }
            components.removeFirst()
        }
        return nil
    }
}
