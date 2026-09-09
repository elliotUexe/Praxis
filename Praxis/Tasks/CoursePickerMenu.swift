import SwiftUI

/// Année → Pôle → Matière, as a cascading menu.
///
/// Both places that pick a course now share this. The recording destination already had the
/// cascade; the task form had a flat `Picker` listing every course as "2A · INP ·
/// Automatique", which is the same data and the same choice presented two different ways —
/// and which grows unusable as the vault fills up with three years of UEs.
///
/// The list of years and poles comes from `CourseDirectoryScanner`, so an empty year (3A
/// before it starts) simply produces no submenu rather than an empty one.
struct CoursePickerMenu<Trailing: View>: View {
    let courses: [CourseOption]
    let onSelect: (CourseOption) -> Void
    /// Extra items appended after a divider — "Aucun" for a task, "Autre dossier…" for a
    /// recording. The two callers need different escape hatches, and neither belongs in the
    /// cascade itself.
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        ForEach(CourseDirectoryScanner.years, id: \.self) { year in
            let coursesForYear = courses.filter { $0.year == year }
            if !coursesForYear.isEmpty {
                Menu(year) {
                    ForEach(CourseDirectoryScanner.poles, id: \.self) { pole in
                        let coursesForPole = coursesForYear.filter { $0.pole == pole }
                        if !coursesForPole.isEmpty {
                            Menu(pole) {
                                ForEach(coursesForPole) { course in
                                    Button(course.displayName) { onSelect(course) }
                                }
                            }
                        }
                    }
                }
            }
        }
        Divider()
        trailing()
    }
}

extension CoursePickerMenu where Trailing == EmptyView {
    init(courses: [CourseOption], onSelect: @escaping (CourseOption) -> Void) {
        self.init(courses: courses, onSelect: onSelect, trailing: { EmptyView() })
    }
}
