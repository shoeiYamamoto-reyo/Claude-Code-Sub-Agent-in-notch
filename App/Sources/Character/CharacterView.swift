import AgentKit
import SwiftUI

/// キャラクター（`docs/design/character.md`）。画像アセットは使わず `Canvas` で描く。
///
/// 描き直すのは、状態ごとの時刻（`CharacterAnimation.nextFrameTime`。待機中はまばたきの間だけ）と、
/// 目が動いている間（60 fps）だけ。エラー時と「視差効果を減らす」がオンのときは、目が動いていなければタイマーを持たない。
struct CharacterView: View {
    let mood: CharacterMood
    let eyeMotion: EyeMotion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(CharacterSchedule(mood: reduceMotion ? nil : mood, fastUntil: eyeMotion.endTime)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            CharacterCanvas(
                mood: mood,
                eyeOffset: mood == .idle ? eyeMotion.offset(at: time) : .zero,
                pose: CharacterAnimation.pose(for: mood, at: time, reduceMotion: reduceMotion)
            )
        }
    }
}

/// 目の補間中だけ 60 fps、それ以外は状態ごとの時刻（`mood` が nil なら補間が終わったら止まる）。
private struct CharacterSchedule: TimelineSchedule {
    static let fastInterval: TimeInterval = 1.0 / 60

    let mood: CharacterMood?
    /// この時刻（timeIntervalSinceReferenceDate）までは 60 fps で描く。
    let fastUntil: TimeInterval

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        var next: Date? = startDate
        let mood = self.mood
        let fastUntil = self.fastUntil
        return AnyIterator {
            guard let current = next else { return nil }
            let time = current.timeIntervalSinceReferenceDate
            if time < fastUntil {
                next = current.addingTimeInterval(Self.fastInterval)
            } else if let mood, let nextTime = CharacterAnimation.nextFrameTime(after: time, for: mood) {
                next = Date(timeIntervalSinceReferenceDate: nextTime)
            } else {
                next = nil
            }
            return current
        }
    }
}

/// 1 コマ分の絵。サブエージェントの一覧（`AgentListView`）では色と見た目（`AgentLook`、ROADMAP 5-8）を変えて使う。
struct CharacterCanvas: View {
    let mood: CharacterMood
    let eyeOffset: EyeOffset
    let pose: CharacterPose
    var palette: CharacterPalette = CharacterSpec.notchPalette
    var look: AgentLook = .standard

    var body: some View {
        Canvas { context, size in
            let scale = min(size.width / CharacterSpec.viewBoxWidth, size.height / CharacterSpec.viewBoxHeight)
            context.translateBy(
                x: (size.width - CharacterSpec.viewBoxWidth * scale) / 2,
                y: (size.height - CharacterSpec.viewBoxHeight * scale) / 2
            )
            context.scaleBy(x: scale, y: scale)

            // 体の底を支点に、拡大 → 回転 → 上下移動。
            let anchor = CharacterSpec.bodyAnchor
            context.translateBy(x: anchor.x, y: anchor.y + pose.offsetY)
            context.rotate(by: .degrees(pose.rotationDegrees))
            context.scaleBy(x: pose.scaleX, y: pose.scaleY)
            context.translateBy(x: -anchor.x, y: -anchor.y)

            let geometry = Self.geometries[look.shape] ?? .standard
            context.fill(Self.bodyPaths[look.shape] ?? Self.bodyPath, with: .color(Color(hex: palette.body)))
            let shadow = CharacterSpec.shadowCenter
            let radii = geometry.shadowRadii
            context.fill(
                Path(ellipseIn: CGRect(
                    x: shadow.x - radii.width,
                    y: shadow.y - radii.height,
                    width: radii.width * 2,
                    height: radii.height * 2
                )),
                with: .color(Color(hex: palette.shadow))
            )

            // 小物は顔と一緒に動かす（目の追従では動かさない）。
            CharacterAccessory.draw(look.accessory, geometry: geometry, in: &context)

            if mood == .idle {
                context.translateBy(x: eyeOffset.dx, y: eyeOffset.dy)
            }
            drawEyes(geometry: geometry, in: &context)
        }
        .accessibilityLabel("キャラクター（\(mood.displayName)）")
    }

