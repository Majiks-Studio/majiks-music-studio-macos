import XCTest
@testable import MajiksMusicStudio

// Lane: Sterling model routing.
//
// The defect these hold shut: Sterling drives 148 MCP tools and 119 journalled
// commands and was running a 4B, because the v3.5 migration meant to promote it
// spent its one-shot flag on a no-op. Nothing about that failure was visible —
// no crash, no red, no wrong-looking setting. It presented as "the app is
// broken", which is why every assertion here is about a decision being SAID
// rather than about a value being present.
//
// Two rules this file obeys, both of them scars:
//
//   * Nothing below touches `UserDefaults.standard`. Every migration test runs
//     on a suite named for this test plus a UUID, and tears it down. A test
//     that reached the owner's real defaults could move his chat model.
//   * Nothing below re-implements the routing order. `SterlingRouter.route` is
//     called for real; a test that copied the if/else chain would still pass
//     with the shipping one deleted.

final class SterlingModelRoutingTests: XCTestCase {

    private let operatorModel = SterlingCapabilities.localOperatorModel
    private let fourB = SterlingCapabilities.legacyDefaultChatModel

    // MARK: - Capability

    func testTheFourBIsChatOnlyAndTheThirtyBOperatesTheApp() {
        XCTAssertEqual(SterlingCapabilities.capability(ofLocalModel: fourB), .chatOnly)
        XCTAssertEqual(SterlingCapabilities.capability(ofLocalModel: operatorModel), .operatesTheApp)
    }

    /// The allow-list is one element on purpose. If this fails because somebody
    /// widened it, the question to answer in the commit is "measured how?" — a
    /// deny-list would default every future model to capable, which is the
    /// silent-degradation direction this lane exists to close.
    func testTheOperatorAllowListIsAnAllowListNotADenyList() {
        XCTAssertEqual(SterlingCapabilities.operatorCapableLocalModels, [operatorModel])
        for model in LLMProvider.mlxLocal.models where model != operatorModel {
            XCTAssertEqual(
                SterlingCapabilities.capability(ofLocalModel: model), .chatOnly,
                "\(model) is not on the operator allow-list and must not claim to operate the app")
        }
    }

    func testTheMemoryAwareLocalDefaultKeepsTheOperatorModelAt24GB() {
        XCTAssertEqual(
            LLMProvider.defaultMLXModel(forPhysicalMemoryGB: 16),
            LLMProvider.lowMemoryMLXModel
        )
        XCTAssertEqual(
            LLMProvider.defaultMLXModel(forPhysicalMemoryGB: 24),
            operatorModel
        )
    }

    /// The label the user reads in the Setup Wizard, the model picker and the
    /// download list. It has to SAY the 4B cannot operate the app — "keep it
    /// selectable, but labelled" is the whole compromise that lets the 4B stay.
    func testTheLabelSaysTheFourBCannotOperateTheApp() {
        let fourBNote = SterlingCapabilities.note(for: fourB, provider: .mlxLocal)
        XCTAssertNotNil(fourBNote)
        XCTAssertTrue(fourBNote?.lowercased().contains("cannot operate") == true,
                      "the 4B's label must say so plainly, got \(fourBNote ?? "nil")")

        let operatorNote = SterlingCapabilities.note(for: operatorModel, provider: .mlxLocal)
        XCTAssertNotNil(operatorNote)
        XCTAssertFalse(operatorNote?.lowercased().contains("cannot") == true)
        XCTAssertNotEqual(fourBNote, operatorNote)
    }

    /// Silence, not a guess, for someone else's gateway: the app cannot know
    /// what an arbitrary endpoint serves and must not claim to.
    func testNoCapabilityClaimIsMadeAboutARemoteProvider() {
        for provider in LLMProvider.allCases where provider != .mlxLocal {
            XCTAssertNil(SterlingCapabilities.note(for: "anything", provider: provider),
                         "\(provider.rawValue) is remote; the app must not judge its models")
        }
        XCTAssertTrue(LLMProvider.allCases.allSatisfy {
            SterlingCapabilities.isRemote($0) == ($0 != .mlxLocal)
        })
    }

    // MARK: - The three routes

