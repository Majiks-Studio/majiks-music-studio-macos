// swift-tools-version: 6.0
import PackageDescription
import Foundation

// I1 flip: the Studio tab runs on the REAL FFI-backed engine when the built
// MajiksEngine.xcframework is present, and falls back to StudioMockEngine when
// it is not, so a build that never ran scripts/build-engine.sh (CI, a fresh
// `swift build`) still compiles and runs.
//
// Selection:
//   MAJIKS_ENGINE=real  -> force the real engine (fails if the framework is
//                          missing, which is the point: catch a skipped build)
//   MAJIKS_ENGINE=mock  -> force StudioMockEngine even if the framework exists
//   unset (default)     -> real when MajiksEngine.xcframework is present here,
//                          mock otherwise
//
// The app/release build (project.yml -> xcodegen -> xcodebuild) always builds
// the framework first and links it. This SPM manifest is the CI + quick-build
// path: without the framework it is the mock build the acceptance requires.

let engineOverride = ProcessInfo.processInfo.environment["MAJIKS_ENGINE"]
let frameworkPath = "MajiksEngine.xcframework"
let frameworkPresent = FileManager.default.fileExists(atPath: frameworkPath)
let useRealEngine: Bool
switch engineOverride {
case "real": useRealEngine = true
case "mock": useRealEngine = false
default: useRealEngine = frameworkPresent
}

var packageTargets: [Target] = []
var appDependencies: [Target.Dependency] = []
var appExcludes: [String] = ["Info.plist"]
var appSwiftSettings: [SwiftSetting] = []
var appLinkerSettings: [LinkerSetting] = []

if useRealEngine {
    // Link the built static xcframework + the committed UniFFI bindings under
    // Sources/Engine, and compile the real-engine code paths.
    packageTargets.append(.binaryTarget(name: "MajiksEngine", path: frameworkPath))
    appDependencies.append(.target(name: "MajiksEngine"))
    appSwiftSettings.append(.define("REAL_ENGINE"))
    // The Rust staticlib pulls in libc++ (signalsmith-stretch is C++) and the
    // CoreAudio frameworks cpal binds; Xcode/SPM does not read Rust's native
    // link metadata, so name them here.
    appLinkerSettings = [
        .linkedLibrary("c++"),
        .linkedFramework("CoreAudio"),
        .linkedFramework("AudioToolbox"),
        .linkedFramework("AudioUnit"),
    ]
} else {
    // No framework: keep Sources/Engine out of the build (it links the
    // xcframework) and run on StudioMockEngine.
    appExcludes.append("Engine")
}

packageTargets.append(
    .executableTarget(
        name: "MajiksMusicStudio",
        dependencies: appDependencies,
        path: "Sources",
        exclude: appExcludes,
        swiftSettings: appSwiftSettings,
        linkerSettings: appLinkerSettings
    )
)
packageTargets.append(
    .testTarget(
        name: "MajiksMusicStudioTests",
        dependencies: ["MajiksMusicStudio"],
        path: "Tests",
        // The tests need REAL_ENGINE too, or a `#if REAL_ENGINE` test compiles
        // to NOTHING and `swift test` reports a cheerful "0 tests passed" —
        // a green run that proves the opposite of what it looks like. The
        // real-engine join tests (StudioPianoRollRealEngineTests) are exactly
        // that shape, so the flag has to reach here.
        swiftSettings: appSwiftSettings
    )
)

let package = Package(
    name: "MajiksMusicStudio",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MajiksMusicStudio", targets: ["MajiksMusicStudio"])
    ],
    targets: packageTargets
)