    private func drawEyes(geometry: CharacterGeometry, in context: inout GraphicsContext) {
        let eyeColor = GraphicsContext.Shading.color(Color(hex: CharacterSpec.eyeColor))
        let stroke = StrokeStyle(lineWidth: CharacterSpec.eyeStrokeWidth, lineCap: .round, lineJoin: .round)

        for (index, center) in [geometry.leftEye, geometry.rightEye].enumerated() {
            let isLeft = index == 0
            switch mood {
            case .idle:
                drawIdleEye(at: center, color: eyeColor, in: &context)

            case .working:
                let half = CharacterSpec.workingLineHalfWidth
                var path = Path()
                path.move(to: CGPoint(x: center.x - half, y: center.y))
                path.addLine(to: CGPoint(x: center.x + half, y: center.y))
                context.stroke(path, with: eyeColor, style: stroke)

            case .waiting:
                let r = CharacterSpec.waitingEyeRadius
                context.fill(Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)), with: eyeColor)
                let h: CGFloat = 2.6
                context.fill(
                    Path(ellipseIn: CGRect(x: center.x + 2.4 - h, y: center.y - 2.4 - h, width: h * 2, height: h * 2)),
                    with: .color(.white)
                )

            case .done:
                // 「^ ^」
                var path = Path()
                path.move(to: CGPoint(x: center.x - 6, y: center.y + 3))
                path.addQuadCurve(to: CGPoint(x: center.x + 6, y: center.y + 3), control: CGPoint(x: center.x, y: center.y - 7))
                context.stroke(path, with: eyeColor, style: stroke)

            case .error:
                // 左は「>」、右は「<」
                let tipX = isLeft ? center.x + 4 : center.x - 4
                let backX = isLeft ? center.x - 5 : center.x + 5
                var path = Path()
                path.move(to: CGPoint(x: backX, y: center.y - 5))
                path.addLine(to: CGPoint(x: tipX, y: center.y))
                path.addLine(to: CGPoint(x: backX, y: center.y + 5))
                context.stroke(path, with: eyeColor, style: stroke)
            }
        }
    }

    /// 待機中の目。形は `AgentLook.Eyes`（ほかの状態の表情は変えない）。まばたきでは縦だけ細くする。
    private func drawIdleEye(at center: CGPoint, color: GraphicsContext.Shading, in context: inout GraphicsContext) {
        let open = pose.eyeOpenness
        func ellipse(rx: CGFloat, ry: CGFloat, dy: CGFloat = 0) -> Path {
            Path(ellipseIn: CGRect(x: center.x - rx, y: center.y + dy - ry, width: rx * 2, height: ry * 2))
        }
        switch look.eyes {
        case .round:
            let r = CharacterSpec.idleEyeRadius
            context.fill(ellipse(rx: r, ry: r * open), with: color)
        case .small:
            context.fill(ellipse(rx: 3.5, ry: 3.5 * open), with: color)
        case .big:
            context.fill(ellipse(rx: 7, ry: 7 * open), with: color)
            if open > 0.6 {
                let h: CGFloat = 2.4
                context.fill(
                    Path(ellipseIn: CGRect(x: center.x + 2.2 - h, y: center.y - 2.2 - h, width: h * 2, height: h * 2)),
                    with: .color(.white)
                )
            }
        case .oval:
            context.fill(ellipse(rx: 4, ry: 6.5 * open), with: color)
        case .sleepy:
            // 上まぶたが下がった、横長で細い目。
            context.fill(ellipse(rx: 5.5, ry: 2.4 * open, dy: 1.5), with: color)
        }
    }

    nonisolated static let geometries: [AgentLook.Shape: CharacterGeometry] = Dictionary(
        uniqueKeysWithValues: AgentLook.Shape.allCases.map { ($0, CharacterGeometry(shape: $0)) }
    )

    /// 体形ごとの輪郭。
    nonisolated static let bodyPaths: [AgentLook.Shape: Path] = geometries.mapValues { path(from: $0.bodySegments) }

    /// ノッチのキャラ（ふつうの体形）の輪郭。
    nonisolated static let bodyPath: Path = path(from: CharacterSpec.bodySegments)

    nonisolated private static func path(from segments: [PathSegment]) -> Path {
        var path = Path()
        for segment in segments {
            switch segment {
            case .move(let point):
                path.move(to: point)
            case .line(let point):
                path.addLine(to: point)
            case .curve(let point, let control1, let control2):
                path.addCurve(to: point, control1: control1, control2: control2)
            }
        }
        path.closeSubpath()
        return path
    }
}

