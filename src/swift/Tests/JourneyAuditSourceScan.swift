import Foundation

// Reading a source file as EVIDENCE, without letting the file's own prose
// answer the question.
//
// Some wiring cannot be observed without a window — a `.onAppear` branch, a
// `.onDrop` closure — so a few guards in this suite read the source instead.
// That is a legitimate last resort and it has two failure modes, both of which
// have bitten this project, and one of which had already bitten THIS lane
// before it was caught:
//
// ── 1. THE COMMENT ANSWERS THE GUARD ────────────────────────────────────────
//
// A concurrent lane grepped `Main.swift` for `CommandMenu("View")` and got
// three hits — every one its own warning prose in a comment explaining the
// defect. Comment-stripped, the code declares none. Had it read the raw file,
// all three of its guards would have been answered by the comments describing
// what they police: green forever, catching nothing.
//
// This codebase comments the WHY, heavily, so its source files are full of
// prose naming the exact symbols its guards look for. Raw `contains` over a
// well-commented file is not evidence.
//
// ── 2. THE DECLARATION ANSWERS THE GUARD ────────────────────────────────────
//
// `StudioEngineFallbackTests` asserted that `StudioRootView` calls
// `announceEngineFallbackIfNeeded()` with a bare `contains`. The declaration
// line — `private func announceEngineFallbackIfNeeded() {` — contains that
// substring, so deleting the CALL left the guard green. Worse, the two other
// strings it checked (`StudioEngineFactory.engineFallbackReason`,
// `fallbackNotice(reason:`) live INSIDE that function's body, so the whole
// guard was satisfied by the function it was policing. A mutation run would
// have shown it SURVIVING; it is fixed here instead.
//
// `callSites(of:in:)` below is the answer to both: strip the prose, then count
// uses that are not the definition.

enum JourneyAuditSource {

    /// The file with comment PROSE removed.
    ///
    /// Deliberately conservative rather than a real lexer:
    ///
    ///  * whole-line comments (`//`, `///`, and `*` / `/*` continuation lines
    ///    inside a block) are dropped — that is where this codebase's heavy
    ///    explanatory prose lives, and it is the actual risk;
    ///  * a trailing `//` comment is truncated, EXCEPT when preceded by `:`,
    ///    so `"https://…"` inside a string literal survives intact.
    ///
    /// It does not attempt to understand string literals in general. It does
    /// not need to: the guards using it look for identifiers and call syntax,
    /// not for text that could plausibly sit inside a quoted string. Where that
    /// stops being true, the guard should assert on behaviour instead of on
    /// source — reading source is already the fallback, not the goal.
    static func code(_ text: String) -> String {
        var out: [String] = []
        var inBlock = false
        for raw in text.components(separatedBy: .newlines) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if inBlock {
                if trimmed.contains("*/") { inBlock = false }
                continue
            }
            if trimmed.hasPrefix("/*") {
                if !trimmed.contains("*/") { inBlock = true }
                continue
            }
            if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") { continue }
            out.append(stripTrailingComment(raw))
        }
        return out.joined(separator: "\n")
    }

    /// Cut a trailing `//` comment, leaving `://` (URL schemes) alone.
    private static func stripTrailingComment(_ line: String) -> String {
        let chars = Array(line)
        var i = 0
        while i + 1 < chars.count {
            if chars[i] == "/" && chars[i + 1] == "/" {
                if i > 0 && chars[i - 1] == ":" { i += 1; continue }
                return String(chars[..<i])
            }
            i += 1
        }
        return line
    }

    /// How many times `name` is CALLED in `text`, not counting its own
    /// declaration and not counting anything written in a comment.
    ///
    /// The declaration contributes one occurrence of `name(` and one of
    /// `func name(`, so subtracting the latter leaves the real call sites.
    static func callSites(of name: String, in text: String) -> Int {
        let source = code(text)
        let uses = occurrences(of: "\(name)(", in: source)
        let declarations = occurrences(of: "func \(name)(", in: source)
        return uses - declarations
    }

    /// Occurrences of `needle`, comment-stripped.
    static func mentions(of needle: String, in text: String) -> Int {
        occurrences(of: needle, in: code(text))
    }

    private static func occurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        return haystack.components(separatedBy: needle).count - 1
    }

    /// A file under `Sources/`, read for one of the guards above.
    static func source(_ relativePath: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)   // …/Tests/JourneyAuditSourceScan.swift
            .deletingLastPathComponent()            // …/Tests
            .deletingLastPathComponent()            // …/swift
            .appendingPathComponent("Sources")
            .appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }
}
