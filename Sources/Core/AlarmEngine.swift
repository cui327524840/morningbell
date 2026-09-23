import AVFoundation
import Combine
import Foundation
import UserNotifications

/// 闹钟引擎：负责算下一次响铃时间、到点响铃、语音播报、贪睡与停止。
/// 两种响铃方式：
/// 1. 后台保活（推荐）：App 常驻后台，到点用 AVAudioPlayer 播放，静音开关也挡不住，能播音乐和语音。
/// 2. 通知兜底：App 被强退或保活关闭时，靠本地通知响（最长 30 秒，受静音开关影响）。
final class AlarmEngine: NSObject, ObservableObject {
    static let shared = AlarmEngine()

    @Published var ringing: Alarm?
    @Published var spokenText: String = ""
    @Published var nextFireDate: Date?
    @Published var statusMessage: String = "未启动"
    @Published var weather: WeatherSnapshot?
    @Published var authorizationText: String = "未请求"
    @Published var criticalAlertsAvailable = false
    /// 安全模式：上次启动异常时，临时停用后台保活，只保留通知提醒。
    @Published var isSafeMode = false

    private weak var store: AlarmStore?
    private weak var settings: AppSettings?

    private var tickTimer: Timer?
    private var autoStopTimer: Timer?
    private var musicPlayer: AVAudioPlayer?
    private var lastFired: [UUID: Date] = [:]
    private var snoozePlan: (alarm: Alarm, date: Date)?
    private var pendingRingID: UUID?

    private override init() {
        super.init()
    }

    // MARK: - 生命周期

    func configure(store: AlarmStore, settings: AppSettings) {
        self.store = store
        self.settings = settings
    }

    func start(safeMode: Bool = false) {
        isSafeMode = safeMode || LaunchLog.isSafeMode
        NotificationScheduler.registerCategories()
        statusMessage = isSafeMode ? "安全模式：已停用后台保活" : "已启动"
        applySettings()
        startTicking()
        if let id = pendingRingID {
            pendingRingID = nil
            ringFromNotification(alarmId: id)
        }
    }

    /// 设置变化后重新应用（保活开关、播报开关、重复规则等）。
    func applySettings() {
        BackgroundKeeper.shared.syncWithSettings((settings?.keepAlive ?? false) && !isSafeMode)
        NotificationScheduler.schedule(alarms: store?.alarms ?? [],
                                       critical: settings?.criticalAlerts ?? false,
                                       fallback: settings?.notificationFallback ?? true)
        updateNextFireDate()
        refreshStatus()
    }

    /// 回到前台或进入后台时调用，确保保活和计时器都在工作。
    func resume() {
        if (settings?.keepAlive ?? false) && !isSafeMode {
            BackgroundKeeper.shared.start()
        }
        refreshStatus()
    }

    private func refreshStatus() {
        if BackgroundKeeper.shared.isRunning {
            statusMessage = "后台保活中 · 到点自动响铃"
        } else if BackgroundKeeper.shared.isEnabled {
            statusMessage = BackgroundKeeper.shared.lastError.map { "保活失败：\($0)" } ?? "保活未生效"
        } else {
            statusMessage = settings?.notificationFallback == true ? "仅通知模式" : "未启用任何提醒"
        }
    }

    // MARK: - 权限

