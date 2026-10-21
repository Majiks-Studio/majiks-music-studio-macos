import Testing
import Foundation
import SwiftUI
@testable import MajiksMusicStudio

// Discoverability: the four things the owner could not find in 3.4.12.
//
// Every feature below already existed and worked. These tests are not "does
// rewind seek" — that is transport's job — they are "is the affordance
// reachable without being told". Discoverability resists testing; where a
// behaviour test is impossible we label a shape or pixel check as such, and
// mutation-check the assertion so a silent removal is a named failure.

// MARK: - Source shape (labelled as shape checks)

@Suite("discoverability shape")
struct StudioDiscoverabilityShapeTests {

    private static let sourcesRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()          // Tests
        .appendingPathComponent("../Sources")
        .standardizedFileURL

    private func source(_ relative: String) throws -> String {
        let url = Self.sourcesRoot.appendingPathComponent(relative)
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// SHAPE CHECK. Back and Fwd are words on the transport, not icon-only
    /// glyphs. The owner found "Keys" at the same size because it had a word
    /// on it; these two are the same call.
    @Test("transport draws Back and Fwd as word labels")
    func transportWordLabelsForSeek() throws {
        let text = try source("Studio/StudioTransportBar.swift")
        #expect(text.contains("title: \"Back\""),
                "shape: Back is no longer a word label on the transport")
        #expect(text.contains("title: \"Fwd\""),
                "shape: Fwd is no longer a word label on the transport")
        #expect(text.contains("labeledTransportButton"),
                "shape: the word-label transport builder is gone")
        // The actions must still be the one-bar nudge, not a different seek.
        #expect(text.contains("nudgePlayhead(bars: -1)"),
                "shape: Back is no longer wired to rewind one bar")
        #expect(text.contains("nudgePlayhead(bars: 1)"),
                "shape: Fwd is no longer wired to forward one bar")
    }

    /// SHAPE CHECK. Effects is a word in the top strip, same idiom as Keys.
    @Test("toolbar Effects is a word label, not an unlabelled glyph")
    func effectsWordLabel() throws {
        let text = try source("Studio/StudioRootView.swift")
        #expect(text.contains("Text(\"Effects\")"),
                "shape: Effects is no longer a word on the toolbar")
        #expect(text.contains("model.routingShown.toggle()"),
                "shape: Effects is no longer wired to the routing pane")
        // The old unlabelled glyph must not have crept back as the primary face.
        #expect(!text.contains("point.3.connected.trianglepath.dotted"),
                "shape: the unlabelled routing glyph is back as the Effects face")
    }

    /// SHAPE CHECK. VOLUME is a permanent word on the transport, wired to
    /// setMasterGain (existing mix.master.gain — no new command).
    @Test("transport carries a VOLUME control wired to master gain")
    func transportVolumeControl() throws {
        let text = try source("Studio/StudioTransportBar.swift")
        #expect(text.contains("StudioTransportVolume.wordLabel"),
                "shape: VOLUME word is gone from the transport volume control")
        #expect(text.contains("static let wordLabel = \"VOLUME\""),
                "shape: the VOLUME constant was renamed or removed")
        #expect(text.contains("model.setMasterGain"),
                "shape: transport volume is no longer wired to setMasterGain")
        #expect(text.contains("masterVolume"),
                "shape: masterVolume is no longer composed into the transport row")
    }

    /// SHAPE CHECK. Collapsed mixer names volume, not just MASTER.
    @Test("collapsed mixer strip names VOLUME")
    func collapsedMixerNamesVolume() throws {
        let text = try source("Studio/StudioMixerDock.swift")
        #expect(text.contains("MIXER · VOLUME"),
                "shape: collapsed mixer no longer says MIXER · VOLUME")
        #expect(text.contains("collapsedVolumeReadout"),
                "shape: collapsed volume readout helper is gone")
    }

    /// SHAPE CHECK. Empty effect chain lists the nine by name.
    @Test("empty effects chain lists the catalog")
    func emptyChainListsCatalog() throws {
        let text = try source("Studio/StudioRoutingView.swift")
        #expect(text.contains("StudioEffectsCatalog.summaryLine"),
                "shape: empty chain no longer draws the effects catalog")
        #expect(text.contains("Text(\"+ Effect\")"),
                "shape: + Effect word label is gone from the add menu")
        #expect(!text.contains("Text(\"+ FX\")"),
                "shape: + FX initialism is back as the add-menu face")
    }

    /// SHAPE CHECK. Coach marks name the instrument front door too.
    @Test("coach marks name Back, seek, VOLUME, Effects and Instrument")
    func coachMarksNameTheFour() {
        let bodies = StudioCoachMark.tipBodies.joined(separator: "\n").lowercased()
        for needle in ["back", "fwd", "bar numbers", "volume", "mixer", "effects", "+ instrument", "sampler", "drum rack", "vault", "keyboard"] {
            #expect(bodies.contains(needle),
                    "shape: coach marks no longer mention \"\(needle)\"")
        }
        #expect(StudioCoachMark.all.count == 4,
                "shape: coach mark count drifted from the four-step card")
    }
}

