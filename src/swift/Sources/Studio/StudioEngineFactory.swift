import Foundation

// The I1 flip lives here: which engine the Studio tab runs on.
//
// REAL_ENGINE (the app build that links MajiksEngine.xcframework, see
// Package.swift / project.yml) returns the FFI-backed RealStudioEngine, driving
// the same timeline-core command bus the CLI and MCP agents use. Every other
// build (CI / a `swift build` without the framework) compiles this file too but
// takes the mock branch, so the Studio tab always has a working engine and the
// no-framework build never breaks.
//
// RealStudioEngine only opens the audio device on the first play (a user
// action), so a launched-but-idle app never grabs the device.

enum StudioEngineFactory {
    /// The one session engine, shared by the DAW tab (StudioRootView) and the
    /// Settings ▸ MIDI tab (spec 7.1 "ownership hoist": both surfaces drive the
    /// SAME instance so learn/bindings edited in Settings are the ones the DAW
    /// timeline reacts to). Lazily created once on first access, thread-safe.
    /// Both engines are Sendable (RealStudioEngine and StudioMockEngine are
    /// actors), so the shared existential is concurrency-safe.
    static let shared: any StudioEngineProtocol = makeDefault()

    /// The engine the PIANO ROLL runs on.
    ///
    /// Same instance as `shared` on a real-engine build — deliberately, because
    /// the roll and the arrangement must agree on what a clip UUID means. The
    /// mock fallback below is the one the E1-ui lane shipped as the default; it
    /// is a demo clip that reaches nothing, so falling back to it is a real
    /// degradation and it is LOGGED as one rather than being silent.
    static let sharedNote: any StudioNoteEngineProtocol = makeNoteEngine()

    static func makeNoteEngine() -> any StudioNoteEngineProtocol {
        #if REAL_ENGINE
        if let real = shared as? RealStudioEngine { return real }
        NSLog("""
            StudioEngineFactory: the real engine is unavailable, so the piano roll is \
            running on StudioMockNoteEngine. Notes drawn in it are a DEMO and reach \
            neither the project nor the .mstudio package.
            """)
        #endif
        return StudioMockNoteEngine.demoSession()
    }

    /// True when the roll is on the real engine. The UI uses it to say so
    /// rather than presenting a demo clip as if it were the user's work.
    static var noteEngineIsReal: Bool {
        #if REAL_ENGINE
        return sharedNote is RealStudioEngine
        #else
        return false
        #endif
    }

    static var engineIsReal: Bool {
        #if REAL_ENGINE
        return shared is RealStudioEngine
        #else
        return false
        #endif
    }

    // MARK: - When the user's project could not be opened, SAY SO
    //
    // The catch below used to be one `NSLog` and nothing else, and what it hands
    // back in its place is not an empty stand-in — `StudioMockEngine`'s own
    // header calls it "the L5 performance-gate fixture: exactly 8 tracks and 100
    // clips". So a corrupt checkpoint, a broken hash chain or a permissions
    // problem produced a fully populated, fully interactive project that was a
    // TEST FIXTURE, presented as the user's work, with the only trace in
    // Console.app. Someone opening the app to find eight tracks they have never
    // seen has no way to tell that from "my project is fine" — and, worse, every
    // edit they then make lands in the mock and reaches no package at all.
    //
    // That is this codebase's signature failure (a piano roll wired to a mock
    // while the real engine ran alongside) one layer up: now it is the whole
    // project. It is recorded here so a surface can say it out loud.
    //
    // `nonisolated(unsafe)` on the same terms as `ArtworkDecodeCache`: written
    // exactly once, inside the lazy initializer of `shared`, before any reader
    // can exist — every read is ordered after that write by `shared` itself.

    /// Why the real engine is not running, in the engine's own words, or nil
    /// when it is running (or when this is a mock-only build, where there is no
    /// degradation to report).
    private nonisolated(unsafe) static var _fallbackReason: String?

