import Foundation
import Combine

/// Shared @MainActor holder for the engine instance. The tab surface reads
/// ``currentSnapshot`` from one engine reference without each view owning its
/// own engine variable — the hub is the single source of truth for the session
/// engine throughout the settings / inspector surface. Created lazily so that
/// importing the module never forces engine initialization.
@MainActor
final class StudioEngineHub: ObservableObject {
    static let shared = StudioEngineHub()

    @Published var engine: (any StudioEngineProtocol)?

    private init() {}

    /// Convenience: the current project snapshot from whichever engine is
    /// attached, or nil if no engine is set.
    var currentSnapshot: StudioProjectSnapshot? {
        get async {
            await engine?.snapshot(ifNewerThan: nil)
        }
    }
}
