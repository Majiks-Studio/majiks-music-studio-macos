import Testing
import Foundation
@testable import MajiksMusicStudio

// The MCP host contract (docs/MCP_API.md "Connecting"):
//
//  - `--studio-mcp-pat <TOKEN> [--studio-mcp-port <N>]` is what turns the server
//    on for a run. No flag, or a blank token, means NO server: fail closed.
//  - The connection line the app hands a human must be the exact `claude mcp add`
//    shape the docs promise, on the resolved port.
//  - Tokens are masked for display; the clear value only ever leaves via an
//    explicit reveal/copy.
//
// These are the pure wire helpers, so they run on the mock build with no engine.

@Suite("Studio MCP launch flags")
struct StudioMCPLaunchFlagTests {
    @Test("no --studio-mcp-pat means no server")
    func absentFlagFailsClosed() {
        #expect(StudioMCPWire.parseLaunchFlags(["MajiksMusicStudio"]) == nil)
        #expect(StudioMCPWire.parseLaunchFlags(["MajiksMusicStudio", "--open-studio-tab"]) == nil)
    }

    @Test("a blank or missing token value is refused, not defaulted")
    func blankTokenFailsClosed() {
        #expect(StudioMCPWire.parseLaunchFlags(["app", "--studio-mcp-pat"]) == nil)
        #expect(StudioMCPWire.parseLaunchFlags(["app", "--studio-mcp-pat", "   "]) == nil)
        #expect(StudioMCPWire.parseLaunchFlags(["app", "--studio-mcp-pat="]) == nil)
        // A following flag is a MISSING value, never a token named "--...".
        #expect(StudioMCPWire.parseLaunchFlags(["app", "--studio-mcp-pat", "--studio-mcp-port", "9000"]) == nil)
    }

    @Test("a token alone serves on the engine's default port")
    func tokenDefaultsToPort8478() throws {
        let flags = try #require(StudioMCPWire.parseLaunchFlags(["app", "--studio-mcp-pat", "mms_abc"]))
        #expect(flags.pat == "mms_abc")
        #expect(flags.port == 8478)
        #expect(StudioMCPWire.defaultPort == 8478)
    }

    @Test("--studio-mcp-port overrides the default, in both spellings")
    func portOverride() throws {
        let spaced = try #require(StudioMCPWire.parseLaunchFlags(
            ["app", "--studio-mcp-pat", "mms_abc", "--studio-mcp-port", "9123"]
        ))
        #expect(spaced.port == 9123)

        let joined = try #require(StudioMCPWire.parseLaunchFlags(
            ["app", "--studio-mcp-pat=mms_xyz", "--studio-mcp-port=9124"]
        ))
        #expect(joined.pat == "mms_xyz")
        #expect(joined.port == 9124)
    }

    @Test("an unparseable or zero port falls back to the default rather than binding 0")
    func badPortFallsBack() throws {
        let bad = try #require(StudioMCPWire.parseLaunchFlags(
            ["app", "--studio-mcp-pat", "mms_abc", "--studio-mcp-port", "not-a-port"]
        ))
        #expect(bad.port == 8478)

        let zero = try #require(StudioMCPWire.parseLaunchFlags(
            ["app", "--studio-mcp-pat", "mms_abc", "--studio-mcp-port", "0"]
        ))
        #expect(zero.port == 8478)
    }
}

@Suite("Studio MCP connection line")
struct StudioMCPConnectionLineTests {
    @Test("matches the documented claude mcp add shape verbatim")
    func documentedShape() {
        let line = StudioMCPWire.connectionLine(port: 8478, token: "mms_TOKEN")
        #expect(line == "claude mcp add majiks-studio --transport http --url http://127.0.0.1:8478/mcp --header \"Authorization: Bearer mms_TOKEN\"")
    }

    @Test("carries the resolved port, not the default")
    func usesResolvedPort() {
        let line = StudioMCPWire.connectionLine(port: 9123, token: "t")
        #expect(line.contains("http://127.0.0.1:9123/mcp"))
        #expect(!line.contains("8478"))
    }

    @Test("health probes loopback only")
    func healthIsLoopback() throws {
        let url = try #require(StudioMCPWire.healthURL(port: 8478))
        #expect(url.absoluteString == "http://127.0.0.1:8478/health")
    }
}

@Suite("Studio MCP token handling")
struct StudioMCPTokenTests {
    @Test("masking never leaks more than the first four characters")
    func maskingHidesTheSecret() {
        let token = "mms_0123456789ABCDEF"
        let masked = StudioMCPWire.mask(token)
        #expect(masked.hasPrefix("mms_"))
        #expect(!masked.contains("0123456789"))
        #expect(masked.count < token.count)
        #expect(StudioMCPWire.mask("") == "")
    }