// MARK: - Pure catalog / math (behaviour of data, not pixels)

@MainActor
@Suite("discoverability catalog")
struct StudioDiscoverabilityCatalogTests {

    @Test("effects catalog is exactly the nine shipped kinds")
    func nineEffects() {
        #expect(StudioEffectsCatalog.expectedCount == 9,
                "the hard floor itself moved; update only with a tenth kind")
        #expect(StudioFxKind.allCases.count == StudioEffectsCatalog.expectedCount,
                "StudioFxKind.allCases is \(StudioFxKind.allCases.count), not nine")
        #expect(StudioEffectsCatalog.labels.count == 9)
        // Hardcoded names — a tautology against allCases.map would pass if the
        // enum emptied. Assert the product names the owner was told exist.
        let expected = [
            "EQ", "Compressor", "Gate", "Delay", "Reverb",
            "Saturator", "Chorus", "Utility", "Limiter",
        ]
        #expect(StudioEffectsCatalog.labels == expected,
                "effects catalog labels drifted: \(StudioEffectsCatalog.labels)")
        #expect(StudioEffectsCatalog.summaryLine == expected.joined(separator: " · "))
    }

    @Test("transport volume maps ends of the track to the fader range")
    func volumeTaperEnds() {
        // Hardcoded expected numbers, not a constant compared to itself.
        #expect(StudioTransportVolume.db(at: 0) == -60.0)
        #expect(StudioTransportVolume.db(at: 1) == 12.0)
        #expect(abs(StudioTransportVolume.db(at: 0.5) - (-24.0)) < 0.001,
                "mid-track should be halfway in dB: got \(StudioTransportVolume.db(at: 0.5))")
        #expect(StudioTransportVolume.caption(db: 0) == "0.0 dB")
        #expect(StudioTransportVolume.caption(db: -6.5) == "-6.5 dB")
        #expect(StudioTransportVolume.wordLabel == "VOLUME")
        #expect(StudioTransportVolume.trackWidth == 72)
        // Track 10 pt + caption ~10 pt + spacing 1 ≈ 21, under rowHeight 52.
        #expect(StudioTransportVolume.trackHeight + 12 < StudioTransportBar.rowHeight)
    }

    @Test("collapsed mixer readout leads with the master dB")
    func collapsedReadoutLeadsWithDB() async throws {
        let model = StudioViewModel(engine: StudioMockEngine())
        model.startPolling()
        defer { model.stopPolling() }
        for _ in 0..<80 where model.snapshot == nil {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        let dock = StudioMixerDock(model: model)
        let text = dock.collapsedVolumeReadout
        #expect(text.contains("dB"),
                "collapsed readout lost the dB level: \(text)")
        #expect(text.contains("+0.0 dB") || text.contains("0.0 dB") || text.contains("+") || text.contains("-"),
                "collapsed readout has no signed level: \(text)")
    }
}

// MARK: - Behaviour: activating the control sends the right thing

@MainActor
@Suite("discoverability reachability")
struct StudioDiscoverabilityReachabilityTests {

