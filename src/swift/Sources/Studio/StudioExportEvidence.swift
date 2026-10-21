import SwiftUI
import AppKit

// MARK: - L13 evidence renderer
//
// Renders the export + provenance dialog to a PNG off-screen via ImageRenderer
// (deterministic, no window, no screenshot flakiness), driven by the same
// StudioViewModel + StudioMockEngine the app runs. The provenance card reads the
// real mock snapshot (its generated/imported split), so the render is faithful.
// Invoked from the evidence test (gated on L13_EVIDENCE).

@MainActor
enum StudioExportEvidence {

    @discardableResult
    static func render(model: StudioViewModel, to dir: String) -> [String] {
        var written: [String] = []
        // The dialog content without the outer ScrollView/sheet chrome, so
        // ImageRenderer lays it out at its ideal size (a ScrollView renders
        // empty through ImageRenderer). This is the same body the sheet shows.
        let view = StudioExportEvidenceView(model: model)
        let path = dir + "/l13-export-dialog.png"
        if write(view, to: path) { written.append(path) }
        return written
    }

    private static func write<V: View>(_ view: V, to path: String) -> Bool {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, .dark))
        renderer.scale = 2
        guard let cg = renderer.cgImage else {
            NSLog("L13 evidence: ImageRenderer returned nil for \(path)")
            return false
        }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }
}

/// The export dialog laid out for the evidence render: the real dialog controls
/// + provenance card, without the sheet's ScrollView (which renders empty
/// through ImageRenderer). Pre-export state (the screenshot the acceptance asks
/// for): format/scope/loudness pickers, the manifest toggle, the provenance
/// split, and the action row.
private struct StudioExportEvidenceView: View {
    @ObservedObject var model: StudioViewModel
    @State private var isPresented = true

    var body: some View {
        // The real dialog, flat (scrolls:false) so the whole body renders through
        // ImageRenderer (a ScrollView renders empty off-screen).
        StudioExportDialog(model: model, isPresented: $isPresented, scrolls: false)
            .fixedSize()
            .background(StudioTokens.panel)
    }
}
