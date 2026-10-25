import Foundation
import XCTest
@testable import AgentKit

final class SoundCueTests: XCTestCase {
    func testPresentationChanges() {
        XCTAssertEqual(SoundCue.forPresentationChange(from: .character, to: .expanded), .expand)
        XCTAssertEqual(SoundCue.forPresentationChange(from: .peek, to: .expanded), .expand)
        XCTAssertEqual(SoundCue.forPresentationChange(from: .expanded, to: .character), .collapse)
        XCTAssertEqual(SoundCue.forPresentationChange(from: .expanded, to: .peek), .collapse)
        XCTAssertEqual(SoundCue.forPresentationChange(from: .character, to: .peek), .notice)
        XCTAssertNil(SoundCue.forPresentationChange(from: .peek, to: .character))
        for state in NotchPresentationState.allCases {
            XCTAssertNil(SoundCue.forPresentationChange(from: state, to: state))
        }
    }

    func testMoodChanges() {
        XCTAssertEqual(SoundCue.forMoodChange(from: .working, to: .done), .finished)
        XCTAssertEqual(SoundCue.forMoodChange(from: .working, to: .error), .error)
        // 承認待ちは peek（notice）か承認キュー（approval）が鳴らす。
        XCTAssertNil(SoundCue.forMoodChange(from: .working, to: .waiting))
        XCTAssertNil(SoundCue.forMoodChange(from: .idle, to: .working))
        XCTAssertNil(SoundCue.forMoodChange(from: .done, to: .idle))
        XCTAssertNil(SoundCue.forMoodChange(from: .done, to: .done))
    }

    func testCategories() {
        XCTAssertEqual(SoundCue.expand.category, .interface)
        XCTAssertEqual(SoundCue.collapse.category, .interface)
        for cue in [SoundCue.notice, .approval, .question, .finished, .error] {
            XCTAssertEqual(cue.category, .alert)
        }
    }
}

final class SoundGateTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1000)

    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    func testPlaysByDefault() {
        var gate = SoundGate()
        for cue in SoundCue.allCases {
            XCTAssertTrue(gate.shouldPlay(cue, settings: SoundSettings(), systemInterfaceSoundsEnabled: true, at: at(0)))
        }
    }

    func testDisabledPlaysNothing() {
        var gate = SoundGate()
        let settings = SoundSettings(isEnabled: false)
        for cue in SoundCue.allCases {
            XCTAssertFalse(gate.shouldPlay(cue, settings: settings, systemInterfaceSoundsEnabled: true, at: at(0)))
        }
    }

    func testCategoryToggles() {
        var gate = SoundGate()
        let noInterface = SoundSettings(playsInterfaceSounds: false)
        XCTAssertFalse(gate.shouldPlay(.expand, settings: noInterface, systemInterfaceSoundsEnabled: true, at: at(0)))
        XCTAssertTrue(gate.shouldPlay(.notice, settings: noInterface, systemInterfaceSoundsEnabled: true, at: at(0)))

        let noAlert = SoundSettings(playsAlertSounds: false)
        XCTAssertTrue(gate.shouldPlay(.collapse, settings: noAlert, systemInterfaceSoundsEnabled: true, at: at(1)))
        XCTAssertFalse(gate.shouldPlay(.finished, settings: noAlert, systemInterfaceSoundsEnabled: true, at: at(1)))
    }

    func testSystemInterfaceSettingOnlyAffectsInterfaceSounds() {
        var gate = SoundGate()
        XCTAssertFalse(gate.shouldPlay(.expand, settings: SoundSettings(), systemInterfaceSoundsEnabled: false, at: at(0)))
        XCTAssertTrue(gate.shouldPlay(.approval, settings: SoundSettings(), systemInterfaceSoundsEnabled: false, at: at(0)))
    }

    func testQuietModeUntilDeadline() {
        var gate = SoundGate()
        let settings = SoundSettings(quietUntil: at(60))
        XCTAssertTrue(settings.isQuiet(at: at(0)))
        XCTAssertFalse(gate.shouldPlay(.approval, settings: settings, systemInterfaceSoundsEnabled: true, at: at(0)))
        XCTAssertFalse(gate.shouldPlay(.expand, settings: settings, systemInterfaceSoundsEnabled: true, at: at(59)))
        // 時刻を過ぎたら自動で解除（タイマーは要らない）。
        XCTAssertFalse(settings.isQuiet(at: at(60)))
        XCTAssertTrue(gate.shouldPlay(.approval, settings: settings, systemInterfaceSoundsEnabled: true, at: at(60)))
    }

    func testThrottlesSameCue() {
        var gate = SoundGate(minimumInterval: 0.25)
        let settings = SoundSettings()
        XCTAssertTrue(gate.shouldPlay(.expand, settings: settings, systemInterfaceSoundsEnabled: true, at: at(0)))
        XCTAssertFalse(gate.shouldPlay(.expand, settings: settings, systemInterfaceSoundsEnabled: true, at: at(0.1)))
        // 別の音は間引かない。
        XCTAssertTrue(gate.shouldPlay(.collapse, settings: settings, systemInterfaceSoundsEnabled: true, at: at(0.1)))
        // 間引かれた呼び出しは記録しないので、最初から 0.25 秒で鳴る。
        XCTAssertTrue(gate.shouldPlay(.expand, settings: settings, systemInterfaceSoundsEnabled: true, at: at(0.25)))
    }

    func testThrottleRecoversWhenClockGoesBack() {
        var gate = SoundGate()
        let settings = SoundSettings()
        XCTAssertTrue(gate.shouldPlay(.notice, settings: settings, systemInterfaceSoundsEnabled: true, at: at(10)))
        XCTAssertTrue(gate.shouldPlay(.notice, settings: settings, systemInterfaceSoundsEnabled: true, at: at(5)))
    }

    func testSettingsRoundTrip() throws {
        let settings = SoundSettings(isEnabled: false, volume: .high, playsInterfaceSounds: false, quietUntil: at(30))
        let data = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(SoundSettings.self, from: data), settings)
    }

    func testNextMorning() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        let evening = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 22)))
        let morning = SoundSettings.nextOccurrence(ofHour: 8, after: evening, calendar: calendar)
        XCTAssertEqual(calendar.dateComponents([.day, .hour, .minute], from: morning), DateComponents(day: 26, hour: 8, minute: 0))

        let early = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 6)))
        let sameDay = SoundSettings.nextOccurrence(ofHour: 8, after: early, calendar: calendar)
        XCTAssertEqual(calendar.dateComponents([.day, .hour], from: sameDay), DateComponents(day: 26, hour: 8))
    }
}

