import SwiftUI

// MARK: - Studio coach marks
//
// Four dismissible first-run tips. Originally the Generate -> Session moment
// (01-DESIGN 3.1 step 4) and only about the ruler, R-to-revise, and the
// generated badge. Rewritten for discoverability: every tip now points at a
// control that already existed and the owner still could not find — Back/Fwd,
// seek, volume, effects, and + Instrument. Seen-state is remembered (v2 key on the shell) so
// they never nag again.
//
// Coach marks beat more chrome for these discoverability gaps: the features were
// built, the labels were missing, and a one-time card that names the words on
// screen is cheaper than another permanent button. The fourth gap (volume)
// also got a permanent VOLUME control on the transport, because "make it
// louder" is not a first-run-only question.

struct StudioCoachMark: Identifiable {
    let id = UUID()
    let systemImage: String
    let text: String

    /// The exact four, in order. Copy is plain and verb-first, no marketing,
    /// no em-dashes (house style). Each sentence names the on-screen WORD the
    /// owner will look for, not a DAW concept.
    static let all: [StudioCoachMark] = [
        StudioCoachMark(
            systemImage: "backward.fill",
            text: "Back and Fwd step one bar. Click the bar numbers, or drag the white handle, to jump anywhere in the song."),
        StudioCoachMark(
            systemImage: "speaker.wave.2.fill",
            text: "VOLUME on the top bar is the whole mix. Open MIXER at the bottom for every track's fader."),
        StudioCoachMark(
            systemImage: "slider.horizontal.3",
            text: "Effects opens EQ, reverb, delay and six more. Add them to any track, a bus, or the master."),
        StudioCoachMark(
            systemImage: "pianokeys.inverse",
            text: "+ Instrument adds a Synth, Sampler or Drum Rack. Load a vault sound, then play it from your keyboard."),
    ]

    /// Pure catalog of tip bodies, for tests that must not depend on view
    /// identity. A rewrite that drops one of the four affordances fails the
    /// discoverability suite by name.
    static var tipBodies: [String] { all.map(\.text) }
}

/// A small bottom-center card that steps through the three tips. Self-contained:
/// it reads/writes its own seen flag via the binding and calls through when
/// done or skipped. The shell owns the AppStorage key.
struct StudioCoachMarksView: View {
    @Binding var isPresented: Bool
    @State private var step = 0

    private var marks: [StudioCoachMark] { StudioCoachMark.all }
    private var current: StudioCoachMark { marks[min(step, marks.count - 1)] }
    private var isLast: Bool { step >= marks.count - 1 }

    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                badge
                VStack(alignment: .leading, spacing: 6) {
                    Text("Getting around the Studio")
                        .font(.system(size: 11, weight: .heavy))
                        .kerning(0.8)
                        .foregroundStyle(StudioTokens.dim)
                        .lineLimit(1)
                        .fixedSize()
                    Text(current.text)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(StudioTokens.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 10) {
                stepDots
                Spacer()
                Button("Skip") { finish() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(StudioTokens.faint)
                Button(isLast ? "Got it" : "Next") {
                    if isLast { finish() } else { withAnimation(.easeOut(duration: 0.15)) { step += 1 } }
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(StudioTokens.bg)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(
                        LinearGradient(
                            colors: [StudioTokens.purple, StudioTokens.cyan],
                            startPoint: .leading, endPoint: .trailing)))
            }
        }
        .padding(16)
        .frame(width: 360)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(StudioTokens.panel)
                .shadow(color: .black.opacity(0.35), radius: 18, y: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 14).stroke(StudioTokens.stroke, lineWidth: 1))
        .padding(.bottom, 24)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Studio tips")
    }

    private var badge: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9)
                .fill(StudioTokens.panelHi)
                .frame(width: 40, height: 40)
            Image(systemName: current.systemImage)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(StudioTokens.text)
        }
    }

    private var stepDots: some View {
        HStack(spacing: 6) {
            ForEach(marks.indices, id: \.self) { i in
                Circle()
                    .fill(i == step ? StudioTokens.cyan : StudioTokens.stroke)
                    .frame(width: 6, height: 6)
            }
        }
    }

    private func finish() {
        withAnimation(.easeOut(duration: 0.2)) { isPresented = false }
    }
}
