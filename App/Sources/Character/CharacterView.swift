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

private struct CharacterCanvas: View {
    let mood: CharacterMood
    let eyeOffset: EyeOffset
    let pose: CharacterPose

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

            context.fill(Self.bodyPath, with: .color(Color(hex: CharacterSpec.bodyColor)))
            let shadow = CharacterSpec.shadowCenter
            let radii = CharacterSpec.shadowRadii
            context.fill(
                Path(ellipseIn: CGRect(
                    x: shadow.x - radii.width,
                    y: shadow.y - radii.height,
                    width: radii.width * 2,
                    height: radii.height * 2
                )),
                with: .color(Color(hex: CharacterSpec.shadowColor))
            )

            if mood == .idle {
                context.translateBy(x: eyeOffset.dx, y: eyeOffset.dy)
            }
            drawEyes(in: &context)
        }
        .accessibilityLabel("キャラクター（\(mood.displayName)）")
    }

    private func drawEyes(in context: inout GraphicsContext) {
        let eyeColor = GraphicsContext.Shading.color(Color(hex: CharacterSpec.eyeColor))
        let stroke = StrokeStyle(lineWidth: CharacterSpec.eyeStrokeWidth, lineCap: .round, lineJoin: .round)

        for (index, center) in [CharacterSpec.leftEye, CharacterSpec.rightEye].enumerated() {
            let isLeft = index == 0
            switch mood {
            case .idle:
                let r = CharacterSpec.idleEyeRadius
                let ry = r * pose.eyeOpenness
                context.fill(Path(ellipseIn: CGRect(x: center.x - r, y: center.y - ry, width: r * 2, height: ry * 2)), with: eyeColor)

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

    private static let bodyPath: Path = {
        var path = Path()
        for segment in CharacterSpec.bodySegments {
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
    }()
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
