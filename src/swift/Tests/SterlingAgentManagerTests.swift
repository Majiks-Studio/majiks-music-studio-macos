import Testing
import Foundation
@testable import MajiksMusicStudio

// Contract locks for the swappable agent + model layer (Lane 1). Both functions
// under test are pure: the FREE badge is what a person spends money against, and
// the persona preamble is the whole of the FFI-free persona swap.

@MainActor
@Suite("SterlingModelCatalog")
struct SterlingModelCatalogTests {

    private func parse(_ json: String) -> [SterlingGatewayModel] {
        SterlingModelCatalog.parse(Data(json.utf8))
    }

    @Test("a :free slug is FREE regardless of pricing")
    func freeSlug() {
        let models = parse(#"{"data":[{"id":"qwen/qwen3.6-flash:free"}]}"#)
        #expect(models.count == 1)
        #expect(models[0].isFree)
        #expect(models[0].priceLabel == "FREE")
    }

    @Test("both prices explicitly zero is FREE")
    func zeroPriced() {
        let models = parse(#"{"data":[{"id":"uc/chat-default","pricing":{"input":0,"output":0}}]}"#)
        #expect(models[0].isFree)
    }

    @Test("a real price is NOT free and renders honestly")
    func pricedModel() {
        let models = parse(#"{"data":[{"id":"qwen3.6-35b","display_name":"Qwen 35B","pricing":{"input":0.6,"output":0.9}}]}"#)
        #expect(models[0].isFree == false)
        #expect(models[0].displayName == "Qwen 35B")
        #expect(models[0].priceLabel == "$0.60 in / $0.90 out /1M")
    }

    @Test("missing pricing is unknown cost, NOT free")
    func unknownCost() {
        let models = parse(#"{"data":[{"id":"mystery-model"}]}"#)
        #expect(models[0].isFree == false)
        #expect(models[0].priceLabel == nil)
    }

    @Test("sub-cent price keeps four decimals so it never reads $0.00")
    func subCentPrice() {
        let models = parse(#"{"data":[{"id":"cheap","pricing":{"input":0.002,"output":0.004}}]}"#)
        #expect(models[0].priceLabel == "$0.0020 in / $0.0040 out /1M")
    }

    @Test("free models sort ahead of paid ones")
    func freeFirst() {
        let models = parse(#"{"data":[{"id":"z-paid","pricing":{"input":1,"output":1}},{"id":"a-free:free"}]}"#)
        #expect(models.first?.isFree == true)
    }

    @Test("a bare array (no data envelope) also parses")
    func bareArray() {
        let models = parse(#"[{"id":"only-model"}]"#)
        #expect(models.count == 1)
        #expect(models[0].id == "only-model")
    }

    @Test("rows without an id are skipped")
    func skipsIdless() {
        let models = parse(#"{"data":[{"name":"no id here"},{"id":"good"}]}"#)
        #expect(models.count == 1)
        #expect(models[0].id == "good")
    }
}

@Suite("SterlingAgentBridge")
struct SterlingAgentBridgeTests {

    private func customAgent(name: String = "Bassline Bot", prompt: String = "You obsess over deep sub-bass.") -> ChatAgent {
        ChatAgent(
            name: name,
            iconSystemName: "music.note",
            summary: "custom",
            accentColorHex: "#2563EB",
            systemPrompt: prompt,
            isBuiltIn: false
        )
    }

    private var sterling: ChatAgent {
        ChatAgent.builtIns.first(where: { $0.id == ChatAgent.majikAgentID })!
    }

    // These cover the NATIVE persona swap. The original one-shot
    // `preamble(switchingTo:from:)` was a transition-based Swift-seam hack used
    // while `copilot_send` had no system-prompt slot; it was replaced by the
    // stateless FFI `systemPromptOverride(for:)`. The tests were left pointing
    // at the removed API, which broke compilation of the whole test target —
    // so they are retargeted here rather than deleted: the behavior they guard
    // (persona swap preserves command-bus parity) still matters.

    @Test("built-in Sterling uses no override so the engine persona stays in force")
    func sterlingUsesNoOverride() {
        #expect(SterlingAgentBridge.systemPromptOverride(for: sterling) == nil)
    }

    @Test("a custom agent overrides the persona and keeps command-bus parity")
    func customPersona() {
        let override = SterlingAgentBridge.systemPromptOverride(for: customAgent())
        #expect(override != nil)
        #expect(override?.contains("Bassline Bot") == true)
        #expect(override?.contains("deep sub-bass") == true)
        // Parity: the command bus must be preserved in the instruction.
        #expect(override?.contains("command bus") == true)
    }

    @Test("a custom agent with no prompt still shifts identity")
    func customNoPrompt() {
        let override = SterlingAgentBridge.systemPromptOverride(for: customAgent(name: "Namer", prompt: ""))
        #expect(override?.contains("Namer") == true)
        // Even with no persona text it must not silently drop tool parity.
        #expect(override?.contains("command bus") == true)
    }

    @Test("selecting Sterling again clears the override (the revert path)")
    func revertToSterling() {
        // Reverting is now expressed as "no override" rather than a preamble
        // announcing Sterling: clearing it hands the persona back to the
        // engine's committed system prompt.
        #expect(SterlingAgentBridge.systemPromptOverride(for: customAgent()) != nil)
        #expect(SterlingAgentBridge.systemPromptOverride(for: sterling) == nil)
    }
}
