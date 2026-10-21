import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Export dialog (L13)
//
// Master WAV/AAC, per-track stems, or the selected region, through the engine's
// offline bounce (the same graph as realtime). A loudness target on the master;
// an optional AI-disclosure provenance manifest travels with the audio. Publish
// reuses the existing majiks.online path (server-side cert minting, untouched).
//
// The dialog issues export.* commands through the same journaled command bus
// everything uses, so every export is auditable. The provenance PREVIEW is
// estimated from the snapshot; the exported manifest is the authoritative
// machine-readable AI disclosure the engine builds from the command journal.

struct StudioExportDialog: View {
    @ObservedObject var model: StudioViewModel
    @Binding var isPresented: Bool
    /// The live sheet scrolls; the off-screen evidence render lays the content
    /// out flat (a ScrollView renders empty through ImageRenderer).
    var scrolls: Bool = true

    @State private var scope: StudioExportScope = .master
    @State private var format: StudioExportFormat = .wav
    @State private var loudness: StudioLoudnessTarget = .streaming
    @State private var includeManifest = true
    @State private var folder: URL = StudioExportDialog.defaultFolder()
    @State private var busy = false
    @State private var outcome: StudioExportOutcome?

    private var preview: StudioProvenancePreview { .from(model.snapshot) }
    private var projectName: String { model.snapshot?.name ?? "Untitled" }
    private var loopRegion: ClosedRange<Int64>? { model.snapshot?.transport.loopRegion }
    /// Stems are 24-bit WAV only (they feed a DAW/mixer, not a player).
    private var formatLocked: Bool { scope == .stems }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(StudioTokens.strokeSoft)
            if scrolls {
                ScrollView { contentStack }
            } else {
                contentStack
            }
            Divider().overlay(StudioTokens.strokeSoft)
            footer
        }
        .frame(width: 460)
        .frame(maxHeight: 640)
        .background(StudioTokens.panel)
        .onChange(of: scope) { _, newScope in
            if newScope == .stems { format = .wav }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Export")
    }

    private var contentStack: some View {
        VStack(alignment: .leading, spacing: 18) {
            scopeSection
            formatSection
            if scope != .stems { loudnessSection }
            manifestSection
            provenanceCard
            destinationSection
            if let outcome { resultCard(outcome) }
        }
        .padding(18)
    }

    // MARK: header / footer

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Export")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(StudioTokens.text)
                Text(projectName)
                    .font(.system(size: 11))
                    .foregroundStyle(StudioTokens.dim)
            }
            Spacer()
            Button {
                isPresented = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(StudioTokens.dim)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                Task { await runManifestOnly() }
            } label: {
                Text("Manifest only")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(StudioTokens.text)
            }
            .buttonStyle(.plain)
            .disabled(busy)
            .help("Write just the AI-disclosure provenance manifest (no audio).")

            Spacer()

            Button {
                Task { await runPublish() }
            } label: {
                Label("Publish to majiks.online", systemImage: "square.and.arrow.up")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(StudioTokens.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(StudioTokens.stroke, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(busy)
            .help("Reuses the existing majiks.online publisher (certs minted server-side); the manifest travels with it.")

            Button {
                Task { await runExport() }
            } label: {
                HStack(spacing: 6) {
                    if busy { ProgressView().controlSize(.small) }
                    Text(busy ? "Exporting..." : "Export")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
            }
            .buttonStyle(.plain)
            .disabled(busy || (scope == .region && loopRegion == nil))
            .studioShimmerBackground(cornerRadius: 8)
            .accessibilityLabel("Export")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    // MARK: sections

    private var scopeSection: some View {
        field("What to export") {
            StudioSegmented(options: StudioExportScope.allCases, selection: $scope) { $0.label }
            if scope == .region {
                if let bars = barRange() {
                    Text("Region: bar \(bars.lowerBound) to bar \(bars.upperBound)")
                        .font(.system(size: 11)).foregroundStyle(StudioTokens.dim)
                } else {
                    // This line used to point at a control that did not exist:
                    // "Set a loop region on the ruler" was true of the engine
                    // command and false of every surface a person could touch.
                    // It now names the gesture that is actually there — the
                    // loop strip under the bar numbers — and the button that
                    // does the same thing without aiming.
                    Text("No loop set. Drag in the loop strip just under the bar numbers, or press the Loop button in the transport bar, then come back here.")
                        .font(.system(size: 11)).foregroundStyle(StudioTokens.warn)
                }
            }
        }
    }

    private var formatSection: some View {
        field("Format") {
            StudioSegmented(options: StudioExportFormat.allCases, selection: $format, enabled: !formatLocked) { $0.label }
            if formatLocked {
                Text("Stems export as 24-bit WAV.")
                    .font(.system(size: 11)).foregroundStyle(StudioTokens.dim)
            }
        }
    }

    private var loudnessSection: some View {
        field("Loudness") {
            StudioSegmented(options: StudioLoudnessTarget.allCases, selection: $loudness) { $0.shortLabel }
            Text(loudnessHelp)
                .font(.system(size: 11)).foregroundStyle(StudioTokens.dim)
        }
    }

    private var loudnessHelp: String {
        if let lufs = loudness.targetLUFS {
            return String(format: "Normalized to %.0f LUFS integrated (EBU R128), measured on the bounce.", lufs)
        }
        return "No normalization: the master is written as mixed."
    }

    private var manifestSection: some View {
        Button {
            includeManifest.toggle()
        } label: {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Include provenance manifest")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(StudioTokens.text)
                    Text("Machine-readable AI disclosure (EU AI Act Art. 50), written next to the audio.")
                        .font(.system(size: 11)).foregroundStyle(StudioTokens.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                StudioSwitch(on: includeManifest)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Include provenance manifest")
        .accessibilityValue(includeManifest ? "on" : "off")
    }

    private var provenanceCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("PROVENANCE")
                    .font(.system(size: 9, weight: .bold)).kerning(0.8)
                    .foregroundStyle(StudioTokens.faint)
                Spacer()
                Text(preview.summaryLine)
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(StudioTokens.text)
            }
            // Generated vs imported bar.
            GeometryReader { geo in
                HStack(spacing: 0) {
                    Rectangle().fill(StudioTokens.purple)
                        .frame(width: geo.size.width * CGFloat(preview.generatedPct) / 100.0)
                    Rectangle().fill(StudioTokens.clipBase)
                }
                .clipShape(Capsule())
            }
            .frame(height: 8)
            // One entry per bucket that actually has clips in it. Printing a
            // fixed "generated / imported" pair meant a note clip written in
            // the roll was counted under "imported", contradicting the manifest
            // this dialog is about to write.
            HStack(spacing: 14) {
                ForEach(preview.buckets.filter { $0.clips > 0 }) { bucket in
                    legend(
                        color: bucket.origin == .generated ? StudioTokens.purple : StudioTokens.clipBase,
                        label: "\(bucket.clips) \(bucket.origin.rawValue)")
                }
            }
            if preview.hasGeneratedContent {
                Text("This export contains AI-generated audio. The manifest carries the per-clip lineage (prompt, model, seed) and the machine-readable disclosure.")
                    .font(.system(size: 10)).foregroundStyle(StudioTokens.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("From the session's command journal — the same classification the exported manifest carries.")
                .font(.system(size: 9)).foregroundStyle(StudioTokens.faint)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(StudioTokens.panelHi))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(StudioTokens.stroke, lineWidth: 1))
    }

    private var destinationSection: some View {
        field("Destination") {
            HStack(spacing: 8) {
                Text(destinationLabel)
                    .font(.system(size: 11).monospaced())
                    .foregroundStyle(StudioTokens.text)
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Choose...") { chooseFolder() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(StudioTokens.purple)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).fill(StudioTokens.panelHi))
        }
    }

    private func resultCard(_ o: StudioExportOutcome) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: o.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(o.ok ? StudioTokens.good : StudioTokens.bad)
                Text(o.ok ? "Exported" : "Export failed")
                    .font(.system(size: 12, weight: .bold)).foregroundStyle(StudioTokens.text)
            }
            if let p = o.outputPath {
                Text(p).font(.system(size: 10).monospaced())
                    .foregroundStyle(StudioTokens.dim).lineLimit(1).truncationMode(.middle)
            }
            if let l = o.loudness, let after = l.integratedLufsAfter {
                Text(String(format: "Loudness: %.1f LUFS (target %@, off %.2f LU)", after, l.target, l.errorLU))
                    .font(.system(size: 10)).foregroundStyle(StudioTokens.dim)
            }
            if let s = o.provenanceSummary {
                Text("Provenance: \(s)").font(.system(size: 10)).foregroundStyle(StudioTokens.dim)
            }
            if let mp = o.manifestPath {
                Text("Manifest: \(mp)").font(.system(size: 10).monospaced())
                    .foregroundStyle(StudioTokens.dim).lineLimit(1).truncationMode(.middle)
            }
            if let m = o.message, !o.ok {
                Text(m).font(.system(size: 10)).foregroundStyle(StudioTokens.bad)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(StudioTokens.panelHi))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(o.ok ? StudioTokens.good.opacity(0.4) : StudioTokens.bad.opacity(0.4), lineWidth: 1))
    }

    // MARK: helpers

    private func field<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .bold)).kerning(0.8)
                .foregroundStyle(StudioTokens.faint)
            content()
        }
    }

    private func legend(color: Color, label: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 9, height: 9)
            Text(label).font(.system(size: 10)).foregroundStyle(StudioTokens.dim)
        }
    }

    private var destinationLabel: String {
        resolvedOutput().path
    }

    /// The bar numbers the RULER is showing.
    ///
    /// This used to divide by `ticksPerBar` and add one, which is a second
    /// formula for something the app already has exactly one of. Everything
    /// else numbers bars through `StudioBarGrid.barNumber(at:)`, measured from
    /// the phase anchor — including the ruler labels the user is reading while
    /// this sheet is open. `project.setPhaseAnchor` is reachable from ⌘K as
    /// "Make bar 1 start at the play head", and one use of it made this line
    /// say "bar 5 to bar 9" over a ruler reading 3 to 7.
    /// Internal, not private, so `StudioExportNamingTests` drives the REAL
    /// dialog's numbering rather than a copy of it that happens to agree.
    func barRange() -> ClosedRange<Int>? {
        guard let r = loopRegion else { return nil }
        let grid = model.barGrid
        let first = grid.barNumber(at: r.lowerBound)
        // The region's LAST bar, not the one after it: a loop that ends on the
        // downbeat of bar 9 covers bars 5 to 8.
        let last = max(first, grid.barNumber(at: max(r.lowerBound, r.upperBound - 1)))
        return first...last
    }

    /// Internal for the same reason `barRange()` is: the file this writes to
    /// is the one thing about an export a test can check without a bounce.
    func resolvedOutput() -> (path: String, isDir: Bool) {
        let name = StudioExportNaming.outputName(
            project: sanitized(projectName), scope: scope, format: format, bars: barRange())
        return (folder.appendingPathComponent(name).path, scope == .stems)
    }

    private func sanitized(_ name: String) -> String {
        let cleaned = name.map { ch -> Character in
            (ch.isLetter || ch.isNumber || ch == "-" || ch == "_" || ch == " ") ? ch : "_"
        }
        let s = String(cleaned).trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? "Untitled" : s
    }

    // MARK: actions

    @MainActor
    private func runExport() async {
        busy = true
        outcome = nil
        let out = resolvedOutput()
        ensureFolder()
        var req = StudioExportRequest(
            scope: scope, format: format, loudness: loudness,
            includeManifest: includeManifest, outputPath: out.path)
        if scope == .region, let r = loopRegion {
            req.regionStartTicks = r.lowerBound
            req.regionEndTicks = r.upperBound
        }
        let result = await model.engine.exportAudio(req)
        outcome = result
        busy = false
    }

    @MainActor
    private func runManifestOnly() async {
        busy = true
        outcome = nil
        ensureFolder()
        let path = folder.appendingPathComponent("\(sanitized(projectName)).manifest.json").path
        outcome = await model.engine.writeManifest(outputPath: path)
        busy = false
    }

    @MainActor
    private func runPublish() async {
        busy = true
        outcome = nil
        let result = await model.engine.publishToMajiks(
            StudioPublishRequest(title: projectName, includeManifest: includeManifest))
        outcome = StudioExportOutcome(ok: result.ok, message: result.message,
            outputPath: result.ok ? "Published to majiks.online" : nil)
        busy = false
    }

    private func ensureFolder() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    private func chooseFolder() {
        #if canImport(AppKit)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = folder
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            folder = url
        }
        #endif
    }

    static func defaultFolder() -> URL {
        let base = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("Majiks Studio Exports", isDirectory: true)
    }
}