final class SoundSynthesizerTests: XCTestCase {
    func testEveryCueIsShortAndDoesNotClip() {
        for cue in SoundCue.allCases {
            let tones = SoundSynthesizer.tones(for: cue)
            XCTAssertFalse(tones.isEmpty, "\(cue)")
            XCTAssertLessThan(SoundSynthesizer.duration(of: tones), 0.5, "\(cue)")

            let samples = SoundSynthesizer.render(tones)
            XCTAssertEqual(samples.count, Int((SoundSynthesizer.duration(of: tones) * 44_100).rounded(.up)), "\(cue)")
            let peak = samples.map(abs).max() ?? 0
            XCTAssertGreaterThan(peak, 0.1, "\(cue) が聞こえない")
            XCTAssertLessThanOrEqual(peak, SoundSynthesizer.peakLimit + 0.0001, "\(cue)")
            // 端が 0 付近で始まり 0 で終わる（クリック音が出ない）。
            XCTAssertLessThan(abs(samples.first ?? 1), 0.01, "\(cue)")
            XCTAssertLessThan(abs(samples.last ?? 1), 0.01, "\(cue)")
        }
    }

    func testCuesSoundDifferent() {
        let rendered = SoundCue.allCases.map { SoundSynthesizer.render(SoundSynthesizer.tones(for: $0)) }
        for i in rendered.indices {
            for j in rendered.indices where j > i {
                XCTAssertNotEqual(rendered[i], rendered[j])
            }
        }
    }

    func testLimitsLoudMixes() {
        let loud = [
            SoundTone(start: 0, duration: 0.1, frequency: 440, amplitude: 1, harmonics: [1]),
            SoundTone(start: 0, duration: 0.1, frequency: 440, amplitude: 1),
        ]
        let peak = SoundSynthesizer.render(loud).map(abs).max() ?? 0
        XCTAssertEqual(peak, SoundSynthesizer.peakLimit, accuracy: 0.0001)
    }

    func testEmptyRendersNothing() {
        XCTAssertEqual(SoundSynthesizer.render([]), [])
    }

    func testWAVHeader() {
        let samples: [Float] = [0, 0.5, -0.5, 1, -1, 2]
        let data = SoundSynthesizer.wavData(samples, sampleRate: 44_100)
        let bytes = [UInt8](data)
        XCTAssertEqual(bytes.count, 44 + samples.count * 2)
        XCTAssertEqual(String(decoding: bytes[0..<4], as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: bytes[8..<16], as: UTF8.self), "WAVEfmt ")
        XCTAssertEqual(String(decoding: bytes[36..<40], as: UTF8.self), "data")
        XCTAssertEqual(uint32(bytes, at: 4), UInt32(36 + samples.count * 2))
        XCTAssertEqual(uint16(bytes, at: 20), 1)  // PCM
        XCTAssertEqual(uint16(bytes, at: 22), 1)  // モノラル
        XCTAssertEqual(uint32(bytes, at: 24), 44_100)
        XCTAssertEqual(uint32(bytes, at: 28), 88_200)
        XCTAssertEqual(uint16(bytes, at: 34), 16)
        XCTAssertEqual(uint32(bytes, at: 40), UInt32(samples.count * 2))
        XCTAssertEqual(int16(bytes, at: 44), 0)
        XCTAssertEqual(int16(bytes, at: 46), 16_384)
        XCTAssertEqual(int16(bytes, at: 48), -16_384)
        XCTAssertEqual(int16(bytes, at: 50), Int16.max)
        XCTAssertEqual(int16(bytes, at: 52), -Int16.max)
        XCTAssertEqual(int16(bytes, at: 54), Int16.max)  // 範囲外は切り詰める
    }

    func testWAVForCue() {
        let data = SoundSynthesizer.wavData(for: .notice)
        let samples = SoundSynthesizer.render(SoundSynthesizer.tones(for: .notice))
        XCTAssertEqual(data.count, 44 + samples.count * 2)
    }

    private func uint16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    private func int16(_ bytes: [UInt8], at offset: Int) -> Int16 {
        Int16(bitPattern: uint16(bytes, at: offset))
    }

    private func uint32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[offset + $1]) << (8 * $1) }
    }
}
