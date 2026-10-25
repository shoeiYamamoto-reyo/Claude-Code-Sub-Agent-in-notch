import Foundation

/// 効果音を作る 1 つの音（正弦波と倍音）。周波数は始まりから終わりまで滑らかに変えられる。
public struct SoundTone: Sendable, Equatable {
    /// 鳴り始める時刻（秒、音全体の先頭から）。
    public var start: TimeInterval
    public var duration: TimeInterval
    /// 始まりの周波数（Hz）。
    public var frequency: Double
    /// 終わりの周波数（Hz）。始まりと同じならグライドしない。
    public var endFrequency: Double
    /// 最大振幅（0〜1）。
    public var amplitude: Double
    /// 2 倍音、3 倍音…の相対的な大きさ。
    public var harmonics: [Double]

    public init(
        start: TimeInterval,
        duration: TimeInterval,
        frequency: Double,
        endFrequency: Double? = nil,
        amplitude: Double,
        harmonics: [Double] = []
    ) {
        self.start = start
        self.duration = duration
        self.frequency = frequency
        self.endFrequency = endFrequency ?? frequency
        self.amplitude = amplitude
        self.harmonics = harmonics
    }

    public var end: TimeInterval { start + duration }
}

/// 効果音のレシピと合成。音声ファイルを持たず、起動時にコードから PCM を作る。
///
/// 音色はどれもこのアプリのオリジナル（coucou の音は別ライセンスのため使わない）。
/// キャラクターに合わせて、短く（0.5 秒未満）、丸い（正弦波主体の）音にしている。
public enum SoundSynthesizer {
    public static let sampleRate = 44_100
    /// 合成後のピークの上限。音割れしないように、これを超えたら全体を縮める。
    public static let peakLimit: Float = 0.9
    /// 鳴り始めの立ち上がり（クリック音を防ぐ）。
    static let attack: TimeInterval = 0.004
    /// 鳴り終わりのフェード（クリック音を防ぐ）。
    static let release: TimeInterval = 0.012

    // 音名と周波数（Hz）。
    private static let g5 = 783.99
    private static let c6 = 1046.50
    private static let e6 = 1318.51
    private static let g6 = 1567.98
    private static let c7 = 2093.00

    public static func tones(for cue: SoundCue) -> [SoundTone] {
        switch cue {
        case .expand:
            // 「ぽわん」: 下から上へ短く持ち上がる。
            [
                SoundTone(start: 0, duration: 0.12, frequency: 520, endFrequency: 800, amplitude: 0.42, harmonics: [0.2]),
                SoundTone(start: 0.05, duration: 0.10, frequency: 1040, endFrequency: 1200, amplitude: 0.12),
            ]
        case .collapse:
            // 開く音の逆向きで、小さめ。
            [
                SoundTone(start: 0, duration: 0.11, frequency: 760, endFrequency: 480, amplitude: 0.3, harmonics: [0.15]),
            ]
        case .notice:
            // 「ピコン」: 2 音。
            [
                SoundTone(start: 0, duration: 0.12, frequency: c6, amplitude: 0.38, harmonics: [0.2, 0.05]),
                SoundTone(start: 0.09, duration: 0.24, frequency: g6, amplitude: 0.38, harmonics: [0.15]),
            ]
        case .approval:
            // 上がる 3 音。お知らせより少し急ぎ。
            [
                SoundTone(start: 0, duration: 0.10, frequency: g5, amplitude: 0.36, harmonics: [0.2]),
                SoundTone(start: 0.08, duration: 0.10, frequency: c6, amplitude: 0.36, harmonics: [0.2]),
                SoundTone(start: 0.16, duration: 0.26, frequency: e6, amplitude: 0.38, harmonics: [0.15]),
            ]
        case .question:
            // 「ん？」: 語尾が上がる。
            [
                SoundTone(start: 0, duration: 0.16, frequency: 620, endFrequency: 930, amplitude: 0.4, harmonics: [0.25]),
                SoundTone(start: 0.19, duration: 0.12, frequency: 1240, amplitude: 0.25),
            ]
        case .finished:
            // 「できた」: ド・ミ・ソ・ド の分散和音。
            [
                SoundTone(start: 0, duration: 0.10, frequency: c6, amplitude: 0.34, harmonics: [0.15]),
                SoundTone(start: 0.07, duration: 0.10, frequency: e6, amplitude: 0.32, harmonics: [0.15]),
                SoundTone(start: 0.14, duration: 0.10, frequency: g6, amplitude: 0.3, harmonics: [0.1]),
                SoundTone(start: 0.21, duration: 0.26, frequency: c7, amplitude: 0.26),
            ]
        case .error:
            // 下がる 2 音。奇数倍音を少し混ぜて、ほかの音と聞き分けやすくする。
            [
                SoundTone(start: 0, duration: 0.14, frequency: 466, endFrequency: 415, amplitude: 0.4, harmonics: [0, 0.3]),
                SoundTone(start: 0.16, duration: 0.24, frequency: 370, endFrequency: 311, amplitude: 0.4, harmonics: [0, 0.3]),
            ]
        }
    }