    @Test("minted tokens are prefixed, long, and not repeated")
    func generatedTokensAreOpaqueAndUnique() {
        let a = StudioMCPWire.generatePAT()
        let b = StudioMCPWire.generatePAT()
        #expect(a.hasPrefix("mms_"))
        #expect(a.count == 56)          // "mms_" + 52 chars of entropy
        #expect(a != b)
        // Crockford base32 body: no I, L, O, U (the ambiguous glyphs).
        let body = a.dropFirst(4)
        #expect(body.allSatisfy { "0123456789ABCDEFGHJKMNPQRSTVWXYZ".contains($0) })
    }
}

@Suite("Studio MCP host state")
@MainActor
struct StudioMCPStateTests {
    /// A model on a throwaway UserDefaults suite AND a throwaway Keychain item,
    /// so the test never touches the user's real settings or the user's real
    /// secrets.
    ///
    /// The Keychain half was missing, and it was not harmless. `storedPAT()`
    /// read the login keychain at the app's own hardcoded service name, so
    /// `connectionLineIsMaskedByDefault` — whose comment says "with no PAT
    /// stored" — silently depended on the developer's machine never having run
    /// the app and generated one. On the owner's machine
    /// (`com.majik.musicstudio` / `studio_mcp_pat`, created 2026-07-25) it
    /// therefore read a REAL token, masked it, and failed on `<TOKEN>`:
    ///
    ///   Expectation failed: (line → "… --header "Authorization: Bearer
    ///   mms_••••"").contains("<TOKEN>")
    ///
    /// That failure was dismissed as environmental noise for a whole session.
    /// It was environmental — but the environment it depended on was the user's
    /// keychain, which is the same missing seam that let a keychain read end up
    /// inside a SwiftUI layout pass (see `StudioKeychainItem`). The assertion
    /// below is unchanged; it now has the precondition it always claimed.
    private func makeModel(_ name: String) -> StudioMCPServerModel {
        let defaults = UserDefaults(suiteName: "StudioMCPHostTests.\(name).\(UUID().uuidString)")!
        let pat = StudioKeychainItem(
            service: "com.majik.musicstudio.tests.mcp.\(UUID().uuidString)",
            account: "studio_mcp_pat"
        )
        return StudioMCPServerModel(defaults: defaults, pat: pat)
    }

    @Test("defaults are fail-closed: off, port 8478")
    func defaultsAreOff() {
        let model = makeModel("defaults")
        #expect(model.isEnabled == false)
        #expect(model.port == 8478)
        #expect(model.state == .off)
        #expect(model.state.isRunning == false)
    }

    @Test("an empty PAT is refused before any engine call")
    func emptyPatRefused() async {
        let model = makeModel("empty-pat")
        let started = await model.start(pat: "   ", port: 8478, logTokenInClear: false)
        #expect(started == false)
        #expect(model.state.isRunning == false)
        if case .failed = model.state {} else {
            Issue.record("expected .failed for an empty PAT, got \(model.state)")
        }
    }

    @Test("a mock-engine build reports unavailable, never success")
    func mockBuildNeverClaimsSuccess() async {
        let model = makeModel("mock-build")
        let started = await model.start(pat: "mms_test", port: 18478, logTokenInClear: false)
        #if REAL_ENGINE
        // On a real-engine build this test would actually bind a socket, which
        // is out of scope here; only the mock build asserts the honest refusal.
        _ = started
        #else
        #expect(started == false)
        #expect(model.state.isRunning == false)
        if case .unavailable = model.state {} else {
            Issue.record("expected .unavailable on a mock build, got \(model.state)")
        }
        #expect(model.engineAvailable == false)
        #endif
    }

    @Test("bootstrap with no flags and the toggle off starts nothing")
    func bootstrapFailsClosed() {
        let model = makeModel("bootstrap")
        model.bootstrapAtLaunch(arguments: ["MajiksMusicStudio"])
        #expect(model.state == .off)
    }

    @Test("the pane's default connection line never renders a live token")
    func connectionLineIsMaskedByDefault() {
        let model = makeModel("masked-line")
        let line = model.connectionLine(revealed: false)
        #expect(line.contains("claude mcp add majiks-studio"))
        // With no PAT stored the line is a template, not a secret.
        #expect(line.contains("<TOKEN>"))
    }
}