    func requestAuthorizationIfNeeded(completion: @escaping (Bool) -> Void) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, _ in
            DispatchQueue.main.async {
                self?.authorizationText = granted ? "已授权" : "未授权"
                completion(granted)
            }
        }
    }

    /// 实验性：请求「重要警告」权限。需要巨魔额外赋予 entitlement，普通安装拿不到。
    func requestCriticalAuthorization(completion: @escaping (Bool) -> Void) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound, .badge, .criticalAlert]) { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.refreshAuthorizationStatus()
                completion(self?.criticalAlertsAvailable ?? false)
            }
        }
    }

    func refreshAuthorizationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            let text: String
            switch settings.authorizationStatus {
            case .authorized: text = "已授权"
            case .denied: text = "已拒绝"
            case .notDetermined: text = "未请求"
            case .provisional: text = "临时授权"
            case .ephemeral: text = "临时授权"
            @unknown default: text = "未知"
            }
            let critical = settings.criticalAlertSetting == .enabled
            DispatchQueue.main.async {
                self?.authorizationText = text
                self?.criticalAlertsAvailable = critical
            }
        }
    }

    // MARK: - 调度

    private func startTicking() {
        tickTimer?.invalidate()
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
        tick()
    }

    /// 每 5 秒检查一次：是否到了响铃时间 / 贪睡是否到期。
    func tick() {
        updateNextFireDate()
        guard ringing == nil else { return }
        let now = Date()

        if let plan = snoozePlan, plan.date <= now {
            snoozePlan = nil
            ring(plan.alarm, isSnooze: true)
            return
        }

        guard let store = store else { return }
        for alarm in store.alarms where alarm.isEnabled {
            guard let occurrence = occurrenceDate(atOrBefore: now, alarm: alarm) else { continue }
            guard now.timeIntervalSince(occurrence) <= 90 else { continue }
            if let fired = lastFired[alarm.id], fired == occurrence { continue }
            lastFired[alarm.id] = occurrence
            ring(alarm, isSnooze: false)
            break
        }
    }

    func updateNextFireDate() {
        let now = Date()
        nextFireDate = (store?.alarms ?? [])
            .filter { $0.isEnabled }
            .compactMap { nextFireDate(for: $0, after: now) }
            .min()
    }

    /// 下一次该闹钟响铃的时间。
    func nextFireDate(for alarm: Alarm, after now: Date) -> Date? {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: now)
        for offset in 0...7 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: startOfToday),
                  let candidate = calendar.date(bySettingHour: alarm.hour,
                                                minute: alarm.minute,
                                                second: 0,
                                                of: day),
                  candidate > now else { continue }
            if alarm.weekdays.isEmpty ||
                alarm.weekdays.contains(calendar.component(.weekday, from: candidate)) {
                return candidate
            }
        }
        return nil
    }

    /// 最近一次「本该响」的时刻（用于后台补触发，容忍 90 秒误差）。
    private func occurrenceDate(atOrBefore now: Date, alarm: Alarm) -> Date? {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: now)
        for offset in 0...1 {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: startOfToday),
                  let candidate = calendar.date(bySettingHour: alarm.hour,
                                                minute: alarm.minute,
                                                second: 0,
                                                of: day),
                  candidate <= now else { continue }
            let weekday = calendar.component(.weekday, from: candidate)
            let matches = alarm.weekdays.isEmpty ? offset == 0 : alarm.weekdays.contains(weekday)
            if matches { return candidate }
        }
        return nil
    }

    // MARK: - 响铃

    func ring(_ alarm: Alarm, isSnooze: Bool) {
        guard ringing == nil else { return }
        ringing = alarm
        spokenText = ""
        // 让闹钟抢占音频：先停掉保活的静音音频，再激活独占的播放会话。
        BackgroundKeeper.shared.stop()
        activateAlarmSession()
        playMusic(for: alarm)
        scheduleAutoStop()
        postRingNotification(alarm: alarm, isSnooze: isSnooze)
        publishLockScreenDigestCard(timeText: alarm.timeText)
        speak(for: alarm)

        if !isSnooze, alarm.weekdays.isEmpty, let store = store,
           let index = store.alarms.firstIndex(where: { $0.id == alarm.id }) {
            // 只响一次的闹钟响过以后自动关闭。
            store.alarms[index].isEnabled = false
            NotificationScheduler.schedule(alarms: store.alarms,
                                           critical: settings?.criticalAlerts ?? false,
                                           fallback: settings?.notificationFallback ?? true)
        }
    }

    func stopRinging() {
        guard let alarm = ringing else { return }
        lastFired[alarm.id] = Date()
        stopAudio()
        ringing = nil
        snoozePlan = nil
        resume()
        NotificationScheduler.schedule(alarms: store?.alarms ?? [],
                                       critical: settings?.criticalAlerts ?? false,
                                       fallback: settings?.notificationFallback ?? true)
        updateNextFireDate()
    }

    func snooze() {
        guard let alarm = ringing else { return }
        let minutes = max(1, alarm.snoozeMinutes)
        stopAudio()
        ringing = nil
        lastFired[alarm.id] = nil
        snoozePlan = (alarm, Date().addingTimeInterval(TimeInterval(minutes * 60)))
        statusMessage = "已贪睡 \(minutes) 分钟"
        resume()
        // 保活运行时由 App 自己响铃，不需要再排一条通知；只有通知模式下才排。
        guard !(settings?.keepAlive ?? false) else { return }
        let content = UNMutableNotificationContent()
        content.title = alarm.label.isEmpty ? "闹钟" : alarm.label
        content.body = "\(minutes) 分钟后再响"
        content.sound = SoundLibrary.shared.notificationSound(for: alarm.soundFileName)
        content.categoryIdentifier = NotificationScheduler.categoryId
        content.userInfo = ["alarmId": alarm.id.uuidString]
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(minutes * 60), repeats: false)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "snooze-\(alarm.id.uuidString)",
                                                                    content: content,
                                                                    trigger: trigger))
    }

    /// 从通知的动作或点击进入时触发响铃（App 可能刚从冷启动被拉起）。
    func ringFromNotification(alarmId: UUID?) {
        guard ringing == nil else { return }
        guard let alarmId = alarmId else { return }
        guard store != nil else {
            pendingRingID = alarmId
            return
        }
        guard let alarm = store?.alarm(with: alarmId) else { return }
        ring(alarm, isSnooze: false)
    }

    func snoozeFromNotification(alarmId: UUID?) {
        if ringing != nil {
            snooze()
            return
        }
        guard let alarmId = alarmId, let alarm = store?.alarm(with: alarmId) else { return }
        let minutes = max(1, alarm.snoozeMinutes)
        snoozePlan = (alarm, Date().addingTimeInterval(TimeInterval(minutes * 60)))
        statusMessage = "已贪睡 \(minutes) 分钟"
    }

    private func activateAlarmSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [])
        try? session.setActive(true)
    }

    private func playMusic(for alarm: Alarm) {
        musicPlayer?.stop()
        guard let url = SoundLibrary.shared.url(for: alarm.soundFileName),
              let player = try? AVAudioPlayer(contentsOf: url) else { return }
        player.numberOfLoops = -1
        player.volume = alarm.wantsSpeech ? 0.25 : 1.0
        player.prepareToPlay()
        player.play()
        musicPlayer = player
    }

    private func scheduleAutoStop() {
        autoStopTimer?.invalidate()
        let minutes = max(1, settings?.autoStopMinutes ?? 10)
        let timer = Timer(timeInterval: TimeInterval(minutes * 60), repeats: false) { [weak self] _ in
            self?.stopRinging()
        }
        RunLoop.main.add(timer, forMode: .common)
        autoStopTimer = timer
    }

    private func stopAudio() {
        SpeechService.shared.stop()
        musicPlayer?.stop()
        musicPlayer = nil
        autoStopTimer?.invalidate()
        autoStopTimer = nil
    }

    private func postRingNotification(alarm: Alarm, isSnooze: Bool) {
        let content = UNMutableNotificationContent()
        content.title = alarm.label.isEmpty ? "闹钟" : alarm.label
        content.body = isSnooze ? "\(alarm.timeText) · 贪睡结束" : "\(alarm.timeText) · 该起床了"
        content.sound = SoundLibrary.shared.notificationSound(for: alarm.soundFileName)
        applyLockScreenDigest(to: content, wantsDigest: !isSnooze)
        content.categoryIdentifier = NotificationScheduler.categoryId
        content.userInfo = ["alarmId": alarm.id.uuidString]
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        UNUserNotificationCenter.current()
            .add(UNNotificationRequest(identifier: "ring-\(alarm.id.uuidString)-\(Int(Date().timeIntervalSince1970))",
                                       content: content,
                                       trigger: trigger))
    }

    // MARK: - 语音播报

    private func speak(for alarm: Alarm) {
        guard settings?.voiceEnabled ?? true, alarm.wantsSpeech else {
            musicPlayer?.volume = 1.0
            return
        }
        var parts: [String] = []
        if alarm.speakTime {
            parts.append(dateGreeting())
        }
        // 顺序：今天是几月几号星期几 → 天气 → 今日时政
        var newsText: String?
        if alarm.speakNews {
            let limit = alarm.newsLimit
            let style = NewsSpeechStyle(rawValue: alarm.newsSpeechStyle) ?? .full
            let digestText: String?
            switch style {
            case .title:
                digestText = DigestService.shared.spokenHeadlines(limit: limit > 0 ? limit : 3)
            case .brief:
                digestText = DigestService.shared.spokenDigest(limit: limit)
            case .full:
                digestText = DigestService.shared.spokenFullDigest(limit: limit)
            }
            newsText = digestText ?? NewsService.shared.topHeadlines(limit: 2)
        }

        let city = alarm.cityName.isEmpty ? (settings?.defaultCity ?? "北京") : alarm.cityName
        guard alarm.speakWeather else {
            if let newsText = newsText { parts.append(newsText) }
            finishSpeech(parts: parts)
            return
        }
        WeatherService.shared.refresh(city: city) { [weak self] snapshot in
            guard let self = self else { return }
            self.weather = snapshot
            var allParts = parts
            if let snapshot = snapshot {
                allParts.append(snapshot.spokenText)
            } else {
                allParts.append("天气暂时获取不到。")
            }
            if let newsText = newsText {
                allParts.append(newsText)
            }
            self.finishSpeech(parts: allParts)
        }
    }

    private func finishSpeech(parts: [String]) {
        let sentences = parts
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "。")) }
            .filter { !$0.isEmpty }
        guard !sentences.isEmpty else { return }
        speakText(sentences.joined(separator: "。") + "。")
    }

    /// 统一走 SpeechService：自动使用设备上最好的中文音色，开启云端语音时用真人音色。
    func speakText(_ text: String) {
        guard !text.isEmpty else { return }
        spokenText = text
        if ringing != nil {
            // 响铃时：念完后把音乐音量恢复到满
            SpeechService.shared.speak(text, onFinish: { [weak self] in
                self?.musicPlayer?.setVolume(1.0, fadeDuration: 1.0)
            })
        } else {
            SpeechService.shared.speak(text)
        }
    }

    /// 试听用：不占用响铃状态。
    func previewSpeech() {
        activateAlarmSession()
        let sample = "\(dateGreeting())。这是语音播报的试听效果，今天\(settings?.defaultCity ?? "北京")晴，气温 12 到 22 度。"
        speakText(sample)
    }

    /// 「今天是 2026 年 9 月 23 日，星期三，现在是早上 6 点 50 分」
    private func dateGreeting() -> String {
        let now = Date()
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month, .day, .weekday, .hour, .minute], from: now)
        let weekdayNames = ["日", "一", "二", "三", "四", "五", "六"]
        let weekdayIndex = (components.weekday ?? 1) - 1
        let weekday = weekdayNames.indices.contains(weekdayIndex) ? weekdayNames[weekdayIndex] : ""
        let hour = components.hour ?? 0
        let period: String
        switch hour {
        case 0..<5: period = "凌晨"
        case 5..<8: period = "早上"
        case 8..<11: period = "上午"
        case 11..<13: period = "中午"
        case 13..<17: period = "下午"
        case 17..<19: period = "傍晚"
        default: period = "晚上"
        }
        let minute = components.minute ?? 0
        let minuteText = minute == 0 ? "整" : "\(minute)分"
        return "今天是\(components.year ?? 0)年\(components.month ?? 0)月\(components.day ?? 0)日，星期\(weekday)，现在是\(period)\(hour)点\(minuteText)"
    }
}