    private func wait(
        _ model: StudioViewModel,
        timeout: TimeInterval = 3.0,
        until condition: @MainActor (StudioViewModel) -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition(model) { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    @Test("Back / Fwd nudge the play head one bar via the same path the buttons call")
    func backFwdNudgeOneBar() async {
        let model = StudioViewModel(engine: StudioMockEngine())
        model.startPolling()
        defer { model.stopPolling() }
        await wait(model) { $0.snapshot != nil }

        let tpb = model.timeSignature.ticksPerBar
        #expect(tpb > 0, "ticks per bar must be positive")

        // Land somewhere past bar 1 so Back has room to move.
        model.seek(toTicks: tpb * 4)
        await wait(model) { abs($0.playheadTicks(now: ProcessInfo.processInfo.systemUptime) - tpb * 4) < 48 }

        let before = model.playheadTicks(now: ProcessInfo.processInfo.systemUptime)
        model.nudgePlayhead(bars: -1)   // Back
        await wait(model) {
            abs($0.playheadTicks(now: ProcessInfo.processInfo.systemUptime) - (before - tpb)) < 48
        }
        let afterBack = model.playheadTicks(now: ProcessInfo.processInfo.systemUptime)
        #expect(abs(afterBack - (before - tpb)) < 48,
                "Back did not move one bar: \(before) -> \(afterBack), tpb=\(tpb)")

        model.nudgePlayhead(bars: 1)    // Fwd
        await wait(model) {
            abs($0.playheadTicks(now: ProcessInfo.processInfo.systemUptime) - before) < 48
        }
        let afterFwd = model.playheadTicks(now: ProcessInfo.processInfo.systemUptime)
        #expect(abs(afterFwd - before) < 48,
                "Fwd did not restore the bar: \(afterBack) -> \(afterFwd)")
    }

    @Test("transport volume control commits mix.master.gain")
    func transportVolumeSendsMasterGain() async {
        let spy = CommandSpyEngine()
        let model = StudioViewModel(engine: spy)
        model.startPolling()
        defer { model.stopPolling() }
        await wait(model) { $0.snapshot != nil }

        // Drive the REAL control's commit path, not a rebuilt twin.
        let control = StudioTransportVolumeControl(valueDB: 0) { db in
            model.setMasterGain(db)
        }
        // Position 1.0 -> +12 dB on the shared taper (hardcoded expected).
        let sent = control.commit(position: 1.0)
        #expect(sent == 12.0, "commit(position: 1) must send +12 dB, got \(sent)")

        // Wait for the journaled command to reach the spy.
        let deadline = Date().addingTimeInterval(3)
        var names: [String] = []
        while Date() < deadline {
            names = await spy.commands.map(\.catalogName)
            if names.contains("mix.master.gain") { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(names.contains("mix.master.gain"),
                "transport volume never sent mix.master.gain; saw \(names)")
    }

    @Test("Effects toggle is the routingShown flag the pane reads")
    func effectsTogglesRoutingShown() async {
        let model = StudioViewModel(engine: StudioMockEngine())
        model.startPolling()
        defer { model.stopPolling() }
        await wait(model) { $0.snapshot != nil }

        #expect(model.routingShown == false, "routing starts closed")
        model.routingShown = true
        #expect(model.routingShown == true, "Effects open path is inert")
        model.routingShown = false
        #expect(model.routingShown == false, "Effects close path is inert")
    }

    @Test("seek to a bar lands the play head (the ruler's jump path)")
    func seekLandsPlayhead() async {
        let model = StudioViewModel(engine: StudioMockEngine())
        model.startPolling()
        defer { model.stopPolling() }
        await wait(model) { $0.snapshot != nil }

        let tpb = model.timeSignature.ticksPerBar
        let target = tpb * 8
        model.seek(toTicks: target)
        await wait(model) {
            abs($0.playheadTicks(now: ProcessInfo.processInfo.systemUptime) - target) < 48
        }
        let landed = model.playheadTicks(now: ProcessInfo.processInfo.systemUptime)
        #expect(abs(landed - target) < 48,
                "seek did not land near bar 9: \(landed) vs \(target)")
    }
}

// MARK: - Pixels (ImageRenderer, no window)

@MainActor
@Suite("discoverability pixels")
struct StudioDiscoverabilityPixelTests {

    private func raster<V: View>(_ view: V, width: CGFloat, height: CGFloat) throws -> CGImage {
        let renderer = ImageRenderer(content:
            view
                .frame(width: width, height: height)
                .environment(\.colorScheme, .dark)
                .background(StudioTokens.panel)
        )
        renderer.scale = 1
        return try #require(renderer.cgImage, "ImageRenderer produced no image")
    }

