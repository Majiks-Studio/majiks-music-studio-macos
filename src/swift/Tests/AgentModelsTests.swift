import Testing
import Foundation
@testable import MajiksMusicStudio

@Suite("ChatAgent")
struct ChatAgentTests {

    @Test("built-in agents are present with stable identities")
    func builtInAgentsExist() {
        let ids = Set(ChatAgent.builtIns.map(\.id))

        #expect(ids.contains(ChatAgent.majikAgentID))
        #expect(ids.contains(ChatAgent.engineerAgentID))
        #expect(ChatAgent.builtIns.count == 2)
    }

    @Test("Majik uses app defaults by default")
    func majikUsesAppDefaults() {
        let majik = ChatAgent.builtIns.first(where: { $0.id == ChatAgent.majikAgentID })

        #expect(majik != nil)
        #expect(majik?.usesAppDefaults == true)
        #expect(majik?.provider == nil)
        #expect(majik?.modelID == "")
    }

    @Test("blank template starts as editable custom agent")
    func blankTemplate() {
        let draft = ChatAgent.blankTemplate()

        #expect(!draft.isBuiltIn)
        #expect(draft.name == "New Agent")
        #expect(draft.temperature == 0.7)
        #expect(draft.topP == 0.9)
        #expect(draft.maxTokens == 1200)
    }

    @Test("duplicate copy becomes editable custom agent")
    func duplicateCopy() {
        let agent = ChatAgent(
            name: "Pinned",
            iconSystemName: "sparkles",
            summary: "Pinned model",
            accentColorHex: "#2563EB",
            provider: .openai,
            modelID: "gpt-4o",
            temperature: 0.4,
            topP: 0.8,
            maxTokens: 900,
            enabledToolIDs: ["generate_music"]
        )
        let duplicated = agent.copyForDuplicate()

        #expect(duplicated.id != agent.id)
        #expect(duplicated.name == "Pinned Copy")
        #expect(duplicated.isBuiltIn == false)
        #expect(duplicated.provider == .openai)
        #expect(duplicated.modelID == "gpt-4o")
    }
}

@Suite("ConversationMigration")
struct ConversationMigrationTests {

    @Test("conversation decoding defaults missing agent ID to Majik")
    func conversationDecodeDefaultsAgent() throws {
        let json = """
        {
            "id": "0E7A8D28-3E7E-4E0C-9B35-BC211AF16D19",
            "title": "Old Conversation",
            "messages": [],
            "createdAt": "2026-03-28T00:00:00Z",
            "updatedAt": "2026-03-28T00:00:00Z"
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(Conversation.self, from: Data(json.utf8))

        #expect(decoded.agentID == ChatAgent.majikAgentID)
    }

    @Test("chat message decoding defaults missing speaker agent to nil")
    func messageDecodeDefaultsSpeaker() throws {
        let json = """
        {
            "id": "0E7A8D28-3E7E-4E0C-9B35-BC211AF16D20",
            "role": "assistant",
            "content": "Hello",
            "timestamp": "2026-03-28T00:00:00Z"
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ChatMessage.self, from: Data(json.utf8))

        #expect(decoded.speakerAgentID == nil)
        #expect(decoded.isFromAssistant)
    }
}
