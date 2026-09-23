import AVFoundation
import Combine
import Foundation

/// 朗读服务。
/// 音色优先级：云端真人语音（配置了才用）→ 设备上最好的中文音色 → 系统默认中文音色。
/// 支持单条朗读与整篇顺序朗读；云端合成结果会缓存到本地。
final class SpeechService: NSObject, ObservableObject {
    static let shared = SpeechService()

    @Published private(set) var isSpeaking = false
    @Published private(set) var isSynthesizing = false
    /// 正在朗读的条目 id，界面据此把按钮换成「停止」。
    @Published private(set) var currentID: String?
    @Published var lastError: String?

    private weak var settings: AppSettings?
    private let synthesizer = AVSpeechSynthesizer()
    private var audioPlayer: AVAudioPlayer?
    private var queue: [(id: String?, text: String)] = []
    private var currentText = ""
    private var finishHandler: (() -> Void)?

    private override init() {
        super.init()
        synthesizer.delegate = self
    }

    func configure(settings: AppSettings) {
        self.settings = settings
    }

    // MARK: - 对外接口

    func speak(_ text: String, id: String? = nil, onFinish: (() -> Void)? = nil) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            onFinish?()
            return
        }
        prepareAudioSession()
        queue = [(id, text)]
        finishHandler = onFinish
        startNext()
    }

    func speakAll(_ items: [(id: String?, text: String)], onFinish: (() -> Void)? = nil) {
        guard !items.isEmpty else {
            onFinish?()
            return
        }
        prepareAudioSession()
        queue = items
        finishHandler = onFinish
        startNext()
    }

    func stop() {
        queue.removeAll()
        finishHandler = nil
        synthesizer.stopSpeaking(at: .immediate)
        audioPlayer?.stop()
        audioPlayer = nil
        isSpeaking = false
        isSynthesizing = false
        currentID = nil
        restoreKeepAliveSession()
    }

    // MARK: - 音色

    /// 设备上所有中文音色，质量高的排前面。
    static func chineseVoices() -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.lowercased().hasPrefix("zh") }
            .sorted { lhs, rhs in
                if lhs.quality.rawValue != rhs.quality.rawValue {
                    return lhs.quality.rawValue > rhs.quality.rawValue
                }
                return lhs.name < rhs.name
            }
    }

    static func qualityText(_ voice: AVSpeechSynthesisVoice) -> String {
        switch voice.quality.rawValue {
        case 3: return "高级"
        case 2: return "增强"
        default: return "标准"
        }
    }

    static func bestChineseVoice() -> AVSpeechSynthesisVoice? {
        let voices = chineseVoices()
        return voices.first { $0.language.lowercased() == "zh-cn" } ?? voices.first
    }

    var preferredSystemVoice: AVSpeechSynthesisVoice? {
        let identifier = settings?.voiceIdentifier ?? ""
        if !identifier.isEmpty, let voice = AVSpeechSynthesisVoice(identifier: identifier) {
            return voice
        }
        return SpeechService.bestChineseVoice()
    }

    /// 诊断页显示当前到底用的是哪个音色。
    var currentVoiceDescription: String {
        if let config = cloudConfig {
            return "云端真人语音 · \(config.voice)"
        }
        guard let voice = preferredSystemVoice else { return "系统默认" }
        return "\(voice.name)（\(SpeechService.qualityText(voice))）"
    }

    var isCloudEnabled: Bool {
        cloudConfig != nil
    }

    var cloudConfig: CloudTTSService.Config? {
        guard let settings = settings, settings.cloudVoiceEnabled else { return nil }
        let config = CloudTTSService.Config(key: settings.cloudTTSKey,
                                           region: settings.cloudTTSRegion,
                                           voice: settings.cloudTTSVoice)
        return CloudTTSService.shared.isConfigured(config) ? config : nil
    }

    // MARK: - 播放流程

    private func startNext() {
        guard !queue.isEmpty else {
            isSpeaking = false
            isSynthesizing = false
            currentID = nil
            let handler = finishHandler
            finishHandler = nil
            restoreKeepAliveSession()
            handler?()
            return
        }
        let next = queue.removeFirst()
        currentID = next.id
        currentText = next.text
        isSpeaking = true

        if let config = cloudConfig {
            speakWithCloud(next.text, config: config)
        } else {
            speakWithSystem(next.text)
        }
    }

    private func speakWithSystem(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = preferredSystemVoice ?? AVSpeechSynthesisVoice(language: "zh-CN")
        utterance.rate = Float(settings?.speechRate ?? 0.45)
        utterance.volume = 1.0
        utterance.postUtteranceDelay = 0.25
        synthesizer.speak(utterance)
    }

    private func speakWithCloud(_ text: String, config: CloudTTSService.Config) {
        if let cached = CloudTTSService.shared.cachedAudio(for: text, config: config) {
            playCloudAudio(cached)
            return
        }
        isSynthesizing = true
        CloudTTSService.shared.synthesize(text: text, config: config) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isSynthesizing = false
                switch result {
                case .success(let data):
                    self.lastError = nil
                    self.playCloudAudio(data)
                case .failure(let error):
                    // 云端失败自动退回系统音色，保证闹钟一定会开口
                    self.lastError = "云端语音失败，已改用系统音色：\(error.localizedDescription)"
                    self.speakWithSystem(self.currentText)
                }
            }
        }
    }

    private func playCloudAudio(_ data: Data) {
        do {
            let player = try AVAudioPlayer(data: data)
            player.delegate = self
            player.prepareToPlay()
            player.play()
            audioPlayer = player
        } catch {
            lastError = "云端语音播放失败，已改用系统音色：\(error.localizedDescription)"
            speakWithSystem(currentText)
        }
    }

    private func prepareAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.duckOthers])
        try? session.setActive(true)
    }

    /// 朗读会临时改掉音频会话，读完把保活用的会话恢复回来。
    private func restoreKeepAliveSession() {
        BackgroundKeeper.shared.start()
    }
}

extension SpeechService: AVSpeechSynthesizerDelegate {
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        startNext()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        isSpeaking = false
        currentID = nil
    }
}

extension SpeechService: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        audioPlayer = nil
        startNext()
    }
}
