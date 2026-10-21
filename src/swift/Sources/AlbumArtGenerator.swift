import SwiftUI

// MARK: - Procedural Album Art Generator

struct AlbumArtGenerator {

    // 15 Color Palettes for variety
    static let colorPalettes: [[Color]] = [
        // Warm palettes
        [Color(red: 0.98, green: 0.50, blue: 0.45), Color(red: 0.85, green: 0.32, blue: 0.31)],  // Coral Red
        [Color(red: 0.96, green: 0.64, blue: 0.38), Color(red: 0.85, green: 0.42, blue: 0.20)],  // Orange Sunset
        [Color(red: 0.95, green: 0.77, blue: 0.30), Color(red: 0.80, green: 0.58, blue: 0.20)],  // Golden Yellow

        // Cool palettes
        [Color(red: 0.20, green: 0.60, blue: 0.86), Color(red: 0.10, green: 0.45, blue: 0.70)],  // Ocean Blue
        [Color(red: 0.40, green: 0.75, blue: 0.85), Color(red: 0.20, green: 0.55, blue: 0.65)],  // Cyan Sky
        [Color(red: 0.30, green: 0.50, blue: 0.70), Color(red: 0.15, green: 0.30, blue: 0.50)],  // Deep Blue

        // Purple/Pink palettes
        [Color(red: 0.70, green: 0.30, blue: 0.85), Color(red: 0.50, green: 0.20, blue: 0.65)],  // Royal Purple
        [Color(red: 0.85, green: 0.35, blue: 0.75), Color(red: 0.70, green: 0.20, blue: 0.60)],  // Magenta Pink
        [Color(red: 0.60, green: 0.40, blue: 0.80), Color(red: 0.40, green: 0.25, blue: 0.60)],  // Indigo Violet

        // Green palettes
        [Color(red: 0.30, green: 0.75, blue: 0.55), Color(red: 0.15, green: 0.60, blue: 0.40)],  // Emerald Green
        [Color(red: 0.50, green: 0.80, blue: 0.40), Color(red: 0.35, green: 0.65, blue: 0.25)],  // Lime Green
        [Color(red: 0.20, green: 0.60, blue: 0.50), Color(red: 0.10, green: 0.45, blue: 0.35)],  // Teal

        // Mixed palettes
        [Color(red: 0.85, green: 0.45, blue: 0.65), Color(red: 0.65, green: 0.25, blue: 0.50)],  // Rose Pink
        [Color(red: 0.60, green: 0.50, blue: 0.80), Color(red: 0.40, green: 0.35, blue: 0.60)],  // Periwinkle
        [Color(red: 0.75, green: 0.60, blue: 0.45), Color(red: 0.60, green: 0.45, blue: 0.30)]   // Warm Brown
    ]

