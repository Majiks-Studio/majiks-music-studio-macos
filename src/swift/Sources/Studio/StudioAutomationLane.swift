import SwiftUI

// MARK: - Automation lane rendering (shared)
//
// The one place a volume/pan automation lane is drawn, so the live timeline
// canvas and any off-canvas preview render identically. Breakpoints connect
// with linear segments (matching the engine's Linear eval: hold the first value
// to the left edge, lerp between points, hold the last to the right edge). The
// point under an active drag is shown at its provisional position.

enum StudioAutomationLaneRenderer {
    static func draw(
        _ context: inout GraphicsContext,
        track: StudioTrackSnapshot,
        target: StudioAutoTarget,
        rowY: CGFloat,
        height: CGFloat,
        width: CGFloat,
        scroll: Int64,
        pxPerTick: CGFloat,
        dragProvisional: StudioAutoPoint?
    ) {
        context.fill(
            Path(CGRect(x: 0, y: rowY, width: width, height: height)),
            with: .color(StudioTokens.panel))
        var top = Path()
        top.move(to: CGPoint(x: 0, y: rowY + 0.5))
        top.addLine(to: CGPoint(x: width, y: rowY + 0.5))
        context.stroke(top, with: .color(StudioTokens.stroke), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

        // Zero/center reference line.
        let refY = StudioAutomationMath.valueToY(0, target: target, rowY: rowY, height: height)
        var ref = Path()
        ref.move(to: CGPoint(x: 0, y: refY)); ref.addLine(to: CGPoint(x: width, y: refY))
        context.stroke(ref, with: .color(.white.opacity(0.05)), lineWidth: 1)

        var points = track.automation(target)
        if let prov = dragProvisional {
            points.removeAll { $0.id == prov.id }
            points.append(prov)
            points.sort { $0.positionTicks < $1.positionTicks }
        }

        let color = StudioTokens.cyan
        guard !points.isEmpty else {
            context.draw(
                Text("\(target.label) automation, click to add points")
                    .font(.system(size: 8, weight: .semibold)).foregroundStyle(StudioTokens.faint),
                at: CGPoint(x: 8, y: rowY + height / 2), anchor: .leading)
            return
        }

        func px(_ p: StudioAutoPoint) -> CGPoint {
            CGPoint(
                x: StudioTimelineMath.ticksToPx(p.positionTicks, pxPerTick: pxPerTick, scrollTicks: scroll),
                y: StudioAutomationMath.valueToY(p.value, target: target, rowY: rowY, height: height))
        }

        var line = Path()
        let first = px(points[0])
        line.move(to: CGPoint(x: 0, y: first.y)); line.addLine(to: first)
        for p in points.dropFirst() { line.addLine(to: px(p)) }
        let last = px(points[points.count - 1])
        line.addLine(to: CGPoint(x: width, y: last.y))
        context.stroke(line, with: .color(color.opacity(0.9)), lineWidth: 1.5)

        var fill = line
        fill.addLine(to: CGPoint(x: width, y: rowY + height))
        fill.addLine(to: CGPoint(x: 0, y: rowY + height))
        fill.closeSubpath()
        context.fill(fill, with: .color(color.opacity(0.08)))

        for p in points {
            let c = px(p)
            guard c.x >= -6, c.x <= width + 6 else { continue }
            let held = dragProvisional?.id == p.id
            let r: CGFloat = held ? 4 : 3
            let rect = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
            context.fill(Path(ellipseIn: rect), with: .color(held ? .white : StudioTokens.faderCap))
            context.stroke(Path(ellipseIn: rect), with: .color(color), lineWidth: 1)
        }

        context.draw(
            Text(target.label.uppercased()).font(.system(size: 8, weight: .bold)).foregroundStyle(StudioTokens.faint),
            at: CGPoint(x: 6, y: rowY + 8), anchor: .leading)
    }
}

/// Off-canvas preview of one automation lane (evidence / previews). Pure Canvas,
/// no gestures, so it renders reliably through ImageRenderer.
struct StudioAutomationLanePreview: View {
    var track: StudioTrackSnapshot
    var target: StudioAutoTarget
    var pxPerTick: CGFloat
    var scroll: Int64 = 0

    var body: some View {
        Canvas { context, size in
            var c = context
            StudioAutomationLaneRenderer.draw(
                &c, track: track, target: target, rowY: 0, height: size.height, width: size.width,
                scroll: scroll, pxPerTick: pxPerTick, dragProvisional: nil)
        }
    }
}
