import SwiftUI

/// Design tokens for the Studio (DAW) surface.
///
/// Source of truth: majiks-studio-daw/mockup/majiks-studio-mockup.html and
/// 01-DESIGN.md section 5. The app previously had no token layer (colors were
/// inline literals); new Studio code MUST route every color through this file.
///
/// THE SHIMMER RULE (binding, 01-DESIGN section 5): the generative gradient
/// appears ONLY on generative surfaces: the Generate button, an in-flight
/// revise region border, rendering take lanes, and the "AI" badge on
/// generated clips. Nothing else may use it. Reduced-motion freezes the
/// animation; the gradient itself stays so the meaning survives.
enum StudioTokens {

    // MARK: - Surfaces

    static let bg = hex(0x0F0F17)
    static let panel = hex(0x181822)
    static let panelHi = hex(0x20202E)
    static let clipBase = hex(0x12121C)

    // MARK: - Strokes

    static let stroke = hex(0x2A2A3A)
    static let strokeSoft = hex(0x232331)

    // MARK: - Text

    static let text = hex(0xE9E9F4)
    static let dim = hex(0x8F8FA8)
    static let faint = hex(0x5B5B74)

    // MARK: - Accents

    static let purple = hex(0x8B5CF6)
    static let cyan = hex(0x4DCCFA)
    static let good = hex(0x59DB8C)
    static let warn = hex(0xFBA04C)
    static let bad = hex(0xFF5F57)
    static let faderCap = hex(0xCFD0E4)

    // MARK: - Stem colors (suite-wide constants, shared with Majik's DJ)

    static let stemVocals = hex(0xFF5FA2)
    static let stemDrums = hex(0xFFB020)
    static let stemBass = hex(0x8B5CF6)
    static let stemOther = hex(0x2BD9C7)
    static let stemImported = hex(0x8A93A6)

    // MARK: - Section tints (ruler section lane)

    static let sectionNeutral = hex(0x3A3A55)   // intro / outro
    static let sectionVerse = hex(0x334155)
    static let sectionChorus = hex(0x4C3570)
    static let sectionBridge = hex(0x233C4A)

    // MARK: - The generative gradient (shimmer surfaces ONLY)

    /// Stops from the mockup: #4DA3FF -> #8B5CF6 (45%) -> #FF5FA2 (80%) -> #2BD9C7 (115%).
    /// The 115% stop is clamped to 1.0; the overshoot exists in CSS only to
    /// keep teal at the trailing edge while the background pans.
    static let gradientStops: [Gradient.Stop] = [
        .init(color: hex(0x4DA3FF), location: 0.00),
        .init(color: hex(0x8B5CF6), location: 0.45),
        .init(color: hex(0xFF5FA2), location: 0.80),
        .init(color: hex(0x2BD9C7), location: 1.00),
    ]