    func testAConfiguredCopilotEndpointWinsOverEverything() {
        let route = SterlingRouter.route(SterlingRoutingInputs(
            copilotEndpointConfigured: true,
            copilotModel: "qwen3-30b",
            chatProvider: .mlxLocal,
            chatModel: fourB,
            downloadedLocalModels: [operatorModel]
        ))
        XCTAssertEqual(route, .remote(model: "qwen3-30b", source: .copilotEndpoint))
        XCTAssertTrue(route.canOperateTheApp)
    }

    /// Order inside "remote" matters too: the dock's own endpoint is the only
    /// route the Studio copilot has, so it must win over a credentialed chat
    /// provider rather than the two racing on declaration order.
    func testTheCopilotEndpointBeatsACredentialedChatProvider() {
        let route = SterlingRouter.route(SterlingRoutingInputs(
            copilotEndpointConfigured: true,
            copilotModel: "qwen3-30b",
            chatProvider: .openrouter,
            chatModel: "anthropic/claude-3.5-haiku",
            chatProviderHasCredential: true))
        XCTAssertEqual(route, .remote(model: "qwen3-30b", source: .copilotEndpoint))
    }

    func testARemoteChatProviderWithACredentialIsARoute() {
        let route = SterlingRouter.route(SterlingRoutingInputs(
            chatProvider: .openrouter,
            chatModel: "anthropic/claude-3.5-haiku",
            chatProviderHasCredential: true
        ))
        XCTAssertEqual(route, .remote(model: "anthropic/claude-3.5-haiku",
                                      source: .chatProvider(.openrouter)))
    }

    /// A provider picked in a menu with no key behind it is a selection, not a
    /// route. Treating it as one is how a refusal turns into a runtime failure.
    func testARemoteProviderWithoutACredentialIsNotARoute() {
        let route = SterlingRouter.route(SterlingRoutingInputs(
            chatProvider: .openrouter,
            chatModel: "anthropic/claude-3.5-haiku",
            chatProviderHasCredential: false
        ))
        guard case .refused = route else {
            return XCTFail("a keyless provider must refuse, got \(route)")
        }
    }

    func testTheDownloadedThirtyBIsTheSecondChoice() {
        let route = SterlingRouter.route(SterlingRoutingInputs(
            chatProvider: .mlxLocal,
            chatModel: operatorModel,
            downloadedLocalModels: [operatorModel]
        ))
        XCTAssertEqual(route, .local(model: operatorModel))
    }

    /// Chat and operating the app are two jobs. Someone may keep the 4B for
    /// chat and still have the 30B on disk; routing uses the capable one for
    /// tools without touching their chat preference.
    func testTheThirtyBOnDiskRoutesEvenWhenTheFourBIsSelectedForChat() {
        let route = SterlingRouter.route(SterlingRoutingInputs(
            chatProvider: .mlxLocal,
            chatModel: fourB,
            downloadedLocalModels: [operatorModel, fourB]
        ))
        XCTAssertEqual(route, .local(model: operatorModel))
    }

    /// The whole point of the lane. Neither route present must NOT fall through
    /// to the 4B.
    func testNeitherRouteRefusesAndNeverFallsBackToTheFourB() {
        let route = SterlingRouter.route(SterlingRoutingInputs(
            chatProvider: .mlxLocal,
            chatModel: fourB,
            downloadedLocalModels: [fourB]
        ))
        guard case let .refused(refusal) = route else {
            return XCTFail("a chat-only model with no remote route must refuse, got \(route)")
        }
        XCTAssertFalse(route.canOperateTheApp)
        XCTAssertFalse(refusal.headline.isEmpty)
        XCTAssertTrue(refusal.detail.contains("Qwen3.5-4B-4bit"),
                      "the refusal must name the model it is refusing: \(refusal.detail)")
    }

    /// "Offer both routes" is the owner's decision, not a nicety: a refusal
    /// with one way out is a dead end for whichever half of the audience cannot
    /// take it (a base MacBook Air cannot host 20 GB of weights).
    func testARefusalAlwaysOffersBothRoutes() {
        guard case let .refused(refusal) = SterlingRouter.route(SterlingRoutingInputs()) else {
            return XCTFail("an unconfigured machine must refuse")
        }
        XCTAssertEqual(refusal.offers.count, 2)
        XCTAssertTrue(refusal.offers.contains(.connectARemoteEndpoint))
        XCTAssertTrue(refusal.offers.contains(.downloadTheLocalModel(
            id: operatorModel,
            approximateGigabytes: SterlingCapabilities.localOperatorModelApproximateGigabytes)))
        for offer in refusal.offers {
            XCTAssertFalse(offer.title.isEmpty)
            XCTAssertFalse(offer.detail.isEmpty)
        }
    }

