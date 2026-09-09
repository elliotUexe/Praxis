import SwiftUI

/// One task, read left to right as **when · what · where**.
///
/// The previous row stacked a title and three `caption2` grey lines — course, type-specific
/// info, subtask summary — all at the same weight, so nothing told the eye where to land.
/// It also painted the type in one of five saturated system colours, which competed with
/// each other and with the app's own accent without ranking anything.
///
/// Now the date leads, in a fixed-width column so the countdowns form a vertical rail the
/// eye can run down. Colour is functional and scarce: red for late, accent for this week,
/// grey for everything else. The type is a monochrome glyph — in a list, colour has to mean
/// urgency; distinguishing the five types by hue belongs to the type picker, where you are
/// actually choosing between them.
struct TaskRowView: View {
    let task: PraxisTask
    let onToggleDone: () -> Void
    let onTap: () -> Void

    @State private var isHovered = false

    /// Wide enough for the longest label the column can hold ("Aujourd'hui"), and no wider.
    private static let dateColumnWidth: CGFloat = 66

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button(action: onToggleDone) {
                Image(systemName: task.isDone ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(task.isDone ? Color.praxisAccent : .secondary)
            }
            .buttonStyle(.plain)

            dateColumn

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Image(systemName: task.type.iconName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(task.title)
                        .strikethrough(task.isDone)
                        .foregroundStyle(task.isDone ? .secondary : .primary)
                    if task.needsReview {
                        Text("à relire")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.orange.opacity(0.18))
                            .clipShape(Capsule())
                    }
                }
                secondaryLine
            }

            Spacer(minLength: 8)

            if let courseName = task.course?.displayName {
                Text(courseName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.10))
                    .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovered ? Color.secondary.opacity(0.08) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture(perform: onTap)
    }

    /// Fixed width whether or not there is a date, so the titles beside it stay aligned and
    /// an undated task reads as a gap in the rail rather than as a shifted line.
    ///
    /// Leading-aligned, not trailing. Right-aligning inside a column sized for the longest
    /// label left every short one ("J-28") pushed away from the checkbox behind a band of
    /// empty space, and made the left edge ragged. Aligning left gives two clean edges: the
    /// dates under each other, and the titles all starting at the same x.
    @ViewBuilder
    private var dateColumn: some View {
        Group {
            if task.isDone {
                Text(task.completedAt.map { $0.formatted(.dateTime.day().month(.abbreviated)) } ?? "")
                    .foregroundStyle(.tertiary)
            } else if let effective = task.effectiveDueDate {
                Text(TaskScheduling.compactCountdownLabel(for: effective))
                    .foregroundStyle(countdownColor(for: effective))
            } else {
                Text("—")
                    .foregroundStyle(.quaternary)
            }
        }
        .font(.caption.weight(.medium))
        .lineLimit(1)
        .frame(width: Self.dateColumnWidth, alignment: .leading)
    }

    private func countdownColor(for date: Date) -> Color {
        switch TaskScheduling.horizon(for: date) {
        case .overdue: return .red
        case .thisWeek: return .praxisAccent
        default: return .secondary
        }
    }

    /// At most one line, and only when it adds something the columns do not already say.
    /// The milestone case comes first because it explains why the row is where it is: a
    /// dossier sitting in "Ce mois-ci" for a December deadline would otherwise look wrong.
    @ViewBuilder
    private var secondaryLine: some View {
        if task.isDone {
            EmptyView()
        } else if task.isDrivenBySubtask, let milestone = task.nextMilestone {
            HStack(spacing: 4) {
                Image(systemName: "arrow.turn.down.right")
                Text(milestone.title)
                if let deadline = task.dueDate {
                    Text("· rendu le \(deadline.formatted(.dateTime.day().month(.abbreviated)))")
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        } else if task.type == .blocage, let waitingOn = task.waitingOn, !waitingOn.isEmpty {
            Text("En attente : \(waitingOn)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        } else if !task.subtasks.isEmpty {
            let done = task.subtasks.filter(\.isDone).count
            Text("\(done)/\(task.subtasks.count) sous-tâches")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
