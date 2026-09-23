import Combine
import Foundation
import SwiftUI

final class AlarmStore: ObservableObject {
    @Published var alarms: [Alarm] = [] {
        didSet { persist() }
    }

    private let storageKey = "morningbell.alarms.v1"
    private var isLoaded = false

    init() {
        load()
    }

    func load() {
        defer { isLoaded = true }
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([Alarm].self, from: data) else {
            alarms = Self.seed
            return
        }
        alarms = decoded
    }

    private func persist() {
        guard isLoaded else { return }
        guard let data = try? JSONEncoder().encode(alarms) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    func add(_ alarm: Alarm) {
        alarms.append(alarm)
        sortAlarms()
    }

    func update(_ alarm: Alarm) {
        guard let index = alarms.firstIndex(where: { $0.id == alarm.id }) else { return }
        alarms[index] = alarm
        sortAlarms()
    }

    func remove(at offsets: IndexSet) {
        alarms.remove(atOffsets: offsets)
    }

    func remove(id: UUID) {
        alarms.removeAll { $0.id == id }
    }

    func alarm(with id: UUID) -> Alarm? {
        alarms.first { $0.id == id }
    }

    private func sortAlarms() {
        alarms.sort { lhs, rhs in
            if lhs.hour != rhs.hour { return lhs.hour < rhs.hour }
            return lhs.minute < rhs.minute
        }
    }

    private static var seed: [Alarm] {
        var alarm = Alarm()
        alarm.hour = 6
        alarm.minute = 50
        alarm.label = "起床 · 晨读时政"
        alarm.weekdays = [2, 3, 4, 5, 6]
        alarm.speakNews = true
        return [alarm]
    }
}

final class AppSettings: ObservableObject {
    private let defaults = UserDefaults.standard
    private var isLoaded = false

    /// 后台保活：让 App 常驻，实现到点准时响铃（会耗电）。
    @Published var keepAlive: Bool = true {
        didSet { save(keepAlive, "keepAlive") }
    }
    /// 通知兜底：App 被强退或保活关闭时，靠本地通知提醒。
    @Published var notificationFallback: Bool = true {
        didSet { save(notificationFallback, "notificationFallback") }
    }
    /// 实验性：尝试使用「重要警告」（需要巨魔赋予额外权限，静音也能响）。
    @Published var criticalAlerts: Bool = false {
        didSet { save(criticalAlerts, "criticalAlerts") }
    }
    @Published var voiceEnabled: Bool = true {
        didSet { save(voiceEnabled, "voiceEnabled") }
    }
    @Published var speechRate: Double = 0.45 {
        didSet { save(speechRate, "speechRate") }
    }
    @Published var autoStopMinutes: Int = 20 {
        didSet { save(autoStopMinutes, "autoStopMinutes") }
    }
    @Published var defaultCity: String = "北京" {
        didSet { save(defaultCity, "defaultCity") }
    }
    @Published var newsSources: [NewsSource] = AppSettings.defaultSources {
        didSet { persistSources() }
    }
    /// 每日时政要点的内容仓库，格式「用户名/仓库名」。
    @Published var digestRepo: String = "" {
        didSet { save(digestRepo, "digestRepo") }
    }
    /// 自定义接口前缀（可留空）。填了会排在三个默认镜像之后作为补充。
    @Published var digestCustomURL: String = "" {
        didSet { save(digestCustomURL, "digestCustomURL") }
    }
    /// 系统朗读音色（AVSpeechSynthesisVoice.identifier），空字符串表示自动挑设备上最好的。
    @Published var voiceIdentifier: String = "" {
        didSet { save(voiceIdentifier, "voiceIdentifier") }
    }
    /// 是否使用云端真人语音（微软 Azure 语音服务）。
    @Published var cloudVoiceEnabled: Bool = false {
        didSet { save(cloudVoiceEnabled, "cloudVoiceEnabled") }
    }
    @Published var cloudTTSKey: String = "" {
        didSet { save(cloudTTSKey, "cloudTTSKey") }
    }
    @Published var cloudTTSRegion: String = "eastasia" {
        didSet { save(cloudTTSRegion, "cloudTTSRegion") }
    }
    @Published var cloudTTSVoice: String = "zh-CN-XiaoxiaoNeural" {
        didSet { save(cloudTTSVoice, "cloudTTSVoice") }
    }
    /// 默认铃声：内置铃声音名或用户导入的音频文件名。空字符串表示内置轻音乐。
    @Published var defaultSoundFileName: String = "" {
        didSet { save(defaultSoundFileName, "defaultSoundFileName") }
    }

    init() {
        keepAlive = defaults.object(forKey: "keepAlive") as? Bool ?? true
        notificationFallback = defaults.object(forKey: "notificationFallback") as? Bool ?? true
        criticalAlerts = defaults.object(forKey: "criticalAlerts") as? Bool ?? false
        voiceEnabled = defaults.object(forKey: "voiceEnabled") as? Bool ?? true
        speechRate = defaults.object(forKey: "speechRate") as? Double ?? 0.45
        autoStopMinutes = defaults.object(forKey: "autoStopMinutes") as? Int ?? 20
        defaultCity = defaults.string(forKey: "defaultCity") ?? "北京"
        digestRepo = defaults.string(forKey: "digestRepo") ?? ""
        digestCustomURL = defaults.string(forKey: "digestCustomURL") ?? ""
        voiceIdentifier = defaults.string(forKey: "voiceIdentifier") ?? ""
        cloudVoiceEnabled = defaults.object(forKey: "cloudVoiceEnabled") as? Bool ?? false
        cloudTTSKey = defaults.string(forKey: "cloudTTSKey") ?? ""
        cloudTTSRegion = defaults.string(forKey: "cloudTTSRegion") ?? "eastasia"
        cloudTTSVoice = defaults.string(forKey: "cloudTTSVoice") ?? "zh-CN-XiaoxiaoNeural"
        defaultSoundFileName = defaults.string(forKey: "defaultSoundFileName") ?? ""
        loadSources()
        isLoaded = true
    }

    private func save(_ value: Any, _ key: String) {
        guard isLoaded else { return }
        defaults.set(value, forKey: key)
    }

    private func loadSources() {
        guard let data = defaults.data(forKey: "newsSources"),
              let decoded = try? JSONDecoder().decode([NewsSource].self, from: data),
              !decoded.isEmpty else {
            newsSources = Self.defaultSources
            return
        }
        newsSources = decoded
    }

    private func persistSources() {
        guard isLoaded else { return }
        guard let data = try? JSONEncoder().encode(newsSources) else { return }
        defaults.set(data, forKey: "newsSources")
    }

    static var defaultSources: [NewsSource] {
        [
            NewsSource(name: "中国政府网 · 最新政策", url: "https://rsshub.app/gov/zhengce/zuixin"),
            NewsSource(name: "中新网 · 滚动新闻", url: "https://www.chinanews.com.cn/rss/scroll-news.xml"),
            NewsSource(name: "人民网 · 时政", url: "http://www.people.com.cn/rss/politics.xml")
        ]
    }
}
