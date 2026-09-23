import AVFoundation

/// 用一条静音音频常驻后台，换来「到点准时响铃」的能力。
/// 这是巨魔安装的 App 才有的待遇：App Store 上架版本做不到。
final class BackgroundKeeper {
    static let shared = BackgroundKeeper()

    /// 由设置页控制是否启用。
    var isEnabled = false
    private(set) var isRunning = false
    private(set) var lastError: String?

    private var player: AVAudioPlayer?

    private init() {}

    /// 启动保活。如果已在运行，只会重新配置音频会话（响铃后需要恢复 mixWithOthers）。
    func start() {
        guard isEnabled else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            if isRunning { return }
            let data = WAVGenerator.silence(seconds: 3, sampleRate: 8000)
            let audioPlayer = try AVAudioPlayer(data: data)
            audioPlayer.numberOfLoops = -1
            audioPlayer.volume = 1.0
            audioPlayer.prepareToPlay()
            audioPlayer.play()
            player = audioPlayer
            isRunning = true
            lastError = nil
        } catch {
            isRunning = false
            lastError = error.localizedDescription
        }
    }

    func stop() {
        player?.stop()
        player = nil
        isRunning = false
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    func syncWithSettings(_ enabled: Bool) {
        isEnabled = enabled
        if enabled {
            start()
        } else {
            stop()
        }
    }
}

/// 内存里生成一段静音 WAV，省得往工程里塞音频文件。
enum WAVGenerator {
    static func silence(seconds: Double, sampleRate: Int = 8000) -> Data {
        let frames = Int(Double(sampleRate) * seconds)
        let byteRate = sampleRate * 2
        var data = Data()
        data.append(contentsOf: Array("RIFF".utf8))
        data.append(contentsOf: littleEndian(UInt32(36 + frames * 2)))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        data.append(contentsOf: littleEndian(UInt32(16)))
        data.append(contentsOf: littleEndian(UInt16(1)))
        data.append(contentsOf: littleEndian(UInt16(1)))
        data.append(contentsOf: littleEndian(UInt32(sampleRate)))
        data.append(contentsOf: littleEndian(UInt32(byteRate)))
        data.append(contentsOf: littleEndian(UInt16(2)))
        data.append(contentsOf: littleEndian(UInt16(16)))
        data.append(contentsOf: Array("data".utf8))
        data.append(contentsOf: littleEndian(UInt32(frames * 2)))
        data.append(Data(count: frames * 2))
        return data
    }

    private static func littleEndian<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
        withUnsafeBytes(of: value.littleEndian) { Array($0) }
    }
}
