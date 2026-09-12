import Foundation
import SwiftData
import MCP

/// The tools Praxis exposes over MCP, and what they do to the store.
///
/// Every handler hops to the main actor and works on `TaskStoreCoordinator.modelContext`,
/// the context the SwiftUI views observe. That is the whole mechanism behind "the list
/// updates by itself when Cowork adds a task": there is no second writer to reconcile.
///
/// The descriptions carry the semantics a client needs — what a `revisionDS` is, what the
/// effective date means, that subtasks are milestones — so nothing has to be pasted into a
/// conversation for the model to use these correctly. The tool schema *is* the context.
struct PraxisMCPTools: @unchecked Sendable {
    let taskStore: TaskStoreCoordinator

    static let instructions = """
    Praxis suit les cours et les tâches d'un étudiant. Cinq types de tâche : rendu (livrable \
    avec date limite), revisionDS (préparer un DS, la date est celle du DS), revisionFond \
    (réviser sans échéance dure), blocage (en attente de quelqu'un), anticipation (mention \
    lointaine). Toute tâche peut porter une date. Les sous-tâches sont des jalons et peuvent \
    porter leur propre date ; la date effective d'une tâche est la plus proche entre la \
    sienne et celles de ses sous-tâches non terminées — c'est elle qui compte pour planifier. \
    Les dates sont au format AAAA-MM-JJ. Une tâche créée par un outil arrive marquée « à \
    relire » pour que l'étudiant la valide.
    """

    // MARK: - Catalogue

