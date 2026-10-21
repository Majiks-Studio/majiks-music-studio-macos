import Foundation

// MARK: - The pattern
//
// Four one-shot defaults migrations in this app were written the same way:
//
//     if !defaults.bool(forKey: flag) {
//         if stored == someExactOldValue { ...move it... }
//         defaults.set(true, forKey: flag)          // UNCONDITIONAL
//     }
//
// The v3.5 one was supposed to promote Sterling's chat model from the 4B to the
// 30B MoE. On a machine where `majik_mlx_model` was not yet written — a first
// run, before the Setup Wizard had stored a choice — the `if` did nothing and
// the flag was spent anyway. The wizard then wrote a model in behind it, and
// the promotion could never run again. Measured on the owner's machine:
// `majik_chat_model_v350_migrated = 1`, `majik_mlx_model` still the 4B.
//
// v1.3.6, v1.9.1 and v3.0 have the identical shape, so this is a pattern bug,
// not an incident. The rule from here on:
//
//     A one-shot flag may only be spent once the migration REACHED A DECISION.
//     "I cannot tell yet" is `.deferred`, and costs one dictionary read on the
//     next launch instead of the feature forever.
//
// `.deferred` is what makes the difference visible in a test: a migration that
// no-ops on unset state now says so by name instead of looking like success.

enum MajikMigrationOutcome: Equatable {
    /// The migration ran and the destination state is now true. Spend the flag.
    case converged(String)
    /// This install was never in the "from" state, so there is nothing to do
    /// and there never will be. Spend the flag.
    case notApplicable(String)
    /// The inputs the migration needs are not available yet. Keep the flag
    /// UNSPENT and try again on the next launch.
    case deferred(String)

    var reason: String {
        switch self {
        case let .converged(reason), let .notApplicable(reason), let .deferred(reason):
            return reason
        }
    }

    var spendsTheFlag: Bool {
        if case .deferred = self { return false }
        return true
    }
}

enum MajikMigration {
    /// Run `body` unless `flag` is already set, and set `flag` only if the
    /// outcome earned it. Returns `nil` when the migration had already run.
    @discardableResult
    static func runOnce(
        _ flag: String,
        in defaults: UserDefaults,
        _ body: () -> MajikMigrationOutcome
    ) -> MajikMigrationOutcome? {
        guard !defaults.bool(forKey: flag) else { return nil }
        let outcome = body()
        if outcome.spendsTheFlag {
            defaults.set(true, forKey: flag)
        }
        return outcome
    }
}

// MARK: - The chat-model migrations
//
// Extracted out of `LLMProviderSettings.load()` so they can be driven against a
// throwaway UserDefaults suite. Nothing in here reads `UserDefaults.standard`,
// the file system, or the network; `load()` supplies the real ones.

struct MajikChatModelMigrationInputs {
    var defaults: UserDefaults
    /// Local model ids already present on disk. Used only to decide whether the
    /// operator model is a route or an offer — this never triggers a download.
    var downloadedLocalModels: Set<String>
    /// `SterlingConfig.isConfigured`. When Sterling already has a remote
    /// endpoint, that IS the operator route and the local chat pick is just a
    /// chat preference, so the recovery below leaves it alone.
    var copilotEndpointConfigured: Bool
}

struct MajikChatModelMigrationReport: Equatable {
    /// Outcome per flag, for the log and for tests to name.
    var outcomes: [String: MajikMigrationOutcome] = [:]
    /// The chat model after migration, when a migration changed it.
    var chatModel: String?
    /// The extraction model after migration, when a migration changed it.
    var extractionModel: String?
}

enum MajikChatModelMigrations {
    static let extractionV136 = "majik_extraction_model_v136_migrated"
    static let chatV191 = "majik_chat_model_v191_migrated"
    static let chatV300 = "majik_chat_model_v300_migrated"
    static let chatV350 = "majik_chat_model_v350_migrated"
    /// The repair. New flag, because the v3.5 flag is already spent on the
    /// machines this has to reach.
    static let operatorCapabilityRepair = "majik_chat_model_operator_capability_v362_repaired"

    static let chatModelKey = "majik_mlx_model"
    static let extractionModelKey = "majik_extraction_model"

    static let extractionModel = SterlingCapabilities.legacyDefaultChatModel
    static let operatorModel = SterlingCapabilities.localOperatorModel

    private static let llama32 = "mlx-community/Llama-3.2-3B-Instruct-4bit"
    private static let graniteMicro = "mlx-community/granite-4.0-h-micro-4bit"

