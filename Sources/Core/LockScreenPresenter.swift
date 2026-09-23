import AVFoundation
import MediaPlayer
import UIKit

/// 把正在播报的内容放到锁屏 / 控制中心的「正在播放」卡片上。
///
/// iOS 14/15 没有实时活动（Live Activity 要 iOS 16.1+，锁屏小组件要 iOS 16+），
/// 所以锁屏能看到正文、并且能在锁屏上暂停/继续/停止的入口，就是 Now Playing 卡片：
/// 标题、副标题、专辑行都会显示在锁屏上，配合人工绘制的封面还能显示当天要闻。
/// 同时这里接管远程控制事件，锁屏按暂停不会打断播报队列。
final class LockScreenPresenter {
    static let shared = LockScreenPresenter()

    /// 由 SpeechService 注入。
    var onPlay: (() -> Void)?
    var onPause: (() -> Void)?
    var onStop: (() -> Void)?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?

    private var progressTimer: Timer?
    private var startedAt = Date()
    private var duration: TimeInterval = 0
    private var isPlaying = false
    private var currentTitle = ""
    private var currentSubtitle = ""
    private var currentBody = ""
    private var artworkKey = ""
    private var artwork: MPMediaItemArtwork?

    private init() {
        registerRemoteCommands()
    }

    var isActive: Bool { !currentTitle.isEmpty }

    // MARK: - 对外接口

    /// 开始一段播报：锁屏立刻显示标题与正文。
    func begin(title: String, subtitle: String, body: String) {
        currentTitle = title.isEmpty ? "晨钟 · 时政播报" : title
        currentSubtitle = subtitle
        currentBody = body
        startedAt = Date()
        duration = Self.estimatedDuration(for: body)
        isPlaying = true
        artwork = makeArtwork(title: currentTitle, subtitle: subtitle)
        publish(elapsed: 0, rate: 1)
        startProgressTimer()
        UIApplication.shared.beginReceivingRemoteControlEvents()
    }

    /// 队列切到下一段时更新显示。
    func update(title: String, subtitle: String, body: String) {
        if title != currentTitle || body != currentBody {
            currentTitle = title.isEmpty ? "晨钟 · 时政播报" : title
            currentSubtitle = subtitle
            currentBody = body
            startedAt = Date()
            duration = Self.estimatedDuration(for: body)
            artwork = makeArtwork(title: currentTitle, subtitle: subtitle)
        }
        publish(elapsed: 0, rate: isPlaying ? 1 : 0)
        startProgressTimer()
    }

    func setPlaying(_ playing: Bool) {
        isPlaying = playing
        startedAt = Date().addingTimeInterval(-currentElapsed)
        publish(elapsed: currentElapsed, rate: playing ? 1 : 0)
    }

    /// 播报结束后把卡片收起来。
    func end() {
        progressTimer?.invalidate()
        progressTimer = nil
        currentTitle = ""
        currentSubtitle = ""
        currentBody = ""
        artworkKey = ""
        artwork = nil
        isPlaying = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        UIApplication.shared.endReceivingRemoteControlEvents()
    }

    // MARK: - 内部

    private var currentElapsed: TimeInterval {
        guard isPlaying else { return 0 }
        return min(duration, max(0, Date().timeIntervalSince(startedAt)))
    }

    private func startProgressTimer() {
        progressTimer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self = self, self.isPlaying, self.isActive else { return }
            self.publish(elapsed: self.currentElapsed, rate: 1)
        }
        RunLoop.main.add(timer, forMode: .common)
        progressTimer = timer
    }

    private func publish(elapsed: TimeInterval, rate: Double) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: currentTitle,
            MPMediaItemPropertyArtist: currentSubtitle,
            // 第三行用来放正文，锁屏上尽可能多显示时政内容
            MPMediaItemPropertyAlbumTitle: Self.compact(currentBody, limit: 160),
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: rate,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue
        ]
        if let artwork = artwork {
            info[MPMediaItemPropertyArtwork] = artwork
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = rate > 0 ? .playing : .paused
    }

    private func registerRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.togglePlayPauseCommand.isEnabled = true
        center.stopCommand.isEnabled = true
        // 播报队列是按条推进的，锁屏上不提供「上一条/下一条」，避免乱序。
        center.nextTrackCommand.isEnabled = false
        center.previousTrackCommand.isEnabled = false

        center.playCommand.addTarget { [weak self] _ in
            guard let self = self, self.isActive else { return .noSuchContent }
            self.onPlay?()
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            guard let self = self, self.isActive else { return .noSuchContent }
            self.onPause?()
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self = self, self.isActive else { return .noSuchContent }
            if self.isPlaying {
                self.onPause?()
            } else {
                self.onPlay?()
            }
            return .success
        }
        center.stopCommand.addTarget { [weak self] _ in
            guard let self = self, self.isActive else { return .noSuchContent }
            self.onStop?()
            return .success
        }
    }

    /// 云端语音拿到真实音频时长后刷新进度条。
    func setDuration(_ value: TimeInterval) {
        guard value > 0, value.isFinite else { return }
        duration = value
        publish(elapsed: currentElapsed, rate: isPlaying ? 1 : 0)
    }

    /// 中文 TTS 大约每秒 4.5~5 个字，用字数估算进度条长度。
    private static func estimatedDuration(for text: String) -> TimeInterval {
        let characters = max(text.count, 1)
        return min(3600, max(20, Double(characters) / 4.6))
    }

    private static func compact(_ text: String, limit: Int) -> String {
        let flattened = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard flattened.count > limit else { return flattened }
        return String(flattened.prefix(limit)) + "…"
    }

    /// 自己画一张封面：深色底 + 绿色竖条 + 标题。锁屏上比默认图标体面得多。
    private func makeArtwork(title: String, subtitle: String) -> MPMediaItemArtwork? {
        let size = CGSize(width: 600, height: 600)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            let bounds = CGRect(origin: .zero, size: size)
            UIColor(red: 0.05, green: 0.06, blue: 0.08, alpha: 1).setFill()
            context.fill(bounds)

            let accent = UIColor(red: 0.32, green: 0.71, blue: 0.29, alpha: 1)
            accent.setFill()
            UIBezierPath(roundedRect: CGRect(x: 48, y: 70, width: 14, height: 130), cornerRadius: 7).fill()

            let titleStyle = NSMutableParagraphStyle()
            titleStyle.lineBreakMode = .byTruncatingTail
            let titleAttributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 54, weight: .bold),
                .foregroundColor: UIColor.white,
                .paragraphStyle: titleStyle
            ]
            let subtitleAttributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 30, weight: .medium),
                .foregroundColor: accent,
                .paragraphStyle: titleStyle
            ]

            let textRect = CGRect(x: 48, y: 250, width: size.width - 96, height: 200)
            (subtitle as NSString).draw(in: CGRect(x: 48, y: 200, width: size.width - 96, height: 40),
                                        withAttributes: subtitleAttributes)
            (title as NSString).draw(in: textRect, withAttributes: titleAttributes)

            let footer = "晨钟 · 时政播报"
            footer.draw(at: CGPoint(x: 48, y: size.height - 90), withAttributes: [
                .font: UIFont.systemFont(ofSize: 26, weight: .semibold),
                .foregroundColor: UIColor(white: 0.65, alpha: 1)
            ])
        }
        return MPMediaItemArtwork(boundsSize: size) { _ in image }
    }
}