    /// 音全体の長さ（秒）。
    public static func duration(of tones: [SoundTone]) -> TimeInterval {
        tones.map(\.end).max() ?? 0
    }

    /// モノラルの PCM（-1〜1）を作る。
    public static func render(_ tones: [SoundTone], sampleRate: Int = sampleRate) -> [Float] {
        let count = Int((duration(of: tones) * Double(sampleRate)).rounded(.up))
        guard count > 0 else { return [] }
        var samples = [Float](repeating: 0, count: count)
        let rate = Double(sampleRate)

        for tone in tones where tone.duration > 0 {
            let first = Int((tone.start * rate).rounded())
            let length = Int((tone.duration * rate).rounded())
            var phase = 0.0
            for i in 0..<length where first + i < count {
                let t = Double(i) / rate
                let progress = t / tone.duration
                // 周波数は指数的に変える（耳には一定の速さで上がり下がりして聞こえる）。
                let frequency = tone.frequency * pow(tone.endFrequency / tone.frequency, progress)
                phase += 2 * .pi * frequency / rate
                var value = sin(phase)
                for (index, level) in tone.harmonics.enumerated() where level != 0 {
                    value += level * sin(phase * Double(index + 2))
                }
                samples[first + i] += Float(tone.amplitude * envelope(at: t, duration: tone.duration) * value)
            }
        }

        let peak = samples.map(abs).max() ?? 0
        if peak > peakLimit {
            let scale = peakLimit / peak
            for i in samples.indices { samples[i] *= scale }
        }
        return samples
    }

    /// 立ち上がり → 指数的な減衰 → 最後のフェードで 0。
    static func envelope(at t: TimeInterval, duration: TimeInterval) -> Double {
        let rise = min(1, t / attack)
        let decay = exp(-3 * t / duration)
        let fall = min(1, max(0, (duration - t) / release))
        return rise * decay * fall
    }

    /// 16 bit モノラルの WAV にする（`AVAudioPlayer(data:)` で読める形式）。
    public static func wavData(_ samples: [Float], sampleRate: Int = sampleRate) -> Data {
        let bytesPerSample = 2
        let dataSize = samples.count * bytesPerSample
        var data = Data(capacity: 44 + dataSize)
        func append(_ string: String) { data.append(contentsOf: Array(string.utf8)) }
        func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }

        append("RIFF")
        append32(UInt32(36 + dataSize))
        append("WAVE")
        append("fmt ")
        append32(16)  // fmt チャンクの大きさ
        append16(1)  // PCM
        append16(1)  // モノラル
        append32(UInt32(sampleRate))
        append32(UInt32(sampleRate * bytesPerSample))  // 1 秒あたりのバイト数
        append16(UInt16(bytesPerSample))  // 1 サンプルのバイト数
        append16(16)  // ビット数
        append("data")
        append32(UInt32(dataSize))
        for sample in samples {
            let clamped = max(-1, min(1, sample))
            append16(UInt16(bitPattern: Int16((clamped * Float(Int16.max)).rounded())))
        }
        return data
    }

    /// `cue` の WAV。
    public static func wavData(for cue: SoundCue) -> Data {
        wavData(render(tones(for: cue)))
    }
}
