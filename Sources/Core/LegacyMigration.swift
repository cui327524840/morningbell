import Foundation

/// 一次性迁移：把老版本留下来的「经典闹铃 + 只念标题」改成新的默认值。
///
/// 背景：早期版本把 `alarm_default`（经典闹铃）写进了每个闹钟的
/// `soundFileName`，也把默认播报档位写成了「只念标题」。改默认值对他们无效，
/// 因为 UserDefaults 里的旧值永远优先。这里做一次带版本号的迁移。
enum LegacyMigration {
    private static let soundFlagKey = "morningbell.migration.soundAndSpeech.v2"
    private static let defaultSoundFlagKey = "morningbell.migration.defaultSound.v2"
    private static let alarmsStorageKey = "morningbell.alarms.v1"

    /// 闹钟级迁移：铃声留空表示「跟随全局默认」（内置轻音乐），播报改成全文。
    static func migrateAlarms(_ alarms: [Alarm]) -> [Alarm] {
        guard !UserDefaults.standard.bool(forKey: soundFlagKey) else { return alarms }
        UserDefaults.standard.set(true, forKey: soundFlagKey)

        var migrated = alarms
        var changed = false
        for index in migrated.indices {
            if migrated[index].soundFileName == "alarm_default" {
                migrated[index].soundFileName = nil
                changed = true
            }
            if migrated[index].newsSpeechStyle != NewsSpeechStyle.full.rawValue {
                migrated[index].newsSpeechStyle = NewsSpeechStyle.full.rawValue
                changed = true
            }
        }
        guard changed, let data = try? JSONEncoder().encode(migrated) else { return migrated }
        UserDefaults.standard.set(data, forKey: alarmsStorageKey)
        return migrated
    }

    /// 全局默认铃声：旧值可能是「经典闹铃」，统一改回内置轻音乐。
    static func migratedDefaultSoundName(current: String) -> String {
        guard !UserDefaults.standard.bool(forKey: defaultSoundFlagKey) else { return current }
        UserDefaults.standard.set(true, forKey: defaultSoundFlagKey)
        guard current.isEmpty || current == "alarm_default" else { return current }
        UserDefaults.standard.set("", forKey: "defaultSoundFileName")
        return ""
    }
}
