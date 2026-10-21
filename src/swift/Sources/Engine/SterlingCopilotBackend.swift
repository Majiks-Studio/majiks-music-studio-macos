import Foundation

// FfiCopilotBackend - the real Sterling backend, over the generated FFI. Lives
// in Sources/Engine/ so it is compiled only in the packaged app (this whole
// directory links MajiksEngine.xcframework and is excluded from the mock build,
// which uses DisabledCopilotBackend instead).
//
// It wraps the SAME EngineClient the Studio tab runs on (RealStudioEngine.
// copilotClient), so Sterling's commands land on the same host the UI shows.
// Config (endpoint + model) comes from SterlingConfig; the key comes from the
// Keychain and is passed only as the request authorization, never persisted in
// the engine and scrubbed from every event.

final class FfiCopilotBackend: StudioCopilotBackend, @unchecked Sendable {
    private let client: EngineClient

    init(client: EngineClient) {
        self.client = client
    }

    var isAvailable: Bool { true }

    func send(_ request: StudioCopilotSendRequest) throws -> UInt64 {
        guard case .local = request.route else {
            throw NSError(
                domain: "Sterling",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "Brigade turns do not run on the local Studio command bus."]
            )
        }
        return try client.copilotSend(
            text: request.text,
            endpoint: SterlingConfig.endpoint,
            model: SterlingConfig.model,
            apiKey: SterlingKeychain.key(),
            systemPromptOverride: request.systemPromptOverride
        )
    }

    func poll(_ turnId: UInt64) throws -> String {
        try client.copilotPoll(turnId: turnId)
    }

    func cancel(_ turnId: UInt64) throws {
        try client.copilotCancel(turnId: turnId)
    }

    func clearHistory() throws {
        try client.copilotClearHistory()
    }

    func undo() throws -> Bool {
        try client.undo()
    }
}

final class RoutedCopilotBackend: StudioCopilotBackend {
    private let local: FfiCopilotBackend
    private let brigade = BrigadeCopilotBackend()

    init(local: FfiCopilotBackend) {
        self.local = local
    }

    var isAvailable: Bool { local.isAvailable }

    func send(_ request: StudioCopilotSendRequest) throws -> UInt64 {
        switch request.route {
        case .local:
            return try local.send(request)
        case .brigade:
            return try brigade.send(request)
        }
    }

    func poll(_ turnId: UInt64) throws -> String {
        if let value = try brigade.pollIfKnown(turnId) {
            return value
        }
        return try local.poll(turnId)
    }

    func cancel(_ turnId: UInt64) throws {
        if try brigade.cancelIfKnown(turnId) { return }
        try local.cancel(turnId)
    }

    func clearHistory() throws {
        try local.clearHistory()
        try brigade.clearHistory()
    }

    func undo() throws -> Bool {
        try local.undo()
    }
}