    /// Static generative gradient (the reduced-motion / non-animated form).
    static var generativeGradient: LinearGradient {
        LinearGradient(
            stops: gradientStops,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// Animated form: `phase` slides the gradient window so the sheen drifts.
    /// Callers derive `phase` from `shimmerPhase(now:)` below.
    static func generativeGradient(phase: Double) -> LinearGradient {
        // Pan the start/end anchors across a 2x-wide window, mirroring the
        // CSS `background-size: 220%` + background-position sweep.
        let p = phase // 0...1
        let start = UnitPoint(x: -1.0 + p, y: 0.0)
        let end = UnitPoint(x: 1.0 + p, y: 1.0)
        return LinearGradient(stops: gradientStops, startPoint: start, endPoint: end)
    }

    /// Shimmer phase for a given time. 01-DESIGN section 5: 8-12 s period.
    /// Triangle wave so the sheen sweeps back and forth like the CSS keyframes.
    static func shimmerPhase(now: TimeInterval, period: TimeInterval = 9.0) -> Double {
        let t = now.truncatingRemainder(dividingBy: period) / period
        return t < 0.5 ? (t * 2.0) : (2.0 - t * 2.0)
    }

    // MARK: - Grid + canvas alpha levels (01-DESIGN section 5)

    static let gridBarAlpha: Double = 0.06
    static let gridBeatAlpha: Double = 0.03
    static let gridDownbeatAlpha: Double = 0.12
    static let waveformBodyAlpha: Double = 0.75
    static let waveformDimAlpha: Double = 0.28
    static let clipFillAlpha: Double = 0.16
    static let clipStrokeAlpha: Double = 0.45

    // MARK: - Layout metrics (8px system)

    static let spacing: CGFloat = 8
    static let trackHeaderWidth: CGFloat = 150
    static let browserWidth: CGFloat = 172
    static let inspectorWidth: CGFloat = 272
    /// Deferred proposal 5 (design DESIGN-catalog-v2.md 6): the contract value
    /// wins. `timeline_core::model::DEFAULT_TRACK_HEIGHT_PX` is 90 and always
    /// was; this token said 64, so a track created in the UI rendered at a
    /// height the engine model disagreed with.
    static let trackHeightDefault: CGFloat = 90
    static let trackHeightMini: CGFloat = 32
    static let trackHeightTall: CGFloat = 128
    static let takeRowHeight: CGFloat = 30
    /// Automation lane height under a track (01-DESIGN section 5: 40px lanes).
    static let automationLaneHeight: CGFloat = 40
    static let sectionRulerHeight: CGFloat = 22
    static let barRulerHeight: CGFloat = 16
    /// The loop strip: the bottom band of the ruler, directly above the lanes.
    /// A band of its own rather than a modifier on an existing drag — see
    /// `StudioTimelineView.beginDrag`. 14px reads at arm's length on a 4K TV
    /// and is comfortably larger than the 6px hit slop everything else uses.
    static let loopRulerHeight: CGFloat = 14
    /// Hit band of a pane-resize divider (StudioPaneDivider). The LINE it draws
    /// is 1 pt; the band you can grab is this. Same reasoning as the loop strip
    /// above: a target sized to the graphic is unusable at sofa distance, and 6
    /// is the hit slop the rest of the Studio already uses.
    static let dividerHit: CGFloat = 6
    static let clipCornerRadius: CGFloat = 6
    static let clipVerticalInset: CGFloat = 5

    // MARK: - Helpers

    static func stemColor(_ kind: StudioStemKind) -> Color {
        switch kind {
        case .vocals: return stemVocals
        case .drums: return stemDrums
        case .bass: return stemBass
        case .other: return stemOther
        case .imported: return stemImported
        }
    }

    /// Clip body fill: stem color mixed 16% over the clip base (mockup's
    /// `color-mix(in srgb, var(--c) 16%, #12121C)`), precomputed per stem so
    /// the canvas hot loop never blends colors.
    static func clipFillColor(_ kind: StudioStemKind) -> Color {
        mixed(stemHex(kind), over: 0x12121C, amount: 0.16)
    }

    /// Take chip fill: stem 12% over the clip base.
    static func takeFillColor(_ kind: StudioStemKind) -> Color {
        mixed(stemHex(kind), over: 0x12121C, amount: 0.12)
    }

    /// Clip name tag color: stem 80% toward white.
    static func clipTagColor(_ kind: StudioStemKind) -> Color {
        mixed(0xFFFFFF, over: stemHex(kind), amount: 0.20)
    }

    private static func stemHex(_ kind: StudioStemKind) -> UInt32 {
        switch kind {
        case .vocals: return 0xFF5FA2
        case .drums: return 0xFFB020
        case .bass: return 0x8B5CF6
        case .other: return 0x2BD9C7
        case .imported: return 0x8A93A6
        }
    }

    private static func mixed(_ top: UInt32, over base: UInt32, amount: Double) -> Color {
        func channel(_ v: UInt32, _ shift: UInt32) -> Double {
            Double((v >> shift) & 0xFF) / 255.0
        }
        let r = channel(top, 16) * amount + channel(base, 16) * (1 - amount)
        let g = channel(top, 8) * amount + channel(base, 8) * (1 - amount)
        let b = channel(top, 0) * amount + channel(base, 0) * (1 - amount)
        return Color(.sRGB, red: r, green: g, blue: b, opacity: 1.0)
    }

    static func sectionColor(_ role: StudioSectionRole) -> Color {
        switch role {
        case .neutral: return sectionNeutral
        case .verse: return sectionVerse
        case .chorus: return sectionChorus
        case .bridge: return sectionBridge
        }
    }

    private static func hex(_ value: UInt32) -> Color {
        let r = Double((value >> 16) & 0xFF) / 255.0
        let g = Double((value >> 8) & 0xFF) / 255.0
        let b = Double(value & 0xFF) / 255.0
        return Color(.sRGB, red: r, green: g, blue: b, opacity: 1.0)
    }
}

// MARK: - Shimmer modifier (generative surfaces only)

/// Background shimmer for generative controls (Generate button, revise pill).
/// Honors reduced motion: the gradient stays, the drift stops.
struct StudioShimmerBackground: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var cornerRadius: CGFloat = 8

    func body(content: Content) -> some View {
        content.background {
            if reduceMotion {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(StudioTokens.generativeGradient)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 12.0)) { context in
                    let phase = StudioTokens.shimmerPhase(
                        now: context.date.timeIntervalSinceReferenceDate)
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(StudioTokens.generativeGradient(phase: phase))
                }
            }
        }
    }
}

extension View {
    /// Apply the generative shimmer background. THE SHIMMER RULE: only call
    /// this on generative surfaces (see StudioTokens header comment).
    func studioShimmerBackground(cornerRadius: CGFloat = 8) -> some View {
        modifier(StudioShimmerBackground(cornerRadius: cornerRadius))
    }
}
