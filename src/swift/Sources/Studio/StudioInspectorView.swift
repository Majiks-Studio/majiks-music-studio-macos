import SwiftUI

// MARK: - Inspector (right rail, contextual)
//
// Empty selection: project overview. Clip selected: lineage placeholder.
// Region selected: revise placeholder. Panels are placeholders by design in
// L5: lineage data and revise logic wire in later lanes; layout, tokens, and
// copy are final.

struct StudioInspectorView: View {
    @ObservedObject var model: StudioViewModel

    /// The rail's width, owned by the shell (StudioRootView) because the user
    /// drags it there. Defaulted to the shipped token.
    var width: CGFloat = StudioTokens.inspectorWidth

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let region = model.selection.region {
                    revisePanel(region: region)
                } else if let clip = selectedClip() {
                    lineagePanel(clip: clip.0, track: clip.1)
                } else {
                    projectPanel
                }
            }
            .padding(12)
        }
        // Fixed across the drag axis, flexible down it — explicitly, on both
        // axes, for the reason the transport bar documents.
        .frame(width: width)
        .frame(maxHeight: .infinity)
        .background(StudioTokens.panel)
        .overlay(alignment: .leading) {
            Rectangle().fill(StudioTokens.strokeSoft).frame(width: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Inspector")
    }

    private func selectedClip() -> (StudioClipSnapshot, StudioTrackSnapshot)? {
        guard let snapshot = model.snapshot,
              let clipID = model.selection.clipIDs.first else { return nil }
        for track in snapshot.tracks {
            if let clip = track.clips.first(where: { $0.id == clipID }) {
                return (clip, track)
            }
        }
        return nil
    }

    // MARK: Shared bits

    private func panelTitle(_ title: String, hint: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold))
                .kerning(1)
                .foregroundStyle(StudioTokens.faint)
            Spacer()
            if let hint {
                Text(hint)
                    .font(.system(size: 9))
                    .foregroundStyle(StudioTokens.faint)
            }
        }
    }

    private func card(@ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            content()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StudioTokens.panelHi)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(StudioTokens.stroke, lineWidth: 1))
    }

    private func kv(_ key: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(key)
                .font(.system(size: 11))
                .foregroundStyle(StudioTokens.dim)
            Spacer(minLength: 10)
            Text(value)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(StudioTokens.text)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(key)
        .accessibilityValue(value)
    }

    private func grayButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(StudioTokens.dim)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(StudioTokens.panelHi)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(StudioTokens.stroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func shimmerButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
        }
        .buttonStyle(.plain)
        .studioShimmerBackground(cornerRadius: 8)
    }

    private func stub(_ message: String) {
        ToastManager.shared.show(message, style: .info)
    }

    // MARK: Project panel (empty selection)

    @ViewBuilder
    private var projectPanel: some View {
        panelTitle("Project")
        card {
            kv("Name", model.snapshot?.name ?? "-")
            kv("Tempo", String(format: "%.1f BPM", model.snapshot?.tempoBPM ?? 0))
            kv("Key", model.snapshot?.key ?? "-")
            kv("Length", "\(model.snapshot?.lengthBars ?? 0) bars")
            kv("Tracks", "\(model.snapshot?.tracks.count ?? 0)")
        }
        panelTitle("Provenance")
        card {
            kv("Audio", model.snapshot?.provenanceSummary ?? "-")
            kv("Manifest", "builds on export")
        }
        Text("Select a clip for its lineage. Drag on the section ruler to select bars, then press R to revise.")
            .font(.system(size: 10.5))
            .foregroundStyle(StudioTokens.faint)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Lineage panel (clip selected)

    @ViewBuilder
    private func lineagePanel(clip: StudioClipSnapshot, track: StudioTrackSnapshot) -> some View {
        panelTitle("Clip: Lineage", hint: "\(track.name)")
        card {
            kv("Origin", clip.origin.label)
            switch clip.origin {
            case .generated:
                kv("Model", "wires in P2")
                kv("Seed", "wires in P2")
                kv("Engine", "wires in P2")
                kv("Journal", "wires in P2")
            case .authored, .recorded:
                // No file and no audio fingerprint to show for a note clip:
                // printing the engine's clip id under "File" is the same lie
                // "Imported" was. A recorded AUDIO clip has an asset, but its
                // fingerprint is a P2 wire-up like the generated case.
                kv("Journal", "wires in P2")
            case .imported:
                kv("File", clip.name)
                kv("Fingerprint", "wires in P2")
            }
            kv("Start", StudioTimelineMath.positionString(
                ticks: clip.startTicks, timeSignature: model.timeSignature,
                phaseAnchorTicks: model.phaseAnchorTicks))
            kv("Length", StudioTimelineMath.positionString(
                ticks: clip.lengthTicks, timeSignature: model.timeSignature))
        }
        if clip.generative {
            panelTitle("Lineage tree")
            card {
                Text("The full parent chain (prompt, separation, revisions) renders here when the journal read surface lands.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(StudioTokens.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                grayButton("Retake") {
                    stub("Retake wires into generation in a later build.")
                }
                .studioHelp("inspector.retake")
                shimmerButton("More like this") {
                    stub("Prompt prefill wires into generation in a later build.")
                }
                .studioHelp("inspector.moreLikeThis")
            }
        }
    }

    // MARK: Revise panel (region selected; drives the real gen + commit flow)

    @ViewBuilder
    private func revisePanel(region: StudioRegionSelection) -> some View {
        let bars = region.barRange(grid: model.barGrid)
        if let audition = model.audition {
            auditionPanel(audition: audition, bars: bars)
        } else {
            reviseSetupPanel(region: region, bars: bars)
        }
    }

    // The instruction + scope + variants form (before Generate).
    @ViewBuilder
    private func reviseSetupPanel(region: StudioRegionSelection, bars: ClosedRange<Int>) -> some View {
        panelTitle("Revise bars \(bars.lowerBound)-\(bars.upperBound)", hint: "esc to cancel")
        TextField("Describe the change", text: $model.reviseInstruction, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(StudioTokens.text)
            .lineLimit(2...4)
            .padding(8)
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .topLeading)
            .background(StudioTokens.bg)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(StudioTokens.purple.opacity(0.6), lineWidth: 1))
            .studioHelp("inspector.revise.instruction")
            .accessibilityLabel("Revise instruction")

        panelTitle("Scope")
        scopeChips
            .studioHelp("inspector.revise.scope")

        HStack {
            Text("Variants").font(.system(size: 11)).foregroundStyle(StudioTokens.dim)
            Spacer()
            Stepper(value: $model.reviseVariantCount, in: 1...8) {
                Text("\(model.reviseVariantCount)")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(StudioTokens.text)
            }
            .labelsHidden()
        }
        .padding(.vertical, 2)
        .studioHelp("inspector.revise.variants")

        if model.reviseScope.contains(.vocals) {
            Toggle(isOn: $model.reviseKeepLyrics) {
                Text("Keep lyrics").font(.system(size: 11)).foregroundStyle(StudioTokens.dim)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .studioHelp("inspector.revise.keepLyrics")
        }

        DisclosureGroup {
            HStack {
                Text("Seed").font(.system(size: 11)).foregroundStyle(StudioTokens.dim)
                Spacer()
                TextField("auto", text: $model.reviseSeedText)
                    .textFieldStyle(.plain).multilineTextAlignment(.trailing)
                    .font(.system(size: 11).monospacedDigit()).frame(width: 90)
                    .foregroundStyle(StudioTokens.text)
            }
            .studioHelp("inspector.revise.seed")
            HStack {
                Text("Crossfade").font(.system(size: 11)).foregroundStyle(StudioTokens.dim)
                Spacer()
                Text("\(Int(model.reviseCrossfadeMs)) ms")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit()).foregroundStyle(StudioTokens.text)
            }
            Slider(value: $model.reviseCrossfadeMs, in: 5...50, step: 5)
                .studioHelp("inspector.revise.crossfade")
        } label: {
            Text("Advanced").font(.system(size: 10, weight: .bold)).foregroundStyle(StudioTokens.faint)
        }
        .padding(.top, 2)

        HStack(spacing: 8) {
            grayButton("Cancel") { model.clearSelection() }
                .studioHelp("inspector.revise.cancel")
            shimmerButton(model.revising ? "Generating..." : "Generate \(model.reviseVariantCount) takes") {
                model.generateRevise()
            }
            .disabled(model.revising)
            .studioHelp("inspector.revise.generate")
        }
        Text("Unscoped stems stay untouched. Commit crossfades \(Int(model.reviseCrossfadeMs)) ms at both edges.")
            .font(.system(size: 10)).foregroundStyle(StudioTokens.faint)
            .fixedSize(horizontal: false, vertical: true)
    }

    // The audition + commit list (after Generate).
    @ViewBuilder
    private func auditionPanel(audition: StudioAuditionState, bars: ClosedRange<Int>) -> some View {
        panelTitle("Audition bars \(bars.lowerBound)-\(bars.upperBound)", hint: model.finalizing ? "finalizing" : "1-9 pick, A original")
        VStack(spacing: 5) {
            takeRow(label: "Original", key: "A", picked: audition.auditioningVariant == nil) {
                model.auditionOriginal()
            }
            ForEach(audition.variants) { variant in
                takeRow(
                    label: "Take \(variant.index + 1)",
                    key: "\(variant.index + 1)",
                    picked: audition.auditioningVariant == variant.index
                ) {
                    model.auditionVariant(variant.index)
                }
            }
        }
        // Per-stem take mixing (L10): pick a take per stem within the region.
        StudioPerStemMixView(model: model, audition: audition)
        HStack(spacing: 8) {
            grayButton("Discard") { model.discardAudition() }
                .studioHelp("inspector.audition.discard")
            shimmerButton("Commit") { model.commitAudition() }
                .studioHelp("inspector.audition.commit")
        }
        if model.finalizing {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Re-rendering the committed take at full quality.")
                    .font(.system(size: 10)).foregroundStyle(StudioTokens.faint)
            }
        } else {
            Text("Commit writes the take in place with a \(Int(model.reviseCrossfadeMs)) ms crossfade, as one undo step.")
                .font(.system(size: 10)).foregroundStyle(StudioTokens.faint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func takeRow(label: String, key: String, picked: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(key)
                    .font(.system(size: 10, weight: .bold).monospacedDigit())
                    .foregroundStyle(picked ? .white : StudioTokens.dim)
                    .frame(width: 18, height: 18)
                    .background(picked ? StudioTokens.purple : StudioTokens.panelHi)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                Text(label).font(.system(size: 12, weight: picked ? .bold : .regular))
                    .foregroundStyle(picked ? StudioTokens.text : StudioTokens.dim)
                Spacer()
                if picked { Image(systemName: "waveform").font(.system(size: 10)).foregroundStyle(StudioTokens.cyan) }
            }
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(picked ? StudioTokens.purple.opacity(0.14) : StudioTokens.panelHi)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(picked ? StudioTokens.purple : StudioTokens.stroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .studioHelp("inspector.audition.take")
        .accessibilityLabel("\(label), key \(key)")
        .accessibilityValue(picked ? "auditioning" : "")
    }

    private var scopeChips: some View {
        HStack(spacing: 6) {
            ForEach([StudioStemKind.vocals, .drums, .bass, .other], id: \.self) { kind in
                let on = model.reviseScope.contains(kind)
                Button {
                    if on { model.reviseScope.remove(kind) } else { model.reviseScope.insert(kind) }
                } label: {
                    Text(kind.rawValue.capitalized)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(on ? StudioTokens.text : StudioTokens.dim)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(on ? StudioTokens.stemColor(kind).opacity(0.22) : .clear)
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(
                            on ? StudioTokens.stemColor(kind) : StudioTokens.stroke, lineWidth: 1))
                }
                .buttonStyle(.plain)
                // help-exempt: the chip row carries one `inspector.revise.scope`
                // tooltip at its call site; a per-chip repeat of the same
                // sentence four times is noise, not help.
                .accessibilityLabel("\(kind.rawValue) scope")
                .accessibilityValue(on ? "in scope" : "out of scope")
            }
        }
    }
}