// MARK: - What an export is called
//
// ⚠️ MASTER AND REGION USED TO WRITE THE SAME FILE.
//
// Both scopes returned `<folder>/<Project>.<ext>`. `write_wav_i24` opens with
// `hound::WavWriter::create` -> `File::create`, which TRUNCATES, and nothing on
// either side of the FFI checks for an existing file. So: export the master,
// then export the chorus as "Selected region", and the master is gone. No
// warning, no second file, nothing to undo — the bounce is not journaled work,
// it is bytes on a disk.
//
// The dialog actively concealed it, too: the Destination line is computed from
// this same function, so it showed the IDENTICAL path for both scopes. A person
// checking before they pressed the button would have seen nothing wrong.
//
// The engine's own export test asserts that the output path exists; it never
// asserts that two different exports produce two different paths, which is why
// this survived a green suite.
//
// A separate type rather than a method on the dialog because a file name is the
// one part of an export a test can check without a bounce, a device, or a disk.

enum StudioExportNaming {

    /// The file (or, for stems, the folder) a scope writes to, inside the
    /// chosen destination.
    ///
    /// - Parameters:
    ///   - project: the project name, ALREADY sanitised.
    ///   - bars: the region's bar range, for the region scope. Nil falls back
    ///     to a bare "Region" suffix — still distinct from the master, which is
    ///     the property that matters, and still not the master's name.
    static func outputName(
        project: String, scope: StudioExportScope, format: StudioExportFormat,
        bars: ClosedRange<Int>?
    ) -> String {
        switch scope {
        case .master:
            return "\(project).\(format.fileExtension)"
        case .region:
            return "\(project) \(regionSuffix(bars)).\(format.fileExtension)"
        case .stems:
            return "\(project) Stems"
        }
    }