    // Generate deterministic album art from a seed string
    static func generate(for seed: String, size: CGFloat = 120) -> some View {
        let hash = abs(seed.hashValue)
        let paletteIndex = hash % colorPalettes.count
        let patternIndex = (hash / colorPalettes.count) % 10
        let palette = colorPalettes[paletteIndex]

        return ZStack {
            // Base gradient background
            LinearGradient(
                colors: palette,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            // Pattern overlay - much more prominent
            PatternView(pattern: patternIndex, seed: hash, palette: palette)
                .opacity(0.85)
                .blendMode(.overlay)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Pattern View

struct PatternView: View {
    let pattern: Int
    let seed: Int
    let palette: [Color]

    var body: some View {
        // Use white for better visibility against colored backgrounds
        let patternColor = Color.white

        switch pattern {
        case 0: CirclesPattern(seed: seed, color: patternColor)
        case 1: WavesPattern(seed: seed, color: patternColor)
        case 2: GridPattern(seed: seed, color: patternColor)
        case 3: DiagonalLinesPattern(seed: seed, color: patternColor)
        case 4: DotsPattern(seed: seed, color: patternColor)
        case 5: HexagonsPattern(seed: seed, color: patternColor)
        case 6: TrianglesPattern(seed: seed, color: patternColor)
        case 7: ConcentricCirclesPattern(seed: seed, color: patternColor)
        case 8: ZigZagPattern(seed: seed, color: patternColor)
        default: StarburstPattern(seed: seed, color: patternColor)
        }
    }
}

// MARK: - Pattern Implementations

struct CirclesPattern: View {
    let seed: Int
    let color: Color

    var body: some View {
        Canvas { context, size in
            let count = 5 + (seed % 3)
            for i in 0..<count {
                let offset = Double(seed + i * 37) * 0.001
                let x = size.width * (0.2 + CGFloat((sin(offset) + 1) * 0.3))
                let y = size.height * (0.2 + CGFloat((cos(offset) + 1) * 0.3))
                let radius = size.width * (0.15 + CGFloat((seed + i * 17) % 10) * 0.02)

                context.fill(
                    Circle().path(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)),
                    with: .color(color.opacity(0.4))
                )
                context.stroke(
                    Circle().path(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)),
                    with: .color(color.opacity(0.6)),
                    lineWidth: 2
                )
            }
        }
    }
}

struct WavesPattern: View {
    let seed: Int
    let color: Color

    var body: some View {
        let waves = 3 + (seed % 3)
        let waveColor = color.opacity(0.5)

        return Canvas { context, size in
            let amplitude = size.height * 0.1
            let frequency = Double(1 + (seed % 3))

            for i in 0..<waves {
                let yOffset = size.height * CGFloat(i) / CGFloat(waves)
                var path = Path()
                path.move(to: CGPoint(x: 0, y: yOffset))

                for x in stride(from: CGFloat(0), through: size.width, by: CGFloat(2)) {
                    let waveSeed = Double(seed + i) * 0.1
                    let xRatio = Double(x / size.width)
                    let piValue = Double.pi
                    let waveValue = sin(xRatio * piValue * 2.0 * frequency + waveSeed)
                    let y = yOffset + amplitude * CGFloat(waveValue)
                    path.addLine(to: CGPoint(x: x, y: y))
                }

                context.stroke(path, with: .color(waveColor), lineWidth: 3)
            }
        }
    }
}

struct GridPattern: View {
    let seed: Int
    let color: Color

    var body: some View {
        Canvas { context, size in
            let spacing = size.width / CGFloat(4 + (seed % 3))

            for x in stride(from: 0, through: size.width, by: spacing) {
                context.stroke(
                    Path { p in
                        p.move(to: CGPoint(x: x, y: 0))
                        p.addLine(to: CGPoint(x: x, y: size.height))
                    },
                    with: .color(color.opacity(0.5)),
                    lineWidth: 1
                )
            }

            for y in stride(from: 0, through: size.height, by: spacing) {
                context.stroke(
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: y))
                        p.addLine(to: CGPoint(x: size.width, y: y))
                    },
                    with: .color(color.opacity(0.5)),
                    lineWidth: 1
                )
            }
        }
    }
}

struct DiagonalLinesPattern: View {
    let seed: Int
    let color: Color

    var body: some View {
        Canvas { context, size in
            let spacing = size.width / CGFloat(6 + (seed % 4))

            for i in stride(from: -size.height, through: size.width + size.height, by: spacing) {
                context.stroke(
                    Path { p in
                        p.move(to: CGPoint(x: i, y: 0))
                        p.addLine(to: CGPoint(x: i + size.height, y: size.height))
                    },
                    with: .color(color.opacity(0.25)),
                    lineWidth: 2
                )
            }
        }
    }
}

struct DotsPattern: View {
    let seed: Int
    let color: Color

    var body: some View {
        Canvas { context, size in
            let spacing = size.width / CGFloat(6 + (seed % 3))
            let radius: CGFloat = 2 + CGFloat((seed % 3))

            for x in stride(from: spacing / 2, through: size.width, by: spacing) {
                for y in stride(from: spacing / 2, through: size.height, by: spacing) {
                    context.fill(
                        Circle().path(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)),
                        with: .color(color.opacity(0.4))
                    )
                }
            }
        }
    }
}

struct HexagonsPattern: View {
    let seed: Int
    let color: Color

    var body: some View {
        Canvas { context, size in
            let hexSize = size.width / CGFloat(4 + (seed % 2))
            let rows = Int(size.height / hexSize) + 1
            let cols = Int(size.width / hexSize) + 1

            for row in 0..<rows {
                for col in 0..<cols {
                    let x = CGFloat(col) * hexSize + (row % 2 == 0 ? 0 : hexSize / 2)
                    let y = CGFloat(row) * hexSize * 0.866

                    let path = hexagonPath(center: CGPoint(x: x, y: y), size: hexSize / 2)
                    context.stroke(path, with: .color(color.opacity(0.5)), lineWidth: 2.5)
                }
            }
        }
    }

