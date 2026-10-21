import Testing
import Foundation
@testable import MajiksMusicStudio

// The app shipped TWO built-in agents both presenting as "The Engineer":
// Sterling (the creative partner — lyrics, arrangement, generation, the whole
// Studio command surface) and the technical specialist (BPM/key detection,
// mixing advice, parameter extraction). Sterling is now "The Producer"; the
// technical agent KEEPS the name "The Engineer".
//
// These tests are written to fail on the COLLISION, not on the presence of a
// happy string. A test that only checks `"The Producer"` appears somewhere
// cannot see a second surface that still says "The Engineer", and cannot see
// the opposite mistake — someone "resolving" the clash by renaming the
// technical agent instead. Both directions are asserted below.
@Suite("Agent naming — no two agents present as The Engineer")
struct AgentNamingTests {

    /// The name the technical specialist must keep.
    private static let engineerLabel = "The Engineer"
    /// The role Sterling must present.
    private static let producerLabel = "The Producer"

    /// Every string a user reads as an agent's identity in Settings ▸ Agents,
    /// the chat empty state, and the copilot dock: the name, plus the leading
    /// role phrase of the subtitle ("The Producer — your AI music production…").
    private func presentedLabels(_ agent: ChatAgent) -> [String] {
        var labels = [agent.name.trimmingCharacters(in: .whitespaces)]
        let summary = agent.summary.trimmingCharacters(in: .whitespaces)
        if let head = summary.split(separator: "—", maxSplits: 1).first {
            let role = head.trimmingCharacters(in: .whitespaces)
            if !role.isEmpty, role != summary {
                labels.append(role)
            }
        }
        return labels
    }

    @Test("built-in agents never present the same role label twice")
    func builtInRoleLabelsAreUnique() {
        var owner: [String: String] = [:]
        var collisions: [String] = []
        for agent in ChatAgent.builtIns {
            for label in presentedLabels(agent) {
                if let existing = owner[label] {
                    collisions.append("\"\(label)\" is presented by both \(existing) and \(agent.name)")
                }
                owner[label] = agent.name
            }
        }
        #expect(collisions.isEmpty, "\(collisions)")
        // Guard the guard: if the label extraction ever silently returns
        // nothing, the uniqueness check above passes vacuously.
        #expect(owner.count >= ChatAgent.builtIns.count * 2 - 1)
    }

    @Test("exactly one built-in agent is The Engineer, and it is the technical one")
    func onlyTheTechnicalAgentIsTheEngineer() {
        let claimants = ChatAgent.builtIns.filter { agent in
            presentedLabels(agent).contains(Self.engineerLabel)
        }
        #expect(claimants.count == 1)
        #expect(claimants.first?.id == ChatAgent.engineerAgentID)
    }

    @Test("Sterling presents as The Producer and nowhere as The Engineer")
    func sterlingIsTheProducer() {
        let sterling = ChatAgent.builtIns.first { $0.id == ChatAgent.majikAgentID }
        #expect(sterling != nil)
        guard let sterling else { return }

        #expect(sterling.name == "Sterling")
        #expect(presentedLabels(sterling).contains(Self.producerLabel))
        // Absence, not presence: no user-facing string on Sterling may carry
        // the other agent's name.
        #expect(!sterling.name.contains(Self.engineerLabel))
        #expect(!sterling.summary.contains(Self.engineerLabel))
        #expect(!sterling.systemPrompt.contains(Self.engineerLabel))
        #expect(!sterling.customInstructions.contains(Self.engineerLabel))
    }

    @Test("the technical agent keeps its name and its job")
    func technicalAgentUnchanged() {
        let engineer = ChatAgent.builtIns.first { $0.id == ChatAgent.engineerAgentID }
        #expect(engineer != nil)
        guard let engineer else { return }

        #expect(engineer.name == Self.engineerLabel)
        // Its own prompt must still introduce it as The Engineer — a blind
        // find-and-replace of "The Engineer" would strip this and reattribute
        // BPM/key/mix analysis to the producer.
        #expect(engineer.systemPrompt.contains("You are The Engineer"))
        #expect(!engineer.name.contains(Self.producerLabel))
        #expect(!engineer.summary.contains(Self.producerLabel))
    }