    static func apply(_ inputs: MajikChatModelMigrationInputs) -> MajikChatModelMigrationReport {
        let defaults = inputs.defaults
        var report = MajikChatModelMigrationReport()

        func storedChatModel() -> String {
            (defaults.string(forKey: chatModelKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        func record(_ flag: String, _ outcome: MajikMigrationOutcome?) {
            guard let outcome else { return }
            report.outcomes[flag] = outcome
        }

        /// The shape all three "old default -> new default" migrations share.
        /// Two lines here used to be wrong, and only one of them was reported:
        ///
        ///   * `stored.isEmpty` spent the flag on a no-op (the known defect);
        ///   * nothing checked whether the DESTINATION was on disk. Promoting a
        ///     user onto the 30B they have not downloaded does not fail — it
        ///     silently costs them a 17 GB fetch on their next message, which
        ///     is the one thing this lane was told not to do. So a promotion
        ///     into a model that must be downloaded DEFERS until it is there,
        ///     and the routing card offers the download meanwhile.
        func promote(from old: String, to new: String) -> MajikMigrationOutcome {
            let stored = storedChatModel()
            if stored.isEmpty {
                return .deferred("no chat model stored yet; the Setup Wizard has not written one")
            }
            guard stored == old else {
                return .notApplicable("chat model is \(stored), not the \(SterlingRouter.shortName(old)) this migration moves")
            }
            if new == operatorModel, !inputs.downloadedLocalModels.contains(operatorModel) {
                return .deferred("\(SterlingRouter.shortName(new)) is not downloaded; offering it beats fetching 17 GB uninvited")
            }
            defaults.set(new, forKey: chatModelKey)
            report.chatModel = new
            return .converged("chat model \(SterlingRouter.shortName(old)) -> \(SterlingRouter.shortName(new))")
        }

        // v1.3.6+: extraction gets its own dedicated model. This one writes
        // unconditionally and so always converges; it is routed through the
        // helper only so all four read the same and none can drift back.
        record(extractionV136, MajikMigration.runOnce(extractionV136, in: defaults) {
            defaults.set(extractionModel, forKey: extractionModelKey)
            report.extractionModel = extractionModel
            return .converged("extraction model pinned to \(SterlingRouter.shortName(extractionModel))")
        })

        // v1.9.1: Llama 3.2 3B -> Qwen 3.5 4B (one download for chat + extraction).
        record(chatV191, MajikMigration.runOnce(chatV191, in: defaults) {
            promote(from: llama32, to: SterlingCapabilities.legacyDefaultChatModel)
        })

        // v3.0: Granite 4.0 H-Micro -> Qwen 3.5 4B.
        record(chatV300, MajikMigration.runOnce(chatV300, in: defaults) {
            promote(from: graniteMicro, to: SterlingCapabilities.legacyDefaultChatModel)
        })

        // v3.5: Qwen 3.5 4B -> Qwen3 30B A3B. The one that lost its flag.
        record(chatV350, MajikMigration.runOnce(chatV350, in: defaults) {
            promote(from: SterlingCapabilities.legacyDefaultChatModel, to: operatorModel)
        })

        // The recovery. v3.5's flag is spent on every machine that shipped with
        // it, including the owner's, so the promotion needs a second, differently
        // keyed chance — one that also refuses to do the two things the first
        // one would have done wrong:
        //
        //   * it does NOT fetch 17 GB on the app's own initiative, so when the
        //     30B is absent it DEFERS and the UI offers the download instead;
        //   * it does NOT overwrite a deliberate choice: only the exact model
        //     v3.5 was supposed to move is moved, and only once.
        record(operatorCapabilityRepair, MajikMigration.runOnce(operatorCapabilityRepair, in: defaults) {
            let stored = storedChatModel()
            if stored.isEmpty {
                return .deferred("no chat model stored yet; the Setup Wizard has not written one")
            }
            if SterlingCapabilities.capability(ofLocalModel: stored) == .operatesTheApp {
                return .notApplicable("\(SterlingRouter.shortName(stored)) already operates the app")
            }
            if inputs.copilotEndpointConfigured {
                return .notApplicable("Sterling runs on the configured endpoint; the local pick is a chat preference")
            }
            guard stored == SterlingCapabilities.legacyDefaultChatModel else {
                return .notApplicable("chat model \(SterlingRouter.shortName(stored)) was chosen deliberately")
            }
            guard inputs.downloadedLocalModels.contains(operatorModel) else {
                return .deferred("\(SterlingRouter.shortName(operatorModel)) is not downloaded; offering it beats fetching 17 GB uninvited")
            }
            defaults.set(operatorModel, forKey: chatModelKey)
            report.chatModel = operatorModel
            return .converged("recovered the v3.5 promotion: \(SterlingRouter.shortName(operatorModel))")
        })

        return report
    }
}