    /// The size is the reason remote is the product default, so the number the
    /// user is shown must not be smaller than the download they get (~17.5 GB).
    func testTheAdvertisedDownloadSizeIsNotOptimistic() {
        XCTAssertGreaterThanOrEqual(SterlingCapabilities.localOperatorModelApproximateGigabytes, 17)
    }

    /// The 30B is never fetched by routing. Absent from disk it is an OFFER,
    /// and the refusal is what the user sees instead of a silent 17 GB pull.
    func testAnUndownloadedThirtyBIsAnOfferNotARoute() {
        let route = SterlingRouter.route(SterlingRoutingInputs(
            chatProvider: .mlxLocal,
            chatModel: operatorModel,
            downloadedLocalModels: []
        ))
        guard case let .refused(refusal) = route else {
            return XCTFail("a model that is not on disk is not a route, got \(route)")
        }
        XCTAssertTrue(refusal.offers.contains(.downloadTheLocalModel(
            id: operatorModel,
            approximateGigabytes: SterlingCapabilities.localOperatorModelApproximateGigabytes)))
    }

    // MARK: - The per-agent seam

    func testAnAgentWithToolsNeedsAnOperatorModelAndOneWithoutDoesNot() {
        let sterling = ChatAgent.builtIns.first(where: { $0.id == ChatAgent.majikAgentID })
        XCTAssertNotNil(sterling)
        XCTAssertTrue(sterling?.needsAnOperatorModel == true)

        var writer = ChatAgent.blankTemplate()
        writer.enabledToolIDs = []
        XCTAssertFalse(writer.needsAnOperatorModel)
        XCTAssertNil(writer.operatorRoute(SterlingRoutingInputs()),
                     "an agent with no tools is never refused, whatever the model is")
    }

    /// The seam is a property of the agent, not a check for Sterling's id.
    /// Switch Sterling's tools off and it stops being an operator; that is the
    /// answer a role system would want, and this is the hook it hangs from.
    func testTheSeamFollowsTheToolsNotTheIdentity() {
        var sterling = ChatAgent.builtIns.first(where: { $0.id == ChatAgent.majikAgentID })!
        sterling.enabledToolIDs = []
        XCTAssertFalse(sterling.needsAnOperatorModel)

        var custom = ChatAgent.blankTemplate()
        custom.enabledToolIDs = ["generate_music"]
        XCTAssertTrue(custom.needsAnOperatorModel)
        guard case .refused? = custom.operatorRoute(SterlingRoutingInputs()) else {
            return XCTFail("a tool-using custom agent on an unconfigured machine must refuse")
        }
    }

    // MARK: - Migrations: the pattern

    private func makeDefaults(_ function: String = #function) -> (UserDefaults, String) {
        let name = "SterlingModelRoutingTests-\(function)-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    /// THE regression. `majik_mlx_model` unset when the migration runs must NOT
    /// spend the flag — that is the exact line that cost Sterling its model.
    /// Restore the unconditional `set(true, forKey:)` and this fails by name.
    func testAMigrationThatCouldNotDecideDoesNotSpendItsFlag() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        let report = MajikChatModelMigrations.apply(MajikChatModelMigrationInputs(
            defaults: defaults,
            downloadedLocalModels: [],
            copilotEndpointConfigured: false))

        let outcome = report.outcomes[MajikChatModelMigrations.chatV350]
        XCTAssertEqual(outcome?.spendsTheFlag, false,
                       "an undecidable migration must defer, got \(String(describing: outcome))")
        XCTAssertFalse(defaults.bool(forKey: MajikChatModelMigrations.chatV350),
                       "the v3.5 flag was spent on a no-op — this is the shipped bug")
    }

    /// And having deferred, it must still work later. This is the half that a
    /// "just don't set the flag" fix could get wrong.
    func testADeferredMigrationStillRunsOnceItsInputsArrive() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        _ = MajikChatModelMigrations.apply(MajikChatModelMigrationInputs(
            defaults: defaults, downloadedLocalModels: [], copilotEndpointConfigured: false))

