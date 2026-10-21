import Foundation

/// What the app says when the engine refuses a command.
///
/// # The defect this replaces
///
/// `StudioViewModel.send` threw the result away: `Task { await engine.send(command) }`.
/// Every gesture that went through it was fire-and-forget, so a refusal was
/// indistinguishable from success — the user right-clicked a track, chose
/// Rename, typed a name, and nothing happened, with nothing said. Eleven
/// shipping gestures were in exactly that state, and the reason it survived so
/// long is that a silent refusal leaves no evidence anywhere: not on screen,
/// not in a log, not in a test.
///
/// # Two audiences, two strings
///
/// The engine's refusal is precise and unreadable:
/// `track.setHeight: /: additional property "height" not allowed`. To someone
/// who has never used a DAW that is not a sentence, it is a **crash** — it
/// looks like the internals fell out of the program. So the person gets a
/// sentence about the thing they were trying to do, in the words of the menu
/// item they clicked, and the engine's own text goes to the console where the
/// person debugging it will look.
///
/// This is the same shape as the catalog's own answer to the problem:
/// `import.audio` and `gen.song` name the parameters they ignored **in their
/// result**, rather than failing and leaving the caller to guess. Saying what
/// happened is part of the command, not an afterthought bolted onto the error
/// path.
enum StudioRefusal {

    /// The sentence for a gesture that has not named its own.
    ///
    /// Deliberately not "Error" and not a code: it says what did not happen and
    /// that nothing was damaged, which are the two things someone needs before
    /// they decide whether to try again. A gesture that can say something more
    /// specific always should — this is the floor, not the target.
    static let generic = "Majik's could not make that change. Nothing was altered."

    /// Say a refusal to the person, and to the log.
    ///
    /// - Parameters:
    ///   - sentence: what the PERSON reads. The gesture's own words.
    ///   - engineDetail: the engine's refusal text. Console only, on purpose.
    ///   - command: the catalog name, so a log line is greppable by verb.
    ///
    /// A toast and not an alert, matching `applyInstrumentPreset`: a refused
    /// context-menu item is not worth a modal, and the same fix (try again,
    /// having noticed) is available either way.
    @MainActor
    static func say(_ sentence: String, engineDetail: String?, command: StudioEngineCommand) {
        NSLog("Studio: %@ refused: %@", command.catalogName, engineDetail ?? "no detail")
        ToastManager.shared.show(sentence, style: .warning, seconds: ToastDuration.actionable)
    }
}
