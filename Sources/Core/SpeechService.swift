import AVFoundation
import Combine
import Foundation

/// 朗读服务：时政要点可以单条朗读，也可以整篇顺序朗读（像听广播一样）。
final class SpeechService: NSObject, ObservableObject {
    static let shared = SpeechService()

    @Published private(set) var isSpeaking = false
    /// 正在朗读的条目 id，用来把按钮显示成「停止」。
    @Published private(set) var currentID: String?

    private weak var settings: AppSettings?
    private let synthesizer = AVSpeechSynthesizer()
    private var queue: [(id: String?, text: String)] = []

    private override init() {
        super.init()
        synthesizer.delegate = self
    }

    func configure(settings: AppSettings) {
        self.settings = settings
    }

    /// 朗读一段文字。
    func speak(_ text: String, id: String? = nil) {
        guard !text.isEmpty else { return }
        prepareAudioSession()
        queue = [(id, text)]
        startNext()
    }

    /// 顺序朗读多条（整篇要点）。
    func speakAll(_ items: [(id: String?, text: String)]) {
        guard !items.isEmpty else { return }
        prepareAudioSession()
        queue = items
        startNext()
    }

    func stop() {
        queue.removeAll()
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
        currentID = nil
        restoreKeepAliveSession()
    }

    private func startNext() {
        guard !queue.isEmpty else {
            isSpeaking = false
            currentID = nil
            restoreKeepAliveSession()
            return
        }
        let next = queue.removeFirst()
        currentID = next.id
        isSpeaking = true
        let utterance = AVSpeechUtterance(string: next.text)
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        utterance.rate = Float(settings?.speechRate ?? 0.45)
        utterance.volume = 1.0
        utterance.postUtteranceDelay = 0.25
        synthesizer.speak(utterance)
    }

    private func prepareAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.duckOthers])
        try? session.setActive(true)
    }

    /// 朗读会临时改掉音频会话，读完把保活用的会话恢复回来，避免闹钟失去后台常驻。
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