/// サブエージェントの小物（ROADMAP 5-8）。頭のてっぺん（`CharacterGeometry.top`）か目の位置に合わせて描く。
/// てっぺんより上は `AgentLook.Accessory.headroom` の高さまでに収める（のっぽでも viewBox からはみ出さない）。
enum CharacterAccessory {
    static func draw(_ accessory: AgentLook.Accessory, geometry: CharacterGeometry, in context: inout GraphicsContext) {
        let top = geometry.top
        let ink = GraphicsContext.Shading.color(Color(hex: CharacterSpec.eyeColor))
        switch accessory {
        case .none:
            break

        case .sprout:
            let tip = CGPoint(x: top.x, y: top.y - 8)
            var stem = Path()
            stem.move(to: CGPoint(x: top.x, y: top.y + 1))
            stem.addLine(to: tip)
            context.stroke(stem, with: .color(Color(hex: 0x5FA85F)), style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
            for side in [-1.0, 1.0] as [CGFloat] {
                var leaf = Path()
                leaf.move(to: tip)
                leaf.addQuadCurve(to: CGPoint(x: tip.x + 11 * side, y: tip.y - 5), control: CGPoint(x: tip.x + 7 * side, y: tip.y + 3))
                leaf.addQuadCurve(to: tip, control: CGPoint(x: tip.x + 4 * side, y: tip.y - 8))
                context.fill(leaf, with: .color(Color(hex: 0x7CC47C)))
            }

        case .antenna:
            let ball = CGPoint(x: top.x + 5, y: top.y - 11.5)
            var line = Path()
            line.move(to: CGPoint(x: top.x, y: top.y + 1))
            line.addLine(to: ball)
            context.stroke(line, with: ink, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            context.fill(Path(ellipseIn: CGRect(x: ball.x - 3.2, y: ball.y - 3.2, width: 6.4, height: 6.4)), with: .color(Color(hex: 0xF6C453)))

        case .ribbon:
            // 頭の右上に結ぶ。
            let knot = CGPoint(x: top.x + 17, y: top.y + 5)
            let color = GraphicsContext.Shading.color(Color(hex: 0xE86A8A))
            for side in [-1.0, 1.0] as [CGFloat] {
                var wing = Path()
                wing.move(to: knot)
                wing.addLine(to: CGPoint(x: knot.x + 9 * side, y: knot.y - 6))
                wing.addLine(to: CGPoint(x: knot.x + 9 * side, y: knot.y + 6))
                wing.closeSubpath()
                context.fill(wing, with: color)
            }
            context.fill(Path(ellipseIn: CGRect(x: knot.x - 2.8, y: knot.y - 2.8, width: 5.6, height: 5.6)), with: .color(Color(hex: 0xC94F70)))

        case .hat:
            let apex = CGPoint(x: top.x + 3, y: top.y - 14.5)
            var cone = Path()
            cone.move(to: CGPoint(x: top.x - 11, y: top.y + 3))
            cone.addLine(to: apex)
            cone.addLine(to: CGPoint(x: top.x + 11, y: top.y + 3))
            cone.addQuadCurve(to: CGPoint(x: top.x - 11, y: top.y + 3), control: CGPoint(x: top.x, y: top.y + 6))
            context.fill(cone, with: .color(Color(hex: 0x9C8CF0)))
            context.fill(Path(ellipseIn: CGRect(x: apex.x - 2.5, y: apex.y - 2.5, width: 5, height: 5)), with: .color(Color(hex: 0xF6C453)))

        case .glasses:
            let style = StrokeStyle(lineWidth: 2, lineCap: .round)
            let r: CGFloat = 8.5
            for center in [geometry.leftEye, geometry.rightEye] {
                context.stroke(Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)), with: ink, style: style)
            }
            var bridge = Path()
            bridge.move(to: CGPoint(x: geometry.leftEye.x + r, y: geometry.leftEye.y))
            bridge.addLine(to: CGPoint(x: geometry.rightEye.x - r, y: geometry.rightEye.y))
            context.stroke(bridge, with: ink, style: style)
        }
    }
}

extension Color {
    /// `0xRRGGBB` の sRGB 色。
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