    func hexagonPath(center: CGPoint, size: CGFloat) -> Path {
        var path = Path()
        for i in 0..<6 {
            let angle = .pi / 3 * Double(i) - .pi / 2
            let x = center.x + size * cos(angle)
            let y = center.y + size * sin(angle)
            if i == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        path.closeSubpath()
        return path
    }
}

struct TrianglesPattern: View {
    let seed: Int
    let color: Color

    var body: some View {
        Canvas { context, size in
            let triangleSize = size.width / CGFloat(3 + (seed % 2))
            let rows = Int(size.height / triangleSize) + 1
            let cols = Int(size.width / triangleSize) + 1

            for row in 0..<rows {
                for col in 0..<cols {
                    let x = CGFloat(col) * triangleSize
                    let y = CGFloat(row) * triangleSize
                    let upward = (row + col + seed) % 2 == 0

                    var path = Path()
                    if upward {
                        path.move(to: CGPoint(x: x, y: y + triangleSize))
                        path.addLine(to: CGPoint(x: x + triangleSize / 2, y: y))
                        path.addLine(to: CGPoint(x: x + triangleSize, y: y + triangleSize))
                    } else {
                        path.move(to: CGPoint(x: x, y: y))
                        path.addLine(to: CGPoint(x: x + triangleSize, y: y))
                        path.addLine(to: CGPoint(x: x + triangleSize / 2, y: y + triangleSize))
                    }
                    path.closeSubpath()

                    context.stroke(path, with: .color(color.opacity(0.5)), lineWidth: 2.5)
                }
            }
        }
    }
}

struct ConcentricCirclesPattern: View {
    let seed: Int
    let color: Color

    var body: some View {
        Canvas { context, size in
            let centerX = size.width * (0.3 + CGFloat((seed % 40)) * 0.01)
            let centerY = size.height * (0.3 + CGFloat(((seed / 40) % 40)) * 0.01)
            let circles = 5 + (seed % 3)

            for i in 0..<circles {
                let radius = size.width * (0.15 + CGFloat(i) * 0.12)
                context.stroke(
                    Circle().path(in: CGRect(
                        x: centerX - radius,
                        y: centerY - radius,
                        width: radius * 2,
                        height: radius * 2
                    )),
                    with: .color(color.opacity(0.5)),
                    lineWidth: 2.5
                )
            }
        }
    }
}

struct ZigZagPattern: View {
    let seed: Int
    let color: Color

    var body: some View {
        Canvas { context, size in
            let rows = 4 + (seed % 3)
            let rowHeight = size.height / CGFloat(rows)
            let zigWidth = size.width / CGFloat(5 + (seed % 3))

            for row in 0..<rows {
                var path = Path()
                let y = CGFloat(row) * rowHeight
                path.move(to: CGPoint(x: 0, y: y))

                var direction = 1
                for x in stride(from: 0, through: size.width, by: zigWidth) {
                    path.addLine(to: CGPoint(x: x, y: y + rowHeight * 0.5 * CGFloat(direction)))
                    direction *= -1
                }

                context.stroke(path, with: .color(color.opacity(0.4)), lineWidth: 2)
            }
        }
    }
}

struct StarburstPattern: View {
    let seed: Int
    let color: Color

    var body: some View {
        let rays = 8 + (seed % 8)
        let rayColor = color.opacity(0.5)

        return Canvas { context, size in
            let centerX = size.width / 2
            let centerY = size.height / 2
            let angleOffset = Double(seed) * 0.01

            for i in 0..<rays {
                let baseAngle = .pi * 2 * Double(i) / Double(rays)
                let angle = baseAngle + angleOffset
                let cosValue = cos(angle)
                let sinValue = sin(angle)
                let endX = centerX + size.width * 0.5 * cosValue
                let endY = centerY + size.height * 0.5 * sinValue

                var path = Path()
                path.move(to: CGPoint(x: centerX, y: centerY))
                path.addLine(to: CGPoint(x: endX, y: endY))

                context.stroke(path, with: .color(rayColor), lineWidth: 2.5)
            }
        }
    }
}
