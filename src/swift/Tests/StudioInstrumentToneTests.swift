import Testing
import Foundation
import Combine
import SwiftUI
@testable import MajiksMusicStudio

// THE TONE LANE, tested from the gesture end.
//
// The synth has had four waveforms and a full ADSR since E2, every one of them
// automatable, and NOTHING in the app could set one — so the only instrument
// sound the product could make was a raw sawtooth. This file asserts the three
// things that turn that into a fixed bug rather than a new inert control:
//
//   • the gesture reaches the BUS, as the exact `device.param.set` commands, in
//     one txn bracket, so one click is one Cmd-Z;
//   • the panel is REACHABLE from a synth track at all (it was not — the chip
//     was not a button for a synth and the context menu had no item);
//   • the Swift preset table has not drifted from the contract the ENGINE proof
//     renders, which is the only thing keeping the two halves honest.
//
// The audio itself is proven where audio can be proven:
// `engine/agent-surface/tests/instrument_tone.rs` renders every preset in that
// contract through the real command bus and asserts they are audibly distinct.
// The preview engine here is silent and never claims otherwise.

// MARK: - Helpers

@MainActor
private func adoptedViewModel(_ engine: StudioMockEngine) async throws -> StudioViewModel {
    let vm = StudioViewModel(engine: engine)
    vm.startPolling()
    for _ in 0..<200 where vm.snapshot == nil {
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    vm.stopPolling()
    try #require(vm.snapshot != nil, "the view model never adopted a snapshot")
    return vm
}

/// A track carrying a bare Synth — the state a person is in the moment they
/// press "Add Synth", and the state in which the only sound available used to
/// be a sawtooth.
@MainActor
private func synthTrack(_ engine: StudioMockEngine, _ vm: StudioViewModel) async throws
    -> (track: UUID, device: String) {
    let trackID = UUID()
    _ = await engine.send(.trackAdd(trackID: trackID.uuidString, name: "Keys", index: 0))
    let deviceID = "inst_tone"
    _ = await engine.send(.deviceAdd(trackID: trackID, deviceID: deviceID, kind: "synth"))
    vm.startPolling()
    for _ in 0..<200 where vm.snapshot?.tracks.first(where: { $0.id == trackID })?
        .devices.isEmpty != false {
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    vm.stopPolling()
    try #require(vm.snapshot?.tracks.first(where: { $0.id == trackID })?.devices.first != nil,
                 "the synth never landed")
    return (trackID, deviceID)
}

private func journaledNames(_ engine: StudioMockEngine, after mark: Int) async -> [String] {
    await engine.journal.dropFirst(mark).map(\.catalogName)
}

@MainActor
private func device(_ vm: StudioViewModel, _ trackID: UUID) -> StudioDeviceSnapshot? {
    vm.snapshot?.tracks.first(where: { $0.id == trackID })?.devices.first
}

// MARK: - 1. The table is the contract

@Suite("The preset table has not drifted from the engine contract")
struct StudioInstrumentPresetContractTests {

    private static func contract() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()    // Tests
            .deletingLastPathComponent()    // swift
            .deletingLastPathComponent()    // src
            .deletingLastPathComponent()    // repo root
            .appendingPathComponent("engine/contracts/instrument-presets.v1.json")
        let data = try Data(contentsOf: url)
        return try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any],
            "engine/contracts/instrument-presets.v1.json is not a JSON object")
    }

    /// THE drift guard, and the reason the numbers live in a contract file at
    /// all rather than in two hand-written tables.
    ///
    /// The Rust proof renders every preset in that file and asserts they are
    /// audibly distinct; this table is what the BUTTONS actually send. If the
    /// two ever disagree, the proof is proving a sound nobody can select. There
    /// is no clever mechanism keeping them together — there is this test.
    @Test("every preset matches engine/contracts/instrument-presets.v1.json exactly")
    func tableMatchesTheContract() throws {
        let doc = try Self.contract()
        let entries = try #require(doc["presets"] as? [[String: Any]])

        #expect(entries.count == StudioInstrumentTone.presets.count, """
            the contract has \(entries.count) presets and the Swift table has \
            \(StudioInstrumentTone.presets.count). A preset in one and not the other is either \
            a button that sends an unproven sound or a proven sound with no button.
            """)

        for (i, entry) in entries.enumerated() {
            let mine = StudioInstrumentTone.presets[i]
            #expect(entry["id"] as? String == mine.id, "preset \(i): id drifted")
            #expect(entry["name"] as? String == mine.name, "preset \(mine.id): name drifted")
            #expect(entry["blurb"] as? String == mine.blurb, """
                preset \(mine.id): the description the user reads drifted from the contract. \
                The Rust proof asserts the sound DOES what this sentence promises, so a \
                changed sentence is a changed promise.
                """)
            let params = try #require(entry["params"] as? [String: NSNumber],
                                      "preset \(mine.id): no params")
            #expect(params.count == mine.params.count, "preset \(mine.id): key count drifted")
            for (key, value) in params {
                let ours = try #require(mine.params[key],
                                        "preset \(mine.id): Swift is missing key \(key)")
                #expect(abs(ours - value.doubleValue) < 1e-9, """
                    preset \(mine.id) key \(key): contract says \(value), Swift sends \(ours). \
                    The engine proof rendered the contract's number; the button sends this one.
                    """)
            }
        }
    }

    /// Every key a preset writes must be one the ENGINE accepts. A typo here
    /// would be a refusal at apply time — a preset button that pops a warning.
    @Test("every preset key is an engine instrument parameter")
    func keysAreEngineKeys() {
        for preset in StudioInstrumentTone.presets {
            for key in preset.params.keys {
                #expect(StudioMockEngine.deviceParamKeys.contains(key),
                        "preset \(preset.id) writes \(key), which is not in DEVICE_PARAM_KEYS")
            }
        }
    }

    /// Every preset writes the SAME key set. If one omitted a key another set,
    /// switching between them would leave the previous preset's value behind
    /// and the "Playing: X" line would be lying.
    @Test("switching between any two presets leaves nothing behind")
    func presetsWriteTheSameKeys() throws {
        let first = try #require(StudioInstrumentTone.presets.first)
        let keys = Set(first.params.keys)
        for preset in StudioInstrumentTone.presets {
            #expect(Set(preset.params.keys) == keys, """
                \(preset.id) writes a different set of keys from \(first.id). Selecting it after \
                \(first.id) would leave a stale value behind, and `current(for:)` would then \
                name neither.
                """)
        }
    }

    /// This app ships NO instrument samples — the sounds vault is drum
    /// one-shots and stems. Naming a synth patch "Piano" would be a promise the
    /// product cannot keep, and the person it was built for asked for a piano.
    @Test("no preset claims to be a recording of a real instrument")
    func nothingClaimsToBeSampled() {
        let forbidden = ["grand", "acoustic", "violin", "cello", "strings",
                         "guitar", "trumpet", "sax", "flute", "choir"]
        for preset in StudioInstrumentTone.presets {
            let name = preset.name.lowercased()
            #expect(name != "piano", """
                "Piano" promises a recorded acoustic piano this app has no samples for. \
                "Electric Piano" is the honest name for a synthesized imitation.
                """)
            for word in forbidden {
                #expect(!name.contains(word), "\(preset.name) claims to be a sampled instrument")
            }
            #expect(preset.blurb.count > 40,
                    "\(preset.id) has no usable description for someone who has never used a DAW")
        }
    }
}

// MARK: - 2. The gesture reaches the bus

@Suite("Picking a sound reaches the command bus")
struct StudioInstrumentToneWiringTests {

    @Test("one preset click is one txn bracket of device.param.set")
    @MainActor
    func onePresetOneBracket() async throws {
        let engine = StudioMockEngine()
        let vm = try await adoptedViewModel(engine)
        let (trackID, deviceID) = try await synthTrack(engine, vm)
        let preset = try #require(StudioInstrumentTone.presets.first)
        let mark = await engine.journal.count

        await vm.applyInstrumentPreset(trackID: trackID, deviceID: deviceID, preset).value

        let names = await journaledNames(engine, after: mark)
        let expected = ["txn.begin"] + Array(repeating: "device.param.set", count: preset.params.count)
            + ["txn.commit"]
        #expect(names == expected, """
            picking a sound must be exactly one bracket of \(preset.params.count) parameter \
            writes, so one click is one Cmd-Z. Got: \(names)
            """)
    }

    /// THE assertion that a preset button is not decoration: after the click the
    /// DEVICE carries the preset's numbers, which is what `build_instrument`
    /// reads to make the sound.
    @Test("the device ends up carrying the preset's parameters")
    @MainActor
    func theDeviceCarriesTheSound() async throws {
        let engine = StudioMockEngine()
        let vm = try await adoptedViewModel(engine)
        let (trackID, deviceID) = try await synthTrack(engine, vm)
        #expect(device(vm, trackID)?.params.isEmpty == true,
                "a brand-new synth must store NOTHING — an absent key is the DSP default")

        let pluck = try #require(StudioInstrumentTone.presets.first { $0.id == "pluck" })
        await vm.applyInstrumentPreset(trackID: trackID, deviceID: deviceID, pluck).value

        let stored = try #require(device(vm, trackID)?.params)
        for (key, value) in pluck.params {
            #expect(stored[key] == value, "\(key) never reached the device")
        }
        #expect(StudioInstrumentTone.current(for: stored)?.id == "pluck",
                "the panel cannot tell which sound is playing, so nothing would light up")
    }

    /// Sparsity, from the UI end. Undoing the first sound must return the
    /// device to storing NOTHING, not to storing a written-out default — the
    /// property that made `device.param.set` safe to ship at all.
    @Test("one Cmd-Z takes the whole sound back, all the way to nothing stored")
    @MainActor
    func undoReturnsToSparse() async throws {
        let engine = StudioMockEngine()
        let vm = try await adoptedViewModel(engine)
        let (trackID, deviceID) = try await synthTrack(engine, vm)
        let organ = try #require(StudioInstrumentTone.presets.first { $0.id == "organ" })

        await vm.applyInstrumentPreset(trackID: trackID, deviceID: deviceID, organ).value
        #expect(device(vm, trackID)?.params.isEmpty == false)

        #expect(await engine.undo(), "there was exactly one unit to undo")
        let after = try #require(await engine.snapshot(ifNewerThan: nil))
        let restored = try #require(after.tracks.first(where: { $0.id == trackID })?.devices.first)

        #expect(restored.params.isEmpty, """
            undo left parameters behind. One click set seven of them, so one Cmd-Z must clear \
            seven — and it must clear them to ABSENT, because an absent key means the DSP \
            default and a written default is a different thing that only looks the same today.
            """)
    }

    /// A raw control is its own undo step: someone nudging one slider expects
    /// one Cmd-Z to undo one nudge, not the whole patch.
    @Test("a single raw control is one command, not a bracket")
    @MainActor
    func oneRawControlIsOneCommand() async throws {
        let engine = StudioMockEngine()
        let vm = try await adoptedViewModel(engine)
        let (trackID, deviceID) = try await synthTrack(engine, vm)
        let mark = await engine.journal.count

        await vm.setInstrumentParam(trackID: trackID, deviceID: deviceID,
                                    key: "cutoff", value: 2500).value

        #expect(await journaledNames(engine, after: mark) == ["device.param.set"])
        #expect(device(vm, trackID)?.params["cutoff"] == 2500)
    }

    /// An unset key reads as the DSP DEFAULT, never as zero. A slider showing 0
    /// for an untouched envelope would be describing a sound nobody is hearing.
    @Test("an untouched control shows the DSP default, not zero")
    func unsetKeysReadAsTheDSPDefault() {
        #expect(StudioInstrumentTone.value("cutoff", in: [:]) == 12000)
        #expect(StudioInstrumentTone.value("sustain", in: [:]) == 0.75)
        #expect(StudioInstrumentTone.value("cutoff", in: ["cutoff": 900]) == 900)
        // And the default waveform is the SOFT one. The whole complaint was
        // that it was a raw saw (1); this mirrors `InstrumentParams::default`.
        #expect(StudioInstrumentTone.value("waveform", in: [:]) != 1,
                "the starting sound is back to a raw sawtooth")
    }
}

// MARK: - 3. Reachability — the panel exists for a synth at all

@Suite("The tone controls are reachable from a synth track")
struct StudioInstrumentToneReachabilityTests {

    private static func source(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Studio")
        return try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
    }

    /// The regression this lane exists for, stated directly: a synth device has
    /// a panel. `openInstrumentPanel` used to demand `playsSamples`, so a synth
    /// track could not open it from anywhere.
    @Test("a synth track can open the instrument panel")
    @MainActor
    func aSynthCanOpenThePanel() async throws {
        let engine = StudioMockEngine()
        let vm = try await adoptedViewModel(engine)
        let (trackID, _) = try await synthTrack(engine, vm)

        let d = try #require(device(vm, trackID))
        #expect(d.makesItsOwnSound, "a synth must be recognised as making its own sound")
        #expect(d.hasAnEditablePanel, """
            a synth reports no editable panel, so the waveform and envelope controls are behind \
            a door with no handle — which is exactly the state this lane found them in.
            """)

        vm.openInstrumentPanel(trackID: trackID)
        #expect(vm.instrumentPanelTrackID == trackID,
                "openInstrumentPanel refused a synth, so the tone controls cannot be reached")
    }

    /// Both affordances still lead there. Counting rather than `contains`: a
    /// mutation that gutted one of them passes a `contains` check because the
    /// other copy of the call is still in the file.
    @Test("the chip and the right-click menu both open the panel")
    func bothAffordancesLeadToThePanel() throws {
        let header = try Self.source("StudioTrackHeaderColumn.swift")
        let opens = header.components(separatedBy: "model.openInstrumentPanel(").count - 1
        #expect(opens >= 2, """
            openInstrumentPanel is called \(opens) time(s) in the track header. Both routes have \
            to send it — the instrument chip AND the right-click menu — because the chip is 9pt \
            tall and on a 4K TV at couch distance the right-click is the one that lands.
            """)
        #expect(!header.contains("device.playsSamples"), """
            the header is gating an instrument affordance on `playsSamples` again. That predicate \
            is what made a Synth unreachable: it is false for the one instrument that HAS a tone \
            to edit. Use `hasAnEditablePanel`.
            """)
    }

    /// Every control in the tone editor calls a gesture. Delete a call and this
    /// fails by name instead of every other test staying green.
    @Test("every tone control in the panel calls a gesture")
    func panelControlsAreWired() throws {
        let panel = try Self.source("StudioInstrumentView.swift")
        #expect(panel.contains("model.applyInstrumentPreset("),
                "the named-sound buttons send nothing")
        // Twice: the waveform chips and the raw sliders both commit through it.
        let sets = panel.components(separatedBy: "model.setInstrumentParam(").count - 1
        #expect(sets >= 2, """
            setInstrumentParam is called \(sets) time(s). The waveform chips and the raw sliders \
            are separate controls and both have to reach the bus, or one of them is decoration.
            """)
        #expect(panel.contains("StudioSynthToneEditor"),
                "the panel no longer shows the tone editor for a synth")
    }

    /// The honesty sentence is on screen, not just in a comment. A synth preset
    /// called "Electric Piano" next to no explanation is how a person concludes
    /// the app has sampled instruments.
    @Test("the panel says on screen that these are not recordings")
    func thePanelIsHonestAboutWhatTheseAre() throws {
        let panel = try Self.source("StudioInstrumentView.swift")
        #expect(panel.contains("recording of a real instrument"), """
            the panel no longer tells the user these sounds are built from scratch rather than \
            recorded. This product has no instrument samples at all, so leaving that out turns \
            "Electric Piano" into a claim it cannot keep.
        """)
    }

    /// The regression is a pixel/layout failure: the raw editor is taller than
    /// the sheet, and a fixed VStack used to push the footer below the clipped
    /// frame. Render the REAL panel with the disclosure open, at its shipped
    /// size, and inspect the footer band. The hard numbers are expected pixels
    /// from this panel, not a value derived from the view under test.
    @Test("the expanded tone editor keeps Done inside the panel")
    @MainActor
    func expandedToneEditorKeepsDoneInsidePanel() async throws {
        let engine = StudioMockEngine()
        let vm = try await adoptedViewModel(engine)
        let (trackID, _) = try await synthTrack(engine, vm)
        defer { vm.stopPolling() }

        let panel = StudioInstrumentView(
            model: vm, trackID: trackID, isPresented: .constant(true),
            initiallyShowsRawControls: true)
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: panel)
        renderer.scale = 1
        let image = try #require(renderer.cgImage, "the expanded panel did not rasterize")
        #expect(image.width == 460, "the shipped panel width changed")
        #expect(image.height == 600, "the shipped synth panel height changed")

        // The footer is right-aligned and its button occupies this fixed band
        // in the shipped 460 pt panel. Compare against the panel background so
        // anti-aliased text contributes mass, not merely changed-pixel count.
        let bytesPerPixel = 4
        let rowBytes = image.bytesPerRow
        let data = image.dataProvider?.data as Data?
        let rgba = try #require(data, "the panel had no pixel buffer")
        func rgb(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8) {
            let i = y * rowBytes + x * bytesPerPixel
            return (rgba[i], rgba[i + 1], rgba[i + 2])
        }
        let background = rgb(2, 590)
        var footerInkMass = 0
        for y in 550..<590 {
            for x in 380..<450 {
                let p = rgb(x, y)
                footerInkMass += abs(Int(p.0) - Int(background.0))
                    + abs(Int(p.1) - Int(background.1))
                    + abs(Int(p.2) - Int(background.2))
            }
        }
        #expect(footerInkMass > 2_000,
                "Done is not visibly inside the bottom footer band; ink mass was \(footerInkMass)")
    }
}
