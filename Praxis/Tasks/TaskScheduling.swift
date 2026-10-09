import Foundation

/// Where a task sits on the timeline. These are the sections of the task list, in order.
///
/// The list used to be grouped by `TaskType`, which answered "what kind of work is this"
/// when the question actually being asked is "what do I have to do next". Type is still
/// visible on every row; it just no longer decides how the list is cut up.
enum TaskHorizon: Int, CaseIterable, Identifiable {
    case overdue
    case thisWeek
    case thisMonth
    case upcoming
    case later
    case undated

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .overdue: return "En retard"
        case .thisWeek: return "Cette semaine"
        case .thisMonth: return "Ce mois-ci"
        case .upcoming: return "À venir"
        case .later: return "Plus tard"
        case .undated: return "Sans date"
        }
    }

    /// A DS six months out and an untriaged note are both noise in the daily view, for
    /// opposite reasons. Neither is hidden, both start folded.
    var startsCollapsed: Bool {
        self == .later || self == .undated
    }
}

/// Everything the task list needs to know about dates, kept free of SwiftData so it can be
/// exercised without a store, a window, or a model container.
enum TaskScheduling {
    /// Pierre's own boundary: past two months, work stops competing for attention today.
    static let laterThresholdDays = 60

    /// The date a task is actually judged by.
    ///
    /// A dossier due in December whose first draft is due in November is, today, a November
    /// task: the deadline that governs your next action is the nearest one, not the final
    /// one. So the effective date is the earliest of the task's own date and the dates of
    /// its *unfinished* subtasks. Ticking the draft off lets the task fall back to December
    /// on its own.
    ///
    /// The final deadline is never replaced by this, only ranked by it — missing it is what
    /// actually costs, so the row keeps showing it.
    static func effectiveDate(taskDate: Date?, openSubtaskDates: [Date]) -> Date? {
        ([taskDate].compactMap { $0 } + openSubtaskDates).min()
    }

    static func horizon(for date: Date?, now: Date = Date()) -> TaskHorizon {
        guard let date else { return .undated }
        let days = daysUntil(date, from: now)
        if days < 0 { return .overdue }
        if days <= 7 { return .thisWeek }
        if days <= 30 { return .thisMonth }
        if days <= laterThresholdDays { return .upcoming }
        return .later
    }

    /// Whole days between two calendar days, so "tomorrow at 8am" is 1 whatever time it is
    /// now, and a deadline earlier today is 0 rather than already overdue.
    static func daysUntil(_ date: Date, from now: Date = Date()) -> Int {
        let calendar = Calendar.current
        return calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: now),
            to: calendar.startOfDay(for: date)
        ).day ?? 0
    }

    static func countdownLabel(for date: Date, now: Date = Date()) -> String {
        let days = daysUntil(date, from: now)
        if days < 0 { return "En retard (J\(days))" }
        if days == 0 { return "Aujourd'hui" }
        if days == 1 { return "Demain" }
        return "J-\(days)"
    }

    /// Same countdown, sized for the list's date column. The section header already says
    /// "En retard" and the row is already red, so the row itself only has to say how late —
    /// "En retard (J-12)" spends sixteen characters restating its own section, and every
    /// other row pays for that width in dead space.
    static func compactCountdownLabel(for date: Date, now: Date = Date()) -> String {
        let days = daysUntil(date, from: now)
        if days < 0 { return "Retard \(-days)j" }
        if days == 0 { return "Aujourd'hui" }
        if days == 1 { return "Demain" }
        return "J-\(days)"
    }

    /// A milestone dated after the deadline it is meant to precede. Worth showing rather
    /// than quietly sorting: it means one of the two dates is wrong.
    static func hasSubtaskPastDeadline(taskDate: Date?, openSubtaskDates: [Date]) -> Bool {
        guard let taskDate else { return false }
        let deadline = Calendar.current.startOfDay(for: taskDate)
        return openSubtaskDates.contains { Calendar.current.startOfDay(for: $0) > deadline }
    }

    /// Offsets offered next to a date field. Setting a DS six months out by clicking the
    /// calendar's month arrow twelve times is the friction that stops dates being entered
    /// at all, which is the whole problem this release exists to fix.
    static let quickOffsets: [(label: String, days: Int)] = [
        ("1 sem.", 7),
        ("1 mois", 30),
        ("3 mois", 90),
        ("6 mois", 182)
    ]

    static func date(offsetByDays days: Int, from now: Date = Date()) -> Date {
        Calendar.current.date(byAdding: .day, value: days, to: now) ?? now
    }

    /// What a task still costs, in minutes, or nil when nobody has estimated it.
    ///
    /// A task with subtasks is measured by them alone: each subtask has its own estimate,
    /// so the task's own figure would count the same work twice. Only the unfinished ones
    /// are added up, which is what a planner needs. A task whose subtasks are all done has
    /// nothing left (0), not "unknown".
    static func remainingMinutes(ownEstimate: Int?, subtaskEstimates: [(minutes: Int, isDone: Bool)]) -> Int? {
        guard !subtaskEstimates.isEmpty else { return ownEstimate }
        return subtaskEstimates.filter { !$0.isDone }.map(\.minutes).reduce(0, +)
    }

    /// "45 min", "2 h", "1 h 30". Hours past an hour, because "150 min" has to be divided
    /// in your head before it means anything.
    static func durationLabel(minutes: Int) -> String {
        guard minutes >= 60 else { return "\(minutes) min" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours) h" : "\(hours) h \(String(format: "%02d", rest))"
    }

    /// Order inside one section of the list: by day, then the higher priority first among
    /// tasks due the same day, then the most recently written down. Compared by calendar
    /// day, not by timestamp — a date picked at 9:14 and one picked at 17:02 are the same
    /// deadline, and comparing the times made every tie a coin toss on when it was typed.
    static func precedes(
        leftDate: Date?, leftPriority: TaskPriority, leftCreatedAt: Date,
        rightDate: Date?, rightPriority: TaskPriority, rightCreatedAt: Date
    ) -> Bool {
        if let leftDate, let rightDate {
            let calendar = Calendar.current
            let l = calendar.startOfDay(for: leftDate)
            let r = calendar.startOfDay(for: rightDate)
            if l != r { return l < r }
        } else if (leftDate == nil) != (rightDate == nil) {
            // Only reached across sections by callers that sort a mixed list; dated first.
            return leftDate != nil
        }
        if leftPriority != rightPriority { return leftPriority.rank > rightPriority.rank }
        // Undated tasks have nothing else to rank them by, so the most recently written
        // down comes first — it is the one still fresh in mind.
        return leftCreatedAt > rightCreatedAt
    }
}