    @Test("the Studio copilot persona presents Sterling as The Producer")
    func copilotPersonaRole() {
        #expect(SterlingPersona.name == "Sterling")
        #expect(SterlingPersona.role == Self.producerLabel)
        #expect(SterlingPersona.role != Self.engineerLabel)
        // The dock header and the Studio tab label both read this value, so a
        // regression here re-creates the collision on two screens at once.
        #expect(!SterlingPersona.greeting.contains(Self.engineerLabel))
    }

    @Test("no Sterling system prompt introduces the agent as The Engineer")
    @MainActor
    func sterlingSystemPromptsDoNotClaimEngineer() {
        let prompts = LLMProviderSettings.defaultSystemPrompts
        // Enumerating the real table (not a hardcoded list of model IDs) means
        // a prompt added later is covered without editing this test.
        #expect(!prompts.isEmpty)
        for (model, prompt) in prompts {
            #expect(
                !prompt.contains(Self.engineerLabel),
                "Sterling's system prompt for \(model) still introduces it as The Engineer"
            )
        }
        // At least one prompt must actually name Sterling as the producer, or
        // the absence check above could pass on prompts that say nothing.
        #expect(prompts.values.contains { $0.contains("You are Sterling, \(Self.producerLabel)") })
    }

    @Test("the extraction prompt still belongs to The Engineer")
    @MainActor
    func extractionPromptKeepsEngineer() {
        // The other half of the blind-replace guard: the technical agent's
        // extraction prompt must keep its identity.
        #expect(LLMProviderSettings.defaultEngineerPrompt.contains("\"The Engineer\""))
        #expect(!LLMProviderSettings.defaultEngineerPrompt.contains(Self.producerLabel))
    }
}

@Suite("Agent naming — persisted identifiers and migration")
@MainActor
struct AgentNamingPersistenceTests {

    @Test("agent IDs and persisted keys are untouched by the rename")
    func identifiersAreStable() {
        // A display-name change must not orphan a user's settings. These are
        // the identifiers a rename would be tempted to touch.
        #expect(ChatAgent.majikAgentID.uuidString == "7C701E35-39C2-4A03-84E7-E7A8D8F3B201")
        #expect(ChatAgent.engineerAgentID.uuidString == "5927DAA4-0808-4922-BC1D-A588FA8A4A03")
        // The extraction prompt target's raw value is a UserDefaults-facing
        // token, not a label.
        #expect(LLMSettingsView.PromptTarget.engineerModel.rawValue == "engineer")
        #expect(LLMSettingsView.PromptTarget.chatModel.rawValue == "chat")
    }

    @Test("a stored Sterling carrying the old subtitle migrates to The Producer")
    func legacySubtitleMigrates() {
        let store = AgentStore()
        let stale = ChatAgent(
            id: ChatAgent.majikAgentID,
            name: "Sterling",
            iconSystemName: "gearshape.2",
            summary: "The Engineer — your AI music production partner: lyrics, arrangement, generation, and everything creative",
            accentColorHex: "#2563EB",
            isBuiltIn: true
        )

        let normalized = store.normalize([stale])
        let sterling = normalized.first { $0.id == ChatAgent.majikAgentID }

        #expect(sterling != nil)
        #expect(sterling?.summary.contains("The Producer") == true)
        #expect(sterling?.summary.contains("The Engineer") == false)
    }

    @Test("a user-edited subtitle is not overwritten by the migration")
    func userEditedSubtitleSurvives() {
        let store = AgentStore()
        let custom = ChatAgent(
            id: ChatAgent.majikAgentID,
            name: "Sterling",
            iconSystemName: "gearshape.2",
            summary: "My own description",
            accentColorHex: "#2563EB",
            isBuiltIn: true
        )

        let normalized = store.normalize([custom])
        #expect(normalized.first { $0.id == ChatAgent.majikAgentID }?.summary == "My own description")
    }

    @Test("the pre-Sterling Majik identity still migrates forward")
    func majikIdentityStillMigrates() {
        let store = AgentStore()
        let ancient = ChatAgent(
            id: ChatAgent.majikAgentID,
            name: "Majik",
            iconSystemName: "music.note",
            summary: "Your AI music production assistant — lyrics, arrangement, generation, and everything creative",
            accentColorHex: "#2563EB",
            isBuiltIn: true
        )

        let normalized = store.normalize([ancient])
        let sterling = normalized.first { $0.id == ChatAgent.majikAgentID }

        #expect(sterling?.name == "Sterling")
        #expect(sterling?.summary.contains("The Producer") == true)
    }
}
