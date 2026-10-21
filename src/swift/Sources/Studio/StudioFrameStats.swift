import Foundation
import QuartzCore

// MARK: - Frame-time HUD support
//
// The performance gate (L5 brief section 6) requires measured frame times
// for pan/zoom over the 100-clip fixture. The canvas records a timestamp per
// draw; intervals between consecutive draws during continuous interaction
// are the frame times. Idle gaps (> 250 ms) are excluded so numbers reflect
// active rendering, not thinking pauses.

@MainActor
final class StudioFrameStats: ObservableObject {

    struct Summary: Equatable {
        var samples: Int
        var averageMillis: Double
        var p95Millis: Double
        var worstMillis: Double
        var effectiveFPS: Double
        var drawCostAverageMillis: Double
        var drawCostP95Millis: Double

        var display: String {
            String(
                format: "%.1f ms avg / %.1f ms p95 / %.1f worst / %.0f fps (%d)",
                averageMillis, p95Millis, worstMillis, effectiveFPS, samples
            )
        }

        var drawCostDisplay: String {
            String(
                format: "draw cost %.2f ms avg / %.2f ms p95",
                drawCostAverageMillis, drawCostP95Millis
            )
        }
    }

    @Published var hudVisible = false
    @Published private(set) var lastSweepSummary: Summary?

    private var lastFullRateDraw: CFTimeInterval?
    /// Frame-to-frame intervals, sampled ONLY while the canvas runs at full
    /// rate (playback, drag, sweep). Idle draws are throttled to 12 Hz by
    /// design, so counting them would report the throttle, not the renderer.
    private var intervals: [Double] = []
    /// Draw-closure durations (CPU cost of one canvas pass), all draws.
    private var drawCosts: [Double] = []
    private let maxSamples = 2400
    private let idleGapSeconds = 0.25

    /// Called from inside the Canvas draw closure (main thread).
    /// `startedAt` = CACurrentMediaTime() taken at the top of the closure.
    func recordDraw(startedAt: CFTimeInterval, fullRate: Bool) {
        let now = CACurrentMediaTime()
        drawCosts.append(now - startedAt)
        if drawCosts.count > maxSamples {
            drawCosts.removeFirst(drawCosts.count - maxSamples)
        }
        guard fullRate else {
            lastFullRateDraw = nil
            return
        }
        defer { lastFullRateDraw = now }
        guard let last = lastFullRateDraw else { return }
        let dt = now - last
        guard dt > 0, dt < idleGapSeconds else { return }
        intervals.append(dt)
        if intervals.count > maxSamples {
            intervals.removeFirst(intervals.count - maxSamples)
        }
    }

    func reset() {
        intervals.removeAll(keepingCapacity: true)
        drawCosts.removeAll(keepingCapacity: true)
        lastFullRateDraw = nil
    }

    /// Stats over the most recent `window` samples.
    func summary(window: Int = 600) -> Summary? {
        let recent = intervals.suffix(window)
        guard recent.count >= 10 else { return nil }
        let sorted = recent.sorted()
        let avg = recent.reduce(0, +) / Double(recent.count)
        let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        let costs = drawCosts.suffix(window)
        let costSorted = costs.sorted()
        let costAvg = costs.isEmpty ? 0 : costs.reduce(0, +) / Double(costs.count)
        let costP95 = costSorted.isEmpty
            ? 0 : costSorted[min(costSorted.count - 1, Int(Double(costSorted.count) * 0.95))]
        return Summary(
            samples: recent.count,
            averageMillis: avg * 1000,
            p95Millis: p95 * 1000,
            worstMillis: (sorted.last ?? 0) * 1000,
            effectiveFPS: avg > 0 ? 1.0 / avg : 0,
            drawCostAverageMillis: costAvg * 1000,
            drawCostP95Millis: costP95 * 1000
        )
    }

    func finishSweep() {
        lastSweepSummary = summary(window: maxSamples)
    }

    /// Write sweep results as JSON for the evidence doc. Path comes from the
    /// STUDIO_PERF_OUT environment variable; silently skipped otherwise.
    func writeSweepResultsIfRequested(context: String) {
        guard let path = ProcessInfo.processInfo.environment["STUDIO_PERF_OUT"],
              let summary = lastSweepSummary else { return }
        let payload: [String: Any] = [
            "context": context,
            "samples": summary.samples,
            "frame_interval_average_ms": summary.averageMillis,
            "frame_interval_p95_ms": summary.p95Millis,
            "frame_interval_worst_ms": summary.worstMillis,
            "effective_fps": summary.effectiveFPS,
            "draw_cost_average_ms": summary.drawCostAverageMillis,
            "draw_cost_p95_ms": summary.drawCostP95Millis,
            "date": ISO8601DateFormatter().string(from: Date()),
        ]
        if let data = try? JSONSerialization.data(
            withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}