    static let catalogue: [Tool] = [
        Tool(
            name: "list_courses",
            description: "Liste les matières connues, avec leur identifiant stable, leur nom, leur chemin dans le vault et le nombre de tâches ouvertes.",
            inputSchema: ["type": "object", "properties": [:]]
        ),
        Tool(
            name: "list_tasks",
            description: "Liste les tâches. Par défaut seulement les tâches ouvertes, toutes matières. Chaque tâche porte sa date effective et son horizon (overdue, thisWeek, thisMonth, upcoming, later, undated).",
            inputSchema: [
                "type": "object",
                "properties": [
                    "courseId": ["type": "string", "description": "Restreindre à une matière (identifiant de list_courses)."],
                    "horizon": ["type": "string", "enum": ["overdue", "thisWeek", "thisMonth", "upcoming", "later", "undated"]],
                    "includeDone": ["type": "boolean", "description": "Inclure les tâches terminées. Faux par défaut."]
                ]
            ]
        ),
        Tool(
            name: "get_task",
            description: "Détail complet d'une tâche : sous-tâches, commentaires, dates.",
            inputSchema: [
                "type": "object",
                "properties": ["id": ["type": "string"]],
                "required": ["id"]
            ]
        ),
        Tool(
            name: "create_task",
            description: "Crée une tâche. Le type est obligatoire ; la date (AAAA-MM-JJ) est fortement recommandée, une tâche sans date atterrit dans « Sans date » et n'est pas planifiable.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "title": ["type": "string"],
                    "type": ["type": "string", "enum": ["rendu", "revisionDS", "revisionFond", "blocage", "anticipation"]],
                    "courseId": ["type": "string", "description": "Identifiant de matière (list_courses)."],
                    "dueDate": ["type": "string", "description": "AAAA-MM-JJ"],
                    "detail": ["type": "string"],
                    "estimatedDurationMinutes": ["type": "integer"],
                    "waitingOn": ["type": "string", "description": "Pour un blocage : ce qu'on attend."],
                    "source": ["type": "string", "description": "D'où vient la tâche, par exemple « mail du 12/09 ». Ajouté en commentaire."]
                ],
                "required": ["title", "type"]
            ]
        ),
        Tool(
            name: "update_task",
            description: "Modifie les champs fournis d'une tâche existante. Les champs omis ne changent pas.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "id": ["type": "string"],
                    "title": ["type": "string"],
                    "type": ["type": "string", "enum": ["rendu", "revisionDS", "revisionFond", "blocage", "anticipation"]],
                    "courseId": ["type": "string"],
                    "dueDate": ["type": "string", "description": "AAAA-MM-JJ, ou chaîne vide pour retirer la date."],
                    "detail": ["type": "string"],
                    "estimatedDurationMinutes": ["type": "integer"]
                ],
                "required": ["id"]
            ]
        ),
        Tool(
            name: "complete_task",
            description: "Marque une tâche terminée (ou la rouvre avec done=false).",
            inputSchema: [
                "type": "object",
                "properties": ["id": ["type": "string"], "done": ["type": "boolean"]],
                "required": ["id"]
            ]
        ),
        Tool(
            name: "add_subtask",
            description: "Ajoute un jalon à une tâche. Avec une date, il devient la prochaine échéance de la tâche tant qu'il n'est pas terminé.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "taskId": ["type": "string"],
                    "title": ["type": "string"],
                    "estimatedMinutes": ["type": "integer"],
                    "dueDate": ["type": "string", "description": "AAAA-MM-JJ"]
                ],
                "required": ["taskId", "title"]
            ]
        ),
        Tool(
            name: "add_comment",
            description: "Ajoute un commentaire horodaté à une tâche, par exemple une information trouvée dans un mail.",
            inputSchema: [
                "type": "object",
                "properties": ["taskId": ["type": "string"], "text": ["type": "string"]],
                "required": ["taskId", "text"]
            ]
        )
    ]

    // MARK: - Dispatch

    func call(_ name: String, arguments: [String: Value]) async -> CallTool.Result {
        do {
            let payload: Any = try await MainActor.run { () throws -> Any in
                switch name {
                case "list_courses": return try listCourses()
                case "list_tasks": return try listTasks(arguments)
                case "get_task": return try getTask(arguments)
                case "create_task": return try createTask(arguments)
                case "update_task": return try updateTask(arguments)
                case "complete_task": return try completeTask(arguments)
                case "add_subtask": return try addSubtask(arguments)
                case "add_comment": return try addComment(arguments)
                default: throw ToolError.unknownTool(name)
                }
            }
            return CallTool.Result(content: [.text(Self.json(payload))])
        } catch {
            return CallTool.Result(content: [.text(error.localizedDescription)], isError: true)
        }
    }

    enum ToolError: LocalizedError {
        case unknownTool(String)
        case missing(String)
        case invalid(String)
        case notFound(String)

        var errorDescription: String? {
            switch self {
            case let .unknownTool(name): return "Outil inconnu : \(name)"
            case let .missing(field): return "Champ obligatoire manquant : \(field)"
            case let .invalid(what): return "Valeur invalide : \(what)"
            case let .notFound(what): return "Introuvable : \(what)"
            }
        }
    }

    // MARK: - Reads

    @MainActor
    private func listCourses() throws -> Any {
        let courses = try taskStore.modelContext.fetch(FetchDescriptor<Course>())
        return courses
            .filter { $0.stableID != nil }
            .map { course in
                [
                    "id": course.stableID ?? "",
                    "name": course.displayName,
                    "path": course.resolvedRelativePath,
                    "openTaskCount": course.tasks.filter { !$0.isDone && !$0.isRejected }.count
                ] as [String: Any]
            }
            .sorted { ($0["path"] as? String ?? "") < ($1["path"] as? String ?? "") }
    }

    @MainActor
    private func listTasks(_ arguments: [String: Value]) throws -> Any {
        let includeDone = arguments["includeDone"]?.boolValue ?? false
        let courseFilter = arguments["courseId"]?.stringValue
        let horizonFilter = arguments["horizon"]?.stringValue

        var tasks = try taskStore.modelContext.fetch(
            FetchDescriptor<PraxisTask>(predicate: #Predicate { !$0.isRejected })
        )
        if !includeDone { tasks = tasks.filter { !$0.isDone } }
        if let courseFilter { tasks = tasks.filter { $0.course?.stableID == courseFilter } }
        if let horizonFilter { tasks = tasks.filter { Self.horizonName($0.horizon) == horizonFilter } }

        return tasks
            .sorted { ($0.effectiveDueDate ?? .distantFuture) < ($1.effectiveDueDate ?? .distantFuture) }
            .map { Self.summary(of: $0) }
    }

    @MainActor
    private func getTask(_ arguments: [String: Value]) throws -> Any {
        let task = try findTask(arguments["id"]?.stringValue)
        var payload = Self.summary(of: task)
        payload["comments"] = task.comments
            .sorted { $0.createdAt < $1.createdAt }
            .map { ["text": $0.text, "source": $0.source, "createdAt": Self.iso($0.createdAt)] }
        return payload
    }

    // MARK: - Writes

    @MainActor
    private func createTask(_ arguments: [String: Value]) throws -> Any {
        guard let title = arguments["title"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            throw ToolError.missing("title")
        }
        guard let rawType = arguments["type"]?.stringValue, let type = TaskType(rawValue: rawType) else {
            throw ToolError.invalid("type")
        }

        let task = PraxisTask(title: title, type: type, origin: "mcp")
        task.detail = arguments["detail"]?.stringValue
        task.dueDate = try Self.date(from: arguments["dueDate"])
        task.estimatedDurationMinutes = arguments["estimatedDurationMinutes"]?.intValue
        task.waitingOn = arguments["waitingOn"]?.stringValue
        if let courseID = arguments["courseId"]?.stringValue {
            task.course = try findCourse(courseID)
        }
        taskStore.modelContext.insert(task)

        if let source = arguments["source"]?.stringValue, !source.isEmpty {
            let comment = TaskComment(text: "Source : \(source)", source: "mcp", task: task)
            taskStore.modelContext.insert(comment)
        }
        taskStore.save()
        return Self.summary(of: task)
    }

    @MainActor
    private func updateTask(_ arguments: [String: Value]) throws -> Any {
        let task = try findTask(arguments["id"]?.stringValue)
        if let title = arguments["title"]?.stringValue, !title.isEmpty { task.title = title }
        if let rawType = arguments["type"]?.stringValue {
            guard let type = TaskType(rawValue: rawType) else { throw ToolError.invalid("type") }
            task.type = type
        }
        if let detail = arguments["detail"]?.stringValue { task.detail = detail.isEmpty ? nil : detail }
        if let rawDate = arguments["dueDate"]?.stringValue {
            task.dueDate = rawDate.isEmpty ? nil : try Self.date(from: arguments["dueDate"])
        }
        if let minutes = arguments["estimatedDurationMinutes"]?.intValue { task.estimatedDurationMinutes = minutes }
        if let courseID = arguments["courseId"]?.stringValue { task.course = try findCourse(courseID) }
        task.updatedAt = Date()
        taskStore.save()
        return Self.summary(of: task)
    }

    @MainActor
    private func completeTask(_ arguments: [String: Value]) throws -> Any {
        let task = try findTask(arguments["id"]?.stringValue)
        let done = arguments["done"]?.boolValue ?? true
        task.isDone = done
        task.completedAt = done ? Date() : nil
        task.updatedAt = Date()
        taskStore.save()
        return Self.summary(of: task)
    }

    @MainActor
    private func addSubtask(_ arguments: [String: Value]) throws -> Any {
        let task = try findTask(arguments["taskId"]?.stringValue)
        guard let title = arguments["title"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            throw ToolError.missing("title")
        }
        let subtask = Subtask(
            title: title,
            estimatedMinutes: max(5, arguments["estimatedMinutes"]?.intValue ?? 30),
            order: task.subtasks.count,
            origin: "mcp",
            dueDate: try Self.date(from: arguments["dueDate"]),
            parentTask: task
        )
        taskStore.modelContext.insert(subtask)
        task.updatedAt = Date()
        taskStore.save()
        return Self.summary(of: task)
    }

    @MainActor
    private func addComment(_ arguments: [String: Value]) throws -> Any {
        let task = try findTask(arguments["taskId"]?.stringValue)
        guard let text = arguments["text"]?.stringValue, !text.isEmpty else { throw ToolError.missing("text") }
        let comment = TaskComment(text: text, source: "mcp", task: task)
        taskStore.modelContext.insert(comment)
        task.updatedAt = Date()
        taskStore.save()
        return ["ok": true, "taskId": task.id.uuidString]
    }

    // MARK: - Lookup

    @MainActor
    private func findTask(_ rawID: String?) throws -> PraxisTask {
        guard let rawID, let id = UUID(uuidString: rawID) else { throw ToolError.invalid("id") }
        let matches = try taskStore.modelContext.fetch(
            FetchDescriptor<PraxisTask>(predicate: #Predicate { $0.id == id })
        )
        guard let task = matches.first else { throw ToolError.notFound("tâche \(rawID)") }
        return task
    }

    @MainActor
    private func findCourse(_ stableID: String) throws -> Course {
        let matches = try taskStore.modelContext.fetch(
            FetchDescriptor<Course>(predicate: #Predicate { $0.stableID == stableID })
        )
        guard let course = matches.first else { throw ToolError.notFound("matière \(stableID)") }
        return course
    }

    // MARK: - Serialisation

    @MainActor
    private static func summary(of task: PraxisTask) -> [String: Any] {
        [
            "id": task.id.uuidString,
            "title": task.title,
            "type": task.type.rawValue,
            "detail": task.detail as Any,
            "courseId": task.course?.stableID as Any,
            "courseName": task.course?.displayName as Any,
            "isDone": task.isDone,
            "completedAt": task.completedAt.map(iso) as Any,
            "dueDate": task.dueDate.map(day) as Any,
            "effectiveDueDate": task.effectiveDueDate.map(day) as Any,
            "horizon": horizonName(task.horizon),
            "estimatedDurationMinutes": task.estimatedDurationMinutes as Any,
            "blockedReason": task.blockedReason as Any,
            "waitingOn": task.waitingOn as Any,
            "needsReview": task.needsReview,
            "origin": task.origin,
            "createdAt": iso(task.createdAt),
            "attachments": task.attachments
                .sorted { $0.addedAt < $1.addedAt }
                .map { ["name": $0.displayName, "path": $0.relativePath] },
            "subtasks": task.subtasks
                .sorted { $0.order < $1.order }
                .map { subtask -> [String: Any] in
                    [
                        "id": subtask.id.uuidString,
                        "title": subtask.title,
                        "estimatedMinutes": subtask.estimatedMinutes,
                        "dueDate": subtask.dueDate.map(day) as Any,
                        "isDone": subtask.isDone
                    ]
                }
        ]
    }

    private static func horizonName(_ horizon: TaskHorizon) -> String {
        switch horizon {
        case .overdue: return "overdue"
        case .thisWeek: return "thisWeek"
        case .thisMonth: return "thisMonth"
        case .upcoming: return "upcoming"
        case .later: return "later"
        case .undated: return "undated"
        }
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static func day(_ date: Date) -> String { dayFormatter.string(from: date) }
    private static func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

    private static func date(from value: Value?) throws -> Date? {
        guard let raw = value?.stringValue, !raw.isEmpty else { return nil }
        guard let date = dayFormatter.date(from: raw) else { throw ToolError.invalid("date « \(raw) », attendu AAAA-MM-JJ") }
        return date
    }

    /// `nil` in a payload becomes JSON `null`; `Any`-typed optionals are unwrapped for
    /// `JSONSerialization`, which refuses `Optional` values outright.
    private static func json(_ payload: Any) -> String {
        let cleaned = Self.stripOptionals(payload)
        guard JSONSerialization.isValidJSONObject(cleaned),
              let data = try? JSONSerialization.data(withJSONObject: cleaned, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    /// Optionals are detected through `Mirror`, not through a cast. `case let x as Any?`
    /// matches *every* value — anything can be wrapped in an optional — so a plain string
    /// was wrapped, unwrapped, and fed straight back in, until the stack ran out. That took
    /// the whole app down on the first real tool call in 0.4.3; the harness had not caught
    /// it because its stand-in tool never went through this path.
    private static func stripOptionals(_ value: Any) -> Any {
        if let dictionary = value as? [String: Any] { return dictionary.mapValues(stripOptionals) }
        if let array = value as? [Any] { return array.map(stripOptionals) }
        let mirror = Mirror(reflecting: value)
        guard mirror.displayStyle == .optional else { return value }
        // `.some` has exactly one child, the wrapped value; `.none` has none.
        guard let wrapped = mirror.children.first?.value else { return NSNull() }
        return stripOptionals(wrapped)
    }
}
