import SwiftUI
import UserNotifications

@main
struct MorningBellApp: App {
    @StateObject private var store = AlarmStore()
    @StateObject private var settings = AppSettings()
    @ObservedObject private var engine = AlarmEngine.shared
    @ObservedObject private var weather = WeatherService.shared
    @ObservedObject private var news = NewsService.shared
    @ObservedObject private var digest = DigestService.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(settings)
                .environmentObject(engine)
                .environmentObject(weather)
                .environmentObject(news)
                .environmentObject(digest)
                .onAppear { bootstrap() }
                .onChange(of: scenePhase) { phase in
                    switch phase {
                    case .active:
                        engine.resume()
                        engine.tick()
                        if digest.digest?.date != digest.today {
                            digest.refresh()
                        }
                    case .background:
                        engine.resume()
                    default:
                        break
                    }
                }
                .fullScreenCover(item: ringingBinding) { alarm in
                    RingingView(alarm: alarm)
                        .environmentObject(engine)
                        .environmentObject(settings)
                }
        }
    }

    /// 响铃界面由引擎的 ringing 属性驱动，只能通过引擎方法关闭，避免误滑动退出。
    private var ringingBinding: Binding<Alarm?> {
        Binding(get: { engine.ringing }, set: { _ in })
    }

    private func bootstrap() {
        LaunchLog.mark("启动开始")
        let unfinishedLastTime = LaunchLog.beginLaunch()
        UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
        LaunchLog.mark("通知回调注册完成")
        engine.configure(store: store, settings: settings)
        digest.configure(settings: settings)
        SpeechService.shared.configure(settings: settings)
        LaunchLog.mark("依赖注入完成")
        engine.requestAuthorizationIfNeeded { _ in }
        LaunchLog.mark("通知授权已发起")
        engine.start(safeMode: unfinishedLastTime)
        LaunchLog.mark("闹钟引擎启动完成")
        weather.refresh(city: settings.defaultCity) { _ in }
        LaunchLog.mark("天气请求已发出")
        digest.loadFromDisk()
        LaunchLog.mark("要点快照加载完成")
        if digest.digest?.date != digest.today {
            digest.refresh()
        }
        if news.items.isEmpty {
            news.refresh(sources: settings.newsSources)
        }
        LaunchLog.mark("首页数据准备完成")
        // 界面显示出来之后再清除启动标记，避免把正常启动误判成崩溃
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            LaunchLog.finishLaunch()
        }
    }
}

/// 通知回调：锁屏上直接点「停止 / 贪睡」，或点击通知进入响铃界面。
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationDelegate()

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        let alarmId = (userInfo["alarmId"] as? String).flatMap { UUID(uuidString: $0) }
        switch response.actionIdentifier {
        case NotificationScheduler.stopAction:
            AlarmEngine.shared.stopRinging()
        case NotificationScheduler.snoozeAction:
            AlarmEngine.shared.snoozeFromNotification(alarmId: alarmId)
        default:
            AlarmEngine.shared.ringFromNotification(alarmId: alarmId)
        }
        completionHandler()
    }
}
