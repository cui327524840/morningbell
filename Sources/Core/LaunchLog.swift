import Foundation

/// 启动哨兵。
/// 每次启动会打一个“启动中”标记，界面正常显示后清掉。
/// 如果下次启动发现标记还在，说明上次没走完（多半是崩溃），
/// 于是自动进入安全模式（停用后台保活），并把上次停在哪一步显示出来。
enum LaunchLog {
    private static let stepKey = "morningbell.launch.step"
    private static let previousStepKey = "morningbell.launch.previousStep"
    private static let inProgressKey = "morningbell.launch.inProgress"
    private static let safeModeKey = "morningbell.launch.safeMode"

    private static var defaults: UserDefaults { UserDefaults.standard }

    static func mark(_ step: String) {
        defaults.set("\(step)（\(timestamp())）", forKey: stepKey)
    }

    /// 返回 true 表示上次启动没有走完，本次应当进入安全模式。
    @discardableResult
    static func beginLaunch() -> Bool {
        let unfinishedLastTime = defaults.bool(forKey: inProgressKey)
        defaults.set(defaults.string(forKey: stepKey) ?? "无记录", forKey: previousStepKey)
        defaults.set(true, forKey: inProgressKey)
        if unfinishedLastTime {
            defaults.set(true, forKey: safeModeKey)
        }
        return unfinishedLastTime
    }

    /// 界面已经显示出来了，清除标记。
    static func finishLaunch() {
        defaults.set(false, forKey: inProgressKey)
        defaults.removeObject(forKey: safeModeKey)
    }

    static var isSafeMode: Bool {
        defaults.bool(forKey: safeModeKey)
    }

    static var lastLaunchText: String {
        let crashed = defaults.bool(forKey: inProgressKey)
        guard crashed else { return "上次启动正常" }
        let step = defaults.string(forKey: previousStepKey) ?? "无记录"
        return "上次启动未完成，停在：\(step)"
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter.string(from: Date())
    }
}
