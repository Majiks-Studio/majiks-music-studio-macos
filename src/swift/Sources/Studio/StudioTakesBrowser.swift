import SwiftUI
import UniformTypeIdentifiers

// MARK: - Takes browser (L10): the left Browser "Takes" tab
//
// Lists every generative result in the project (revise / extend / layer /
// landed song), filterable by prompt / region / kind, each showing its lineage
// (prompt, seed, model, engine). Click to preview it in place; drag onto the
// timeline to use it on a clip; "More like this" re-rolls from its lineage.
// Landed-song provenance is filtered out of the auditionable list (the L8
// follow-up) but still reachable via the kind filter. Purge reclaims space.
//
// Reads engine.takes(...) and drives take.promote / take.auditionMix / purge,
// the SAME commands an agent uses, so the UI and an agent share one path.

struct StudioTakesBrowser: View {
    @ObservedObject var model: StudioViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            filterBar
            let items = model.filteredTakes()
            if items.isEmpty {
                emptyNote(model.takesBrowserItems.isEmpty
                    ? "Takes from Revise, Extend, and Add a Layer land here."
                    : "No takes match the filter.")
            } else {
                ForEach(items) { item in
                    takeRow(item)
                }
            }
            if model.takesBrowserItems.contains(where: { $0.auditionable }) {
                purgeButton
            }
        }
        .confirmationDialog(
            "Purge take audio?",
            isPresented: $model.purgeConfirmShown,
            titleVisibility: .visible
        ) {
            Button("Purge unused takes", role: .destructive) { model.purgeTakes() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Deletes the audio of un-committed takes to reclaim space. Their lineage stays. This cannot be undone.")
        }
    }

    // MARK: Filter bar

    @ViewBuilder
    private var filterBar: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 9)).foregroundStyle(StudioTokens.faint)
            TextField("Filter takes", text: $model.takesFilter.search)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(StudioTokens.text)
                .accessibilityLabel("Filter takes")
        }
        .padding(.horizontal, 7).padding(.vertical, 5)
        .background(StudioTokens.bg)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(StudioTokens.stroke, lineWidth: 1))

        HStack(spacing: 4) {
            chip("Auditionable", on: model.takesFilter.auditionableOnly) {
                model.takesFilter.auditionableOnly.toggle()
            }
            let regionOn = model.takesFilter.region != nil
            chip("This region", on: regionOn) {
                model.takesFilter.region = regionOn ? nil : model.selection.region
            }
            .disabled(model.selection.region == nil && !regionOn)
        }
    }

    private func chip(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(on ? StudioTokens.text : StudioTokens.dim)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(on ? StudioTokens.purple.opacity(0.22) : .clear)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(on ? StudioTokens.purple : StudioTokens.stroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(on ? "on" : "off")
    }

    // MARK: Take row

    private func takeRow(_ item: StudioTakeBrowserItem) -> some View {
        Button {
            model.previewTake(item)
        } label: {
            HStack(alignment: .top, spacing: 6) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(StudioTokens.stemColor(item.stemKind))
                    .frame(width: 6, height: 6)
                    .padding(.top, 3)
                    .opacity(item.offline ? 0.4 : 1)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(item.offline ? StudioTokens.faint : StudioTokens.text)
                        .lineLimit(1)
                    Text(metaLine(item))
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(StudioTokens.faint)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                statusBadge(item)
            }
            .padding(.horizontal, 7).padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(StudioTokens.panelHi.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(StudioTokens.strokeSoft, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .onDrag { NSItemProvider(object: item.takeID as NSString) }
        .contextMenu { rowMenu(item) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.kind.label) take, \(item.stemName), \(item.title)")
        .accessibilityValue(item.offline ? "purged" : (item.provenance ? "landed song" : item.status.rawValue))
        .accessibilityHint("Click to preview. Drag onto a clip to use it there.")
    }

    /// The compact lineage line under the title: kind, seed, model, and bars.
    private func metaLine(_ item: StudioTakeBrowserItem) -> String {
        var parts: [String] = [item.kind.label]
        if item.stemName != "mix" { parts.append(item.stemName) }
        if let seed = item.lineage.seed { parts.append("seed \(seed % 100000)") }
        if let m = item.lineage.model { parts.append(m.replacingOccurrences(of: "acestep-v15-", with: "")) }
        if let s = item.lineage.regionStartTicks, let e = item.lineage.regionEndTicks,
           model.snapshot != nil {
            let region = StudioRegionSelection(rawStart: s, rawEnd: e)
            if let region {
                let bars = region.barRange(grid: model.barGrid)
                parts.append("bars \(bars.lowerBound)-\(bars.upperBound)")
            }
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func statusBadge(_ item: StudioTakeBrowserItem) -> some View {
        if item.offline {
            badge("purged", StudioTokens.faint)
        } else if item.provenance {
            badge("source", StudioTokens.cyan)
        } else if item.status == .promoted {
            badge("in mix", StudioTokens.good)
        }
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text.uppercased())
            .font(.system(size: 7.5, weight: .bold)).kerning(0.4)
            .foregroundStyle(color)
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(color.opacity(0.14))
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    @ViewBuilder
    private func rowMenu(_ item: StudioTakeBrowserItem) -> some View {
        Button("Preview in place") { model.previewTake(item) }
        Button("More like this") { model.rerollFromTake(item) }
        if let clip = model.selection.clipIDs.first, item.auditionable {
            Button("Place on selected clip") { model.placeTakeOnClip(takeID: item.takeID, clipID: clip) }
        }
        if item.auditionable {
            Divider()
            Button("Purge this take", role: .destructive) { model.purgeTakes(scope: .take(item.takeID)) }
        }
    }

    private var purgeButton: some View {
        Button { model.purgeConfirmShown = true } label: {
            HStack(spacing: 5) {
                Image(systemName: "trash").font(.system(size: 9))
                Text("Purge unused takes").font(.system(size: 10, weight: .semibold))
                Spacer(minLength: 0)
            }
            .foregroundStyle(StudioTokens.dim)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(StudioTokens.panelHi)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(StudioTokens.stroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .padding(.top, 2)
        .accessibilityLabel("Purge unused takes")
    }

    private func emptyNote(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5))
            .foregroundStyle(StudioTokens.faint)
            .padding(.horizontal, 4).padding(.vertical, 6)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Per-stem take mixing (L10, design 3.2 step 4)
//
// Shown in the audition panel: within an auditioned region, pick which take
// (variant) each stem uses independently (drums from take 2, other from take
// 3). Composes one take per stem, committed as one undo step (building on L9's
// audition). Drives take.auditionMix so an agent watching hears the same mix.

struct StudioPerStemMixView: View {
    @ObservedObject var model: StudioViewModel
    let audition: StudioAuditionState

    var body: some View {
        let stems = model.auditionStems()
        if stems.count > 1 {
            VStack(alignment: .leading, spacing: 5) {
                Text("PER-STEM MIX")
                    .font(.system(size: 9, weight: .bold)).kerning(1)
                    .foregroundStyle(StudioTokens.faint)
                ForEach(stems, id: \.self) { stem in
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(StudioTokens.stemColor(stem)).frame(width: 6, height: 6)
                        Text(stem.rawValue.capitalized)
                            .font(.system(size: 11)).foregroundStyle(StudioTokens.dim)
                            .frame(width: 52, alignment: .leading)
                        Spacer(minLength: 0)
                        ForEach(audition.variants) { variant in
                            variantButton(stem: stem, variant: variant.index)
                        }
                    }
                }
                Text("Pick a take per stem, then Commit.")
                    .font(.system(size: 9)).foregroundStyle(StudioTokens.faint)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(StudioTokens.panelHi)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(StudioTokens.stroke, lineWidth: 1))
        }
    }

    private func variantButton(stem: StudioStemKind, variant: Int) -> some View {
        let on = model.stemMixVariant(stem) == variant
        return Button {
            model.auditionStemVariant(stem, variant: variant)
        } label: {
            Text("\(variant + 1)")
                .font(.system(size: 10, weight: .bold).monospacedDigit())
                .foregroundStyle(on ? .white : StudioTokens.dim)
                .frame(width: 18, height: 18)
                .background(on ? StudioTokens.stemColor(stem).opacity(0.9) : StudioTokens.bg)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5)
                    .stroke(on ? StudioTokens.stemColor(stem) : StudioTokens.stroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(stem.rawValue) take \(variant + 1)")
        .accessibilityValue(on ? "selected" : "")
    }
}