    /// Non-nil when the Studio is running on `StudioMockEngine` *because the
    /// real engine failed*, never merely because this is a mock build.
    ///
    /// ⚠️ THIS DELIBERATELY DOES NOT TOUCH `shared`.
    ///
    /// The obvious version reads `_ = shared` first, so that the answer is
    /// guaranteed to have been decided. That is wrong here, and dangerously so:
    /// `RealStudioEngine.init` OPENS the user's `.mstudio` package, so a
    /// diagnostic accessor would become the thing that opens the project — from
    /// whatever context happened to ask, including a test bundle, which would
    /// open the owner's real package at `defaultProjectPath()` while the
    /// shipping app very possibly has it open too. No existing test touches
    /// `shared`; this must not be the first.
    ///
    /// So it reports only what has already been decided. A caller that has not
    /// yet constructed the engine correctly reads nil — there is no fallback
    /// yet, because there has been no attempt. The one caller that matters
    /// (`StudioRootView.announceEngineFallbackIfNeeded`) runs from `.onAppear`,
    /// long after `StudioViewModel` took `shared` in its initializer.
    static var engineFallbackReason: String? { _fallbackReason }

    /// What to put in front of the user. Deliberately says nothing about
    /// "engines" or "mocks" — the person this app is for has never opened a DAW
    /// and does not have those words. It says the two things that actually
    /// matter: this is not your project, and do not work in it.
    static func fallbackNotice(reason: String) -> String {
        "Your project could not be opened, so the Studio is showing a sample "
        + "project instead — nothing here is yours, and changes will not be saved. "
        + "(\(reason))"
    }

    static func makeDefault() -> any StudioEngineProtocol {
        #if REAL_ENGINE
        do {
            // The GUI app is AUDIBLE by default: a user pressing Play is heard,
            // no env var needed. `audibleByDefault` is false under XCTest so a
            // real-engine `swift test` stays silent (the automated-blast safety
            // never regresses).
            return try RealStudioEngine(dataDir: defaultProjectPath(), audible: audibleByDefault)
        } catch {
            NSLog("StudioEngineFactory: real engine init failed (\(error)); falling back to mock")
            _fallbackReason = "\(error)"
            return StudioMockEngine()
        }
        #else
        return StudioMockEngine()
        #endif
    }

    #if REAL_ENGINE
    /// The shared engine as its concrete type, for the surfaces that need more
    /// than `StudioEngineProtocol` — today that is the MCP host
    /// (`StudioMCPServerModel`), which drives `startMCP` / `stopMCP`.
    ///
    /// Returns nil when the real engine failed to initialize and `shared` fell
    /// back to `StudioMockEngine`; callers must treat that as "no server", never
    /// as success. Touching this materializes `shared`, so only call it when you
    /// actually intend to bring the engine up.
    static func realEngine() -> RealStudioEngine? {
        shared as? RealStudioEngine
    }
    #endif

    #if REAL_ENGINE
    /// Whether the GUI app should open an AUDIBLE output device by default. True
    /// for the shipping app; false under an automated test bundle (`swift test`
    /// / XCTest) so a real-engine test run never makes sound. The shipping app
    /// does not link XCTest, so this is true there. Belt-and-suspenders: checks
    /// both the XCTest env marker and whether XCTestCase is loaded.
    private static var audibleByDefault: Bool {
        let env = ProcessInfo.processInfo.environment
        let underXCTest = env["XCTestConfigurationFilePath"] != nil
            || env["XCTestSessionIdentifier"] != nil
            || NSClassFromString("XCTestCase") != nil
        return !underXCTest
    }

    /// The `.mstudio` package the tab opens. `--studio-project PATH` targets a
    /// specific package (the I1 proof + integration runs); otherwise a stable
    /// per-user package under Application Support.
    private static func defaultProjectPath() -> String {
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "--studio-project"), i + 1 < args.count {
            return args[i + 1]
        }
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("MajiksMusicStudio", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("Studio.mstudio").path
    }

    // The MCP server used to be started from here, which meant it only ever came
    // up once something first touched `shared` — i.e. after the user opened the
    // Studio (or MIDI Settings) tab. Launching with `--studio-mcp-pat` alone did
    // NOT serve anything, contrary to docs/MCP_API.md. The host now owns that
    // lifecycle end to end (StudioMCPServer.swift, called from
    // `applicationDidFinishLaunching`), so there is exactly one start path for
    // both launch arguments and the Settings toggle.
    #endif
}
