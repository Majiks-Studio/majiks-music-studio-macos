import Foundation

struct RPCRequest: Codable {
    let jsonrpc: String
    let id: String
    let method: String
    let params: JSONValue?

    init(id: String, method: String, params: JSONValue?) {
        self.jsonrpc = "2.0"
        self.id = id
        self.method = method
        self.params = params
    }
}

struct RPCErrorPayload: Codable {
    let code: Int
    let message: String
    let data: JSONValue?
}

struct RPCResponse: Codable {
    let jsonrpc: String
    let id: String?
    let result: JSONValue?
    let error: RPCErrorPayload?
}

// Progress notification from Codex's backend
struct ProgressNotification: Codable {
    let jsonrpc: String
    let method: String
    let params: GenerationProgress?
}

enum RPCClientError: Error, LocalizedError {
    case processNotRunning
    case timeout
    case serverError(RPCErrorPayload)
    case invalidResponse
    case pipeWriteFailure(Error)

    var errorDescription: String? {
        switch self {
        case .processNotRunning:
            return "Python backend is not running."
        case .timeout:
            return "Backend request timed out."
        case .serverError(let payload):
            var message = "Server error (\(payload.code)): \(payload.message)"
            if let data = payload.data?.objectValue {
                if let detail = data["detail"]?.stringValue, !detail.isEmpty {
                    message += "\nDetail: \(detail)"
                }
                if let fix = data["fix"]?.stringValue, !fix.isEmpty {
                    message += "\nSuggested fix: \(fix)"
                }
                if let step = data["step"]?.stringValue, !step.isEmpty {
                    message += "\nStep: \(step)"
                }
                if let code = data["code"]?.stringValue, !code.isEmpty {
                    message += "\nCode: \(code)"
                }
            }
            return message
        case .invalidResponse:
            return "Invalid response from backend."
        case .pipeWriteFailure(let error):
            return "Failed to write to backend pipe: \(error.localizedDescription)"
        }
    }
}
