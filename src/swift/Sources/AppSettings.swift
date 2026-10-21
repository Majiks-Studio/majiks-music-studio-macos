import Foundation

@MainActor
final class AppSettings: ObservableObject {
    @Published var openRouterKey: String = ""
    @Published var openRouterModel: String = "qwen/qwen3-30b-a3b"

    private let service = "com.majik.musicstudio"
    private let keyAccount = "openrouter_api_key"
    private let modelAccount = "openrouter_model"

    func load() {
        do {
            if let stored = try KeychainStore.get(account: keyAccount, service: service) {
                openRouterKey = stored
            }
            if let storedModel = try KeychainStore.get(account: modelAccount, service: service) {
                openRouterModel = storedModel
            }
        } catch {
            // Ignore keychain errors for now.
        }
    }

    func save() {
        do {
            try KeychainStore.set(openRouterKey, account: keyAccount, service: service)
            try KeychainStore.set(openRouterModel, account: modelAccount, service: service)
        } catch {
            // Ignore keychain errors for now.
        }
    }
}
