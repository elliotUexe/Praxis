import Foundation
import MCP

/// Hosts the MCP server inside Praxis, the way Obsidian's Local REST API plugin hosts one
/// inside Obsidian.
///
/// In-process on purpose. Every tool call that writes lands on the main actor's
/// `ModelContext` — the one the SwiftUI views observe through `@Query` — so a task created
/// by Cowork from a professor's email appears in the list the instant it is saved, with no
/// notification, polling or reload. A separate process would have needed cross-process
/// change notifications between two containers, and the app would have shown stale data
/// until a refetch. Being the single writer is what makes the live update free.
///
/// Reachable only from this machine: the listener binds to `127.0.0.1`, and every request
/// must carry a bearer token generated once and shown in Réglages. Without the token, any
/// local process could inject tasks.
@MainActor
final class MCPServerCoordinator: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var lastError: String?
    @Published private(set) var requestCount = 0

    static let enabledKey = "mcpEnabled"
    static let portKey = "mcpPort"
    static let tokenKey = "mcpToken"
    /// Next to Obsidian's 27123/27124, so the two read as one family in a config file.
    static let defaultPort: UInt16 = 27130

    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static var port: UInt16 {
        get {
            let stored = UserDefaults.standard.integer(forKey: portKey)
            return (1024...65535).contains(stored) ? UInt16(stored) : defaultPort
        }
        set { UserDefaults.standard.set(Int(newValue), forKey: portKey) }
    }

    /// Generated once and kept. Stored in UserDefaults rather than the Keychain because it
    /// only ever guards a loopback port — the same choice Obsidian's plugin makes — and
    /// because a plain key can be pre-seeded alongside the client configuration.
    static var token: String {
        if let existing = UserDefaults.standard.string(forKey: tokenKey), !existing.isEmpty {
            return existing
        }
        let fresh = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        UserDefaults.standard.set(fresh, forKey: tokenKey)
        return fresh
    }

    static var endpointURL: String { "http://127.0.0.1:\(port)/mcp" }

    /// The line to paste into `claude_desktop_config.json`, mirroring the Obsidian entry
    /// already there: `mcp-remote` bridges Claude Desktop's stdio to this HTTP endpoint.
    static var claudeDesktopConfiguration: String {
        """
        "praxis": {
          "command": "npx",
          "args": [
            "mcp-remote@latest",
            "\(endpointURL)",
            "--header",
            "Authorization: Bearer \(token)"
          ]
        }
        """
    }

    private var server: Server?
    private var transport: StatelessHTTPServerTransport?
    private var listener: LocalHTTPListener?

    func start(taskStore: TaskStoreCoordinator) async {
        guard Self.isEnabled, !isRunning else { return }
        lastError = nil

        let tools = PraxisMCPTools(taskStore: taskStore)
        let server = Server(
            name: "praxis",
            version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0",
            instructions: PraxisMCPTools.instructions,
            capabilities: .init(tools: .init(listChanged: false))
        )
        // `Server` is an actor; registration is isolated to it.
        _ = await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: PraxisMCPTools.catalogue)
        }
        _ = await server.withMethodHandler(CallTool.self) { parameters in
            await tools.call(parameters.name, arguments: parameters.arguments ?? [:])
        }

        let transport = StatelessHTTPServerTransport(
            validationPipeline: StandardValidationPipeline(validators: [
                StaticBearerTokenValidator(token: Self.token),
                OriginValidator.localhost(),
                AcceptHeaderValidator(mode: .jsonOnly),
                ContentTypeValidator(),
                ProtocolVersionValidator(),
            ])
        )

        do {
            try await server.start(transport: transport)
        } catch {
            lastError = "Serveur MCP : \(error.localizedDescription)"
            return
        }

        // Registered *after* `start`, which installs the SDK's own handler, so this one
        // replaces it. The SDK's rejects any second `initialize` for the life of the
        // `Server` — fine for a process that serves one client and exits, fatal for a
        // server that lives as long as the app: every restart of Claude Desktop (and every
        // second client, a Claude Code session next to Cowork) opens with `initialize` and
        // would be refused until Praxis itself relaunched. Verified with `mcp-remote`
        // against a harness. Praxis runs the server in non-strict mode, where nothing
        // depends on the initialized flag, so answering every handshake is safe.
        let serverInfo = Server.Info(name: "praxis", version: await server.version)
        let capabilities = await server.capabilities
        _ = await server.withMethodHandler(Initialize.self) { parameters in
            Initialize.Result(
                protocolVersion: parameters.protocolVersion,
                capabilities: capabilities,
                serverInfo: serverInfo,
                instructions: PraxisMCPTools.instructions
            )
        }

        let listener = LocalHTTPListener(port: Self.port) { [weak self] request in
            guard request.path?.hasPrefix("/mcp") == true else {
                return .error(statusCode: 404, .invalidRequest("Not found"))
            }
            let response = await transport.handleRequest(request)
            await MainActor.run { self?.requestCount += 1 }
            return response
        }
        do {
            try listener.start()
        } catch {
            await server.stop()
            lastError = "Port \(Self.port) indisponible : \(error.localizedDescription)"
            return
        }

        self.server = server
        self.transport = transport
        self.listener = listener
        isRunning = true
    }

    func stop() async {
        listener?.stop()
        listener = nil
        await server?.stop()
        server = nil
        transport = nil
        isRunning = false
    }

    func restart(taskStore: TaskStoreCoordinator) async {
        await stop()
        await start(taskStore: taskStore)
    }

    func regenerateToken() {
        UserDefaults.standard.removeObject(forKey: Self.tokenKey)
        _ = Self.token
    }
}

/// One static token, compared in constant time. The SDK's own `BearerTokenValidator` is
/// built around OAuth resource metadata and discovery, none of which applies to a single
/// local client holding a pre-shared key.
struct StaticBearerTokenValidator: HTTPRequestValidator {
    let token: String

    func validate(_ request: HTTPRequest, context: HTTPValidationContext) -> HTTPResponse? {
        let presented = request.headers["authorization"] ?? request.headers["Authorization"] ?? ""
        let expected = "Bearer \(token)"
        guard presented.utf8.count == expected.utf8.count,
              zip(presented.utf8, expected.utf8).reduce(0, { $0 | ($1.0 ^ $1.1) }) == 0 else {
            return .error(
                statusCode: 401,
                .invalidRequest("Unauthorized: missing or invalid bearer token"),
                extraHeaders: ["WWW-Authenticate": "Bearer realm=\"praxis\""]
            )
        }
        return nil
    }
}
