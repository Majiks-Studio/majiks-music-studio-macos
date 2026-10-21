import SwiftUI
import AppKit

// MARK: - L12 evidence renderer
//
// Renders the mixer dock + an automation lane to PNGs off-screen via
// ImageRenderer (deterministic, no window, no screenshot flakiness), driven by
// the same StudioViewModel + StudioMockEngine the app runs. Both surfaces are
// pure SwiftUI (the automation lane uses the SAME shared renderer the live
// canvas does), so the render is faithful. Invoked from the evidence test.

@MainActor
enum StudioMixerEvidence {

    /// Render the composed image + a dock close-up. Returns the paths written.
    @discardableResult
    static func render(model: StudioViewModel, to dir: String) -> [String] {
        guard let snap = model.snapshot else { return [] }
        model.mixerCollapsed = false

        let autoTrack = snap.tracks.first(where: { !$0.volumeAutomation.isEmpty }) ?? snap.tracks.last!
        let maxTick = max(Int64(1), autoTrack.volumeAutomation.map(\.positionTicks).max() ?? snap.lengthTicks)
        let pxPerTick = 1000.0 / CGFloat(maxTick) * 0.82

        var written: [String] = []
        let combined = StudioMixerEvidenceView(
            model: model, tracks: snap.tracks, master: snap.master,
            autoTrack: autoTrack, pxPerTick: pxPerTick)
        if write(combined, to: dir + "/l12-mixer-automation.png") { written.append(dir + "/l12-mixer-automation.png") }

        let dock = StudioMixerStripsRow(model: model, tracks: snap.tracks, master: snap.master)
            .padding(14).background(StudioTokens.panel)
        if write(dock, to: dir + "/l12-mixer-dock.png") { written.append(dir + "/l12-mixer-dock.png") }

        return written
    }

    private static func write<V: View>(_ view: V, to path: String) -> Bool {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, .dark))
        renderer.scale = 2
        guard let cg = renderer.cgImage else {
            NSLog("L12 evidence: ImageRenderer returned nil for \(path)")
            return false
        }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }
}

/// A plain (non-scrolling) row of the real mixer strips + master, so the strips
/// render through ImageRenderer (a horizontal ScrollView renders empty).
private struct StudioMixerStripsRow: View {
    @ObservedObject var model: StudioViewModel
    let tracks: [StudioTrackSnapshot]
    let master: StudioMasterSnapshot

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ForEach(tracks) { StudioMixerStrip(model: model, track: $0) }
            StudioMasterStrip(model: model, master: master)
        }
    }
}

/// One automation lane strip (header + the shared lane renderer) stacked over
/// the mixer strips, so a single image shows both L12 surfaces.
private struct StudioMixerEvidenceView: View {
    @ObservedObject var model: StudioViewModel
    let tracks: [StudioTrackSnapshot]
    let master: StudioMasterSnapshot
    let autoTrack: StudioTrackSnapshot
    let pxPerTick: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 2).fill(StudioTokens.stemColor(autoTrack.kind))
                            .frame(width: 7, height: 7)
                        Text(autoTrack.name).font(.system(size: 11, weight: .bold)).foregroundStyle(StudioTokens.text)
                    }
                    Text("volume automation").font(.system(size: 9)).foregroundStyle(StudioTokens.dim)
                }
                .frame(width: 150, alignment: .leading)
                .padding(.leading, 12)
                StudioAutomationLanePreview(track: autoTrack, target: .volume, pxPerTick: pxPerTick)
            }
            .frame(height: StudioTokens.automationLaneHeight + 24)
            .background(StudioTokens.panel)
            .overlay(alignment: .bottom) { Rectangle().fill(StudioTokens.stroke).frame(height: 1) }

            HStack(spacing: 8) {
                Text("MIXER").font(.system(size: 9, weight: .bold)).kerning(1).foregroundStyle(StudioTokens.dim)
                Spacer()
            }
            .padding(.horizontal, 14).padding(.vertical, 6)

            StudioMixerStripsRow(model: model, tracks: tracks, master: master)
                .padding(.horizontal, 14).padding(.bottom, 12)
        }
        .background(StudioTokens.panel)
    }
}