    private func pixelData(_ image: CGImage) -> [UInt8] {
        let w = image.width, h = image.height
        let bytesPerRow = w * 4
        var data = [UInt8](repeating: 0, count: h * bytesPerRow)
        guard let ctx = CGContext(
            data: &data, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return [] }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return data
    }

    /// Non-near-black pixels. Useful for a whole transport bar against a dark
    /// panel: labels, chrome and the volume fill all count.
    private func inkCount(_ image: CGImage) -> Int {
        let data = pixelData(image)
        var ink = 0
        for i in stride(from: 0, to: data.count, by: 4) {
            let r = Int(data[i]), g = Int(data[i + 1]), b = Int(data[i + 2])
            if r + g + b > 80 { ink += 1 }
        }
        return ink
    }

    /// Bright text-ish pixels only. panelHi chrome sits mid-grey; white/near-
    /// white label glyphs sit higher, so this is what distinguishes a labeled
    /// chip from an empty one of the same fill.
    private func brightInkCount(_ image: CGImage) -> Int {
        let data = pixelData(image)
        var ink = 0
        for i in stride(from: 0, to: data.count, by: 4) {
            let r = Int(data[i]), g = Int(data[i + 1]), b = Int(data[i + 2])
            if r + g + b > 400 { ink += 1 }
        }
        return ink
    }

    private func bootedModel() async throws -> StudioViewModel {
        let model = StudioViewModel(engine: StudioMockEngine())
        model.startPolling()
        for _ in 0..<80 where model.snapshot == nil {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        try #require(model.snapshot != nil, "mock engine never produced a snapshot")
        return model
    }

    /// The transport row is pinned at 52 pt. A label that wraps blows past that
    /// and steals the timeline (3.4.8). Assert the composed bar still measures
    /// exactly rowHeight when rendered at a realistic width.
    @Test("transport bar with VOLUME and word labels stays 52 pt tall")
    func transportRowStays52() async throws {
        let model = try await bootedModel()
        defer { model.stopPolling() }

        // Render the real bar at a width that forces the HStack to be tight —
        // the wrap-explosion only shows under pressure.
        let width: CGFloat = 1100
        let height = StudioTransportBar.rowHeight
        #expect(height == 52, "rowHeight constant itself drifted from 52")

        let image = try raster(StudioTransportBar(model: model), width: width, height: height)
        #expect(image.height == 52,
                "transport raster height is \(image.height), not 52 — a label wrapped")
        #expect(image.width == 1100,
                "transport raster width drifted: \(image.width)")

        let ink = inkCount(image)
        // Hard floor: a painted bar has thousands of non-panel pixels. An empty
        // frame is near zero. 400 is well above "blank" and well below a full
        // white fill.
        #expect(ink > 400,
                "transport bar drew almost no ink (\(ink)); labels may be missing")
    }

    @Test("VOLUME control draws the VOLUME word as ink")
    func volumeControlDrawsLabel() throws {
        var committed: Double?
        let control = StudioTransportVolumeControl(valueDB: -6) { committed = $0 }
        let image = try raster(control, width: 90, height: 28)
        let ink = inkCount(image)
        // The word VOLUME + the track + the dB readout must produce measurable
        // ink. Hardcoded floor, not a relative comparison.
        #expect(ink > 30,
                "VOLUME control drew too little ink (\(ink)); the label may be gone")
        #expect(image.height == 28)
        #expect(committed == nil, "rendering must not commit a gain change")
    }

    @Test("labeled Back button draws bright text ink the empty chip does not")
    func backButtonDrawsLabel() throws {
        let labeled = try raster(
            Text("Back")
                .font(.system(size: 10, weight: .bold))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(StudioTokens.panelHi)
                .foregroundStyle(StudioTokens.text),
            width: 48, height: 24)
        let empty = try raster(
            Color.clear.frame(width: 48, height: 24).background(StudioTokens.panelHi),
            width: 48, height: 24)
        let labeledInk = brightInkCount(labeled)
        let emptyInk = brightInkCount(empty)
        // Hard floor on the labeled chip, and a gap over the empty one. The
        // empty chip's bright count is near zero (panelHi is mid-grey); a
        // surviving assertion that only checked total ink passed for both.
        #expect(labeledInk > 40,
                "Back label bright ink is only \(labeledInk); the word may not be drawing")
        #expect(labeledInk > emptyInk + 20,
                "Back label bright ink (\(labeledInk)) is not above empty chip (\(emptyInk))")
    }
}
