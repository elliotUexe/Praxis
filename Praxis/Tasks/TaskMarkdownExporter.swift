import Foundation

/// Pure text generation — no vault writes here. Produces a Tasks-plugin-compatible
/// Markdown export that Pierre saves wherever he wants via NSSavePanel (Phase 4:
/// on-demand file export, deliberately NOT an automatic vault injection). Placing the
/// result inside a UE folder makes it pick up automatically in that UE's `_MOC_UE.md`
/// Dataview "Tâches en cours" block (`path includes <folder>` / `not done`) — verified
/// present and working — but that placement is Pierre's manual choice, not this code's.
enum TaskMarkdownExporter {
    private static let sectionOrder: [TaskType] = [.rendu, .revisionFond, .revisionDS, .blocage, .anticipation]

    private static func sectionTitle(for type: TaskType) -> String {
        switch type {
        case .rendu: return "🔴 Rendus"
        case .revisionFond: return "🟡 Révisions de fond"
        case .revisionDS: return "🟣 Révisions pour DS"
        case .blocage: return "🟠 Points de blocage"
        case .anticipation: return "🔵 Anticipations"
        }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// `courseDisplayName` nil ⇒ global export (all courses mixed). `tag` becomes the
    /// vault tag written into frontmatter (e.g. `imt/automatique`) — best-effort guess
    /// from the course name when not supplied; Pierre can always correct it by hand.
    static func markdown(for tasks: [PraxisTask], courseDisplayName: String?, tag: String?) -> String {
        var lines: [String] = []

        lines.append("---")
        lines.append("type: tache")
        lines.append("domaine: imt")
        lines.append("tags: [\(tag ?? "imt/taches")]")
        lines.append("date: \(dateFormatter.string(from: Date()))")
        lines.append("status: actif")
        lines.append("liens_source: []")
        lines.append("---")
        lines.append("")
        lines.append("# Tâches\(courseDisplayName.map { " — \($0)" } ?? "")")
        lines.append("")
        lines.append("> Export Praxis — aller simple. Cocher une case ici ne se répercute pas dans Praxis ; c'est Praxis qui reste la source de vérité, ce fichier n'est qu'une photo exportée à la demande.")
        lines.append("")

        for type in sectionOrder {
            let tasksForType = tasks.filter { $0.type == type }
            guard !tasksForType.isEmpty else { continue }

            lines.append("## \(sectionTitle(for: type))")
            lines.append("")
            for task in tasksForType.sorted(by: { !$0.isDone && $1.isDone }) {
                lines.append(line(for: task))
                if let detail = task.detail, !detail.isEmpty {
                    lines.append("  *\(detail)*")
                }
            }
            lines.append("")
        }

        lines.append("---")
        lines.append("*Exporté le \(dateFormatter.string(from: Date())) par Praxis.*")

        return lines.joined(separator: "\n")
    }

    private static func line(for task: PraxisTask) -> String {
        let checkbox = task.isDone ? "- [x]" : "- [ ]"
        var text = "\(checkbox) \(task.title)"

        switch task.type {
        case .rendu:
            if let due = task.dueDate {
                text += " 📅 \(dateFormatter.string(from: due))"
            }
            text += " #rendu"
        case .revisionFond:
            if let minutes = task.estimatedDurationMinutes {
                text += " (~\(minutes) min)"
            }
            text += " #revision-fond"
        case .revisionDS:
            if let minutes = task.estimatedDurationMinutes {
                text += " (~\(minutes) min)"
            }
            text += " #revision-ds"
        case .blocage:
            if let waitingOn = task.waitingOn, !waitingOn.isEmpty {
                text += " — en attente : \(waitingOn)"
            }
            text += " #blocage"
        case .anticipation:
            if let horizon = task.horizonDate {
                text += " ⏳ \(dateFormatter.string(from: horizon))"
            }
            text += " #anticipation"
        }
        return text
    }

    static func suggestedFilename(courseDisplayName: String?) -> String {
        guard let name = courseDisplayName else { return "Taches.md" }
        return "Taches - \(name).md"
    }
}
