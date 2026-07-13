import SwiftUI

/// Visual differentiation by type per the Praxis MVP plan: Rendus read as urgent (red,
/// countdown), Révisions read as unscheduled work (no date shown — deliberately, they
/// aren't placed on the calendar yet), Points de blocage read as "not actionable by you
/// right now" rather than alarming, Anticipations read as quiet/deferred.
struct TaskRowView: View {
    let task: PraxisTask
    let onToggleDone: () -> Void
    let onTap: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button(action: onToggleDone) {
                Image(systemName: task.isDone ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(task.isDone ? .green : .secondary)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    typeIcon
                    Text(task.title)
                        .strikethrough(task.isDone)
                        .foregroundStyle(task.isDone ? .secondary : .primary)
                    if task.needsReview {
                        Text("à relire")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.orange.opacity(0.2))
                            .clipShape(Capsule())
                    }
                }
                if let courseName = task.course?.displayName {
                    Text(courseName)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                secondaryInfo
            }
            Spacer()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }

    private var typeIcon: some View {
        Group {
            switch task.type {
            case .rendu:
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
            case .revisionFond:
                Image(systemName: "book.fill").foregroundStyle(.blue)
            case .revisionDS:
                Image(systemName: "book.closed.fill").foregroundStyle(Color.indigo)
            case .blocage:
                Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(Color.orange.opacity(0.7))
            case .anticipation:
                Image(systemName: "clock.fill").foregroundStyle(.gray)
            }
        }
        .font(.caption)
    }

    @ViewBuilder
    private var secondaryInfo: some View {
        switch task.type {
        case .rendu:
            if let due = task.dueDate {
                Text(dueCountdown(due))
                    .font(.caption2)
                    .foregroundStyle(due < Date() ? .red : .secondary)
            }
        case .revisionFond, .revisionDS:
            if let minutes = task.estimatedDurationMinutes {
                Text("\(minutes) min estimées")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        case .blocage:
            if let waitingOn = task.waitingOn, !waitingOn.isEmpty {
                Text("En attente : \(waitingOn)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        case .anticipation:
            if let horizon = task.horizonDate {
                Text("Horizon : \(horizon.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func dueCountdown(_ date: Date) -> String {
        let calendar = Calendar.current
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: Date()),
            to: calendar.startOfDay(for: date)
        ).day ?? 0
        if days < 0 { return "En retard (J\(days))" }
        if days == 0 { return "Aujourd'hui" }
        return "J-\(days)"
    }
}