        // The Setup Wizard writes a choice, as it does on a real first run.
        defaults.set(fourB, forKey: MajikChatModelMigrations.chatModelKey)

        let second = MajikChatModelMigrations.apply(MajikChatModelMigrationInputs(
            defaults: defaults, downloadedLocalModels: [operatorModel],
            copilotEndpointConfigured: false))

        XCTAssertEqual(second.chatModel, operatorModel)
        XCTAssertEqual(defaults.string(forKey: MajikChatModelMigrations.chatModelKey), operatorModel)
        XCTAssertTrue(defaults.bool(forKey: MajikChatModelMigrations.chatV350))
    }

    func testAllThreeEarlierMigrationsDeferOnUnsetStateToo() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        let report = MajikChatModelMigrations.apply(MajikChatModelMigrationInputs(
            defaults: defaults, downloadedLocalModels: [], copilotEndpointConfigured: false))

        for flag in [MajikChatModelMigrations.chatV191,
                     MajikChatModelMigrations.chatV300,
                     MajikChatModelMigrations.chatV350] {
            XCTAssertEqual(report.outcomes[flag]?.spendsTheFlag, false,
                           "\(flag) spent its flag with nothing to read")
            XCTAssertFalse(defaults.bool(forKey: flag), "\(flag) was spent on a no-op")
        }
    }

    /// The half of the v3.5 defect that was never reported: even when it DID
    /// fire, it wrote a 17 GB model the machine might not have, and the cost
    /// landed as a surprise download on the user's next message. A promotion
    /// into a model that is not on disk defers; the routing card offers it.
    func testAPromotionNeverWritesAModelThatIsNotOnDisk() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        defaults.set(fourB, forKey: MajikChatModelMigrations.chatModelKey)
        let first = MajikChatModelMigrations.apply(MajikChatModelMigrationInputs(
            defaults: defaults, downloadedLocalModels: [fourB], copilotEndpointConfigured: false))

        XCTAssertEqual(first.outcomes[MajikChatModelMigrations.chatV350]?.spendsTheFlag, false)
        XCTAssertNil(first.chatModel)
        XCTAssertEqual(defaults.string(forKey: MajikChatModelMigrations.chatModelKey), fourB,
                       "the chat model must not point at 17 GB that is not there")

        // And it lands the moment the download does.
        let second = MajikChatModelMigrations.apply(MajikChatModelMigrationInputs(
            defaults: defaults, downloadedLocalModels: [fourB, operatorModel],
            copilotEndpointConfigured: false))
        XCTAssertEqual(second.chatModel, operatorModel)
    }

    /// A deliberate choice is not a migration target, and a spent flag stays
    /// spent. Both halves of "one-shot" have to hold or the pattern is worse
    /// than what it replaced.
    func testADeliberateChoiceIsNotApplicableAndTheFlagIsSpent() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        defaults.set("mlx-community/GLM-4.7-Flash-4bit", forKey: MajikChatModelMigrations.chatModelKey)
        let report = MajikChatModelMigrations.apply(MajikChatModelMigrationInputs(
            defaults: defaults, downloadedLocalModels: [operatorModel], copilotEndpointConfigured: false))

        XCTAssertEqual(report.outcomes[MajikChatModelMigrations.chatV350]?.spendsTheFlag, true)
        XCTAssertNil(report.chatModel)
        XCTAssertEqual(defaults.string(forKey: MajikChatModelMigrations.chatModelKey),
                       "mlx-community/GLM-4.7-Flash-4bit")
    }

    func testMigrationsAreIdempotentAcrossRelaunches() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        defaults.set(fourB, forKey: MajikChatModelMigrations.chatModelKey)
        let first = MajikChatModelMigrations.apply(MajikChatModelMigrationInputs(
            defaults: defaults, downloadedLocalModels: [operatorModel], copilotEndpointConfigured: false))
        XCTAssertEqual(first.chatModel, operatorModel)

        // A second launch must be a no-op, not a second promotion.
        defaults.set(fourB, forKey: MajikChatModelMigrations.chatModelKey)
        let second = MajikChatModelMigrations.apply(MajikChatModelMigrationInputs(
            defaults: defaults, downloadedLocalModels: [operatorModel], copilotEndpointConfigured: false))
        XCTAssertTrue(second.outcomes.isEmpty, "spent flags must not re-run")
        XCTAssertEqual(defaults.string(forKey: MajikChatModelMigrations.chatModelKey), fourB)
    }

    // MARK: - Migrations: the owner's machine

    /// The measured state: `majik_chat_model_v350_migrated = 1` and
    /// `majik_mlx_model` still the 4B. The repair has to reach it without him
    /// editing defaults by hand.
    private func ownersMachine(_ defaults: UserDefaults) {
        defaults.set(true, forKey: MajikChatModelMigrations.extractionV136)
        defaults.set(true, forKey: MajikChatModelMigrations.chatV191)
        defaults.set(true, forKey: MajikChatModelMigrations.chatV300)
        defaults.set(true, forKey: MajikChatModelMigrations.chatV350)
        defaults.set(fourB, forKey: MajikChatModelMigrations.chatModelKey)
    }

    func testAnAlreadySpentV350RecoversOnceTheThirtyBIsOnDisk() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        ownersMachine(defaults)

        let report = MajikChatModelMigrations.apply(MajikChatModelMigrationInputs(
            defaults: defaults,
            downloadedLocalModels: [operatorModel, fourB],
            copilotEndpointConfigured: false))

        XCTAssertNil(report.outcomes[MajikChatModelMigrations.chatV350],
                     "the v3.5 flag is spent; recovery must come from its own flag")
        XCTAssertEqual(report.chatModel, operatorModel)
        XCTAssertEqual(defaults.string(forKey: MajikChatModelMigrations.chatModelKey), operatorModel)
    }

    /// Until the 30B is there, the repair DEFERS rather than either giving up
    /// or fetching 17 GB uninvited — so the moment he downloads it, the next
    /// launch converges with no further action.
    func testTheRepairDefersRatherThanAutoDownloadingSeventeenGigabytes() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        ownersMachine(defaults)

        let first = MajikChatModelMigrations.apply(MajikChatModelMigrationInputs(
            defaults: defaults, downloadedLocalModels: [fourB], copilotEndpointConfigured: false))
        XCTAssertEqual(first.outcomes[MajikChatModelMigrations.operatorCapabilityRepair]?.spendsTheFlag, false)
        XCTAssertNil(first.chatModel)
        XCTAssertEqual(defaults.string(forKey: MajikChatModelMigrations.chatModelKey), fourB)

        let second = MajikChatModelMigrations.apply(MajikChatModelMigrationInputs(
            defaults: defaults,
            downloadedLocalModels: [fourB, operatorModel],
            copilotEndpointConfigured: false))
        XCTAssertEqual(second.chatModel, operatorModel)
    }

    /// "on the 30B OR on remote". With Sterling pointed at an endpoint, the
    /// local pick is a chat preference and the repair leaves it alone.
    func testAConfiguredEndpointSatisfiesTheRepairWithoutTouchingTheChatModel() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        ownersMachine(defaults)

        let report = MajikChatModelMigrations.apply(MajikChatModelMigrationInputs(
            defaults: defaults, downloadedLocalModels: [fourB], copilotEndpointConfigured: true))

        XCTAssertEqual(report.outcomes[MajikChatModelMigrations.operatorCapabilityRepair]?.spendsTheFlag, true)
        XCTAssertNil(report.chatModel)
        XCTAssertEqual(defaults.string(forKey: MajikChatModelMigrations.chatModelKey), fourB)

        // And routing then says so out loud rather than implying the 4B drives it.
        let route = SterlingRouter.route(SterlingRoutingInputs(
            copilotEndpointConfigured: true,
            copilotModel: "qwen3-30b",
            chatProvider: .mlxLocal,
            chatModel: fourB))
        XCTAssertTrue(route.canOperateTheApp)
    }

    /// The extraction model is a separate, lighter job and is NOT changed by
    /// any of this. Moving it would break parameter extraction app-wide.
    func testExtractionStaysOnTheFourB() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(fourB, forKey: MajikChatModelMigrations.chatModelKey)

        let report = MajikChatModelMigrations.apply(MajikChatModelMigrationInputs(
            defaults: defaults, downloadedLocalModels: [operatorModel], copilotEndpointConfigured: false))

        XCTAssertEqual(report.extractionModel, fourB)
        XCTAssertEqual(defaults.string(forKey: MajikChatModelMigrations.extractionModelKey), fourB)
        XCTAssertEqual(report.chatModel, operatorModel, "chat moves, extraction does not")
    }
}