    /// "bars 5-8", or "bar 5" when the region is one bar long. Named in the
    /// user's own units, so the file in Finder matches the line the dialog
    /// printed above the button.
    static func regionSuffix(_ bars: ClosedRange<Int>?) -> String {
        guard let bars else { return "Region" }
        return bars.lowerBound == bars.upperBound
            ? "bar \(bars.lowerBound)"
            : "bars \(bars.lowerBound)-\(bars.upperBound)"
    }
}

// MARK: - Custom controls
//
// Pure-SwiftUI segmented selector + switch, matching the Majiks dark theme (the
// native NSSegmentedControl / NSSwitch clash with it) and, unlike the AppKit
// controls, they render faithfully through ImageRenderer (the evidence path).

struct StudioSegmented<T: Identifiable & Equatable>: View {
    let options: [T]
    @Binding var selection: T
    var enabled: Bool = true
    let label: (T) -> String

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options) { opt in
                let selected = opt == selection
                Button {
                    if enabled { selection = opt }
                } label: {
                    Text(label(opt))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(selected ? .white : StudioTokens.text)
                        .lineLimit(1).minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7).padding(.horizontal, 4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? StudioTokens.purple : StudioTokens.panelHi))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? StudioTokens.purple : StudioTokens.stroke, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? [.isSelected] : [])
                .accessibilityLabel(label(opt))
            }
        }
        .opacity(enabled ? 1 : 0.45)
    }
}

struct StudioSwitch: View {
    let on: Bool
    var body: some View {
        Capsule()
            .fill(on ? StudioTokens.purple : StudioTokens.clipBase)
            .frame(width: 38, height: 22)
            .overlay(alignment: on ? .trailing : .leading) {
                Circle().fill(.white).frame(width: 16, height: 16).padding(3)
            }
            .overlay(Capsule().stroke(StudioTokens.stroke, lineWidth: 1))
            .animation(.easeInOut(duration: 0.15), value: on)
    }
}