enum NotificationScheduler {
    static let categoryId = "ALARM_RING"
    static let stopAction = "STOP"
    static let snoozeAction = "SNOOZE"

    static func registerCategories() {
        let stop = UNNotificationAction(identifier: stopAction, title: "停止", options: [.destructive])
        let snooze = UNNotificationAction(identifier: snoozeAction, title: "贪睡", options: [])
        let category = UNNotificationCategory(identifier: categoryId,
                                              actions: [stop, snooze],
                                              intentIdentifiers: [],
                                              options: [])
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    static func schedule(alarms: [Alarm], critical: Bool, fallback: Bool) {
        let center = UNUserNotificationCenter.current()
        // 只清理本 App 的闹钟通知，别把贪睡通知一起删掉。
        center.getPendingNotificationRequests { requests in
            let stale = requests
                .map { $0.identifier }
                .filter { $0.hasPrefix(alarmIdentifierPrefix) }
            center.removePendingNotificationRequests(withIdentifiers: stale)
            guard fallback else { return }
            for alarm in alarms where alarm.isEnabled {
                add(alarm: alarm, critical: critical, center: center)
            }
        }
    }

    private static let alarmIdentifierPrefix = "alarm-"

    private static func add(alarm: Alarm, critical: Bool, center: UNUserNotificationCenter) {
            let content = UNMutableNotificationContent()
            content.title = alarm.label.isEmpty ? "闹钟" : alarm.label
            content.body = "\(alarm.timeText) · 点击进入响铃界面"
            content.sound = SoundLibrary.shared.notificationSound(for: alarm.soundFileName)
            content.categoryIdentifier = categoryId
            content.userInfo = ["alarmId": alarm.id.uuidString]
            if critical {
                // 重要警告是 iOS 15 才有的能力，旧系统上自动跳过
                if #available(iOS 15.0, *) {
                    content.interruptionLevel = .critical
                }
            }

            let weekdays: [Int] = alarm.weekdays.isEmpty ? [0] : Array(alarm.weekdays)
            for weekday in weekdays {
                var components = DateComponents()
                components.hour = alarm.hour
                components.minute = alarm.minute
                if weekday != 0 {
                    components.weekday = weekday
                }
                let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: weekday != 0)
                let request = UNNotificationRequest(identifier: "\(alarmIdentifierPrefix)\(alarm.id.uuidString)-\(weekday)",
                                                    content: content,
                                                    trigger: trigger)
                center.add(request)
            }
    }
}
