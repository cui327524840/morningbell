import Foundation

struct Alarm: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var hour: Int = 6
    var minute: Int = 50
    var label: String = "起床"
    /// 1 = 周日 … 7 = 周六。空集合表示只响一次。
    var weekdays: Set<Int> = []
    var isEnabled: Bool = true
    /// 贪睡分钟数，0 表示不允许贪睡。
    var snoozeMinutes: Int = 5
    /// 自定义铃声的文件名（位于 App 的 Documents 目录）；nil 表示内置铃声。
    var soundFileName: String?
    var speakTime: Bool = true
    var speakWeather: Bool = true
    /// 起床时顺带播报今日时政要点（默认打开，这是这个 App 的主打功能）。
    var speakNews: Bool = true
    /// 播报时连简报一起念（默认打开；只念标题的话内容太少）。
    var speakNewsDetail: Bool = true
    /// 播报条数：0 表示当天全部。
    var newsLimit: Int = 0
    /// 该闹钟单独指定的城市；为空则使用设置里的默认城市。
    var cityName: String = ""

    var timeText: String {
        String(format: "%02d:%02d", hour, minute)
    }

    var repeatText: String {
        if weekdays.isEmpty { return "仅一次" }
        if weekdays.count == 7 { return "每天" }
        if weekdays == Set([2, 3, 4, 5, 6]) { return "工作日" }
        if weekdays == Set([1, 7]) { return "周末" }
        return Weekday.ordered
            .filter { weekdays.contains($0) }
            .map { "周" + Weekday.short($0) }
            .joined(separator: " ")
    }

    var wantsSpeech: Bool {
        speakTime || speakWeather || speakNews
    }

    private enum CodingKeys: String, CodingKey {
        case id, hour, minute, label, weekdays, isEnabled, snoozeMinutes
        case soundFileName, speakTime, speakWeather, speakNews, speakNewsDetail, newsLimit, cityName
    }

    init() {}

    /// 自己实现解码：以后往 Alarm 里加字段时，旧数据也能正常读出来，不会丢闹钟。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        hour = try container.decodeIfPresent(Int.self, forKey: .hour) ?? 6
        minute = try container.decodeIfPresent(Int.self, forKey: .minute) ?? 50
        label = try container.decodeIfPresent(String.self, forKey: .label) ?? "起床"
        weekdays = try container.decodeIfPresent(Set<Int>.self, forKey: .weekdays) ?? []
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        snoozeMinutes = try container.decodeIfPresent(Int.self, forKey: .snoozeMinutes) ?? 5
        soundFileName = try container.decodeIfPresent(String.self, forKey: .soundFileName)
        speakTime = try container.decodeIfPresent(Bool.self, forKey: .speakTime) ?? true
        speakWeather = try container.decodeIfPresent(Bool.self, forKey: .speakWeather) ?? true
        speakNews = try container.decodeIfPresent(Bool.self, forKey: .speakNews) ?? true
        speakNewsDetail = try container.decodeIfPresent(Bool.self, forKey: .speakNewsDetail) ?? true
        newsLimit = try container.decodeIfPresent(Int.self, forKey: .newsLimit) ?? 0
        cityName = try container.decodeIfPresent(String.self, forKey: .cityName) ?? ""
    }
}

enum Weekday {
    /// 周一 … 周日
    static let ordered = [2, 3, 4, 5, 6, 7, 1]
    private static let names = ["日", "一", "二", "三", "四", "五", "六"]

    static func short(_ weekday: Int) -> String {
        let index = weekday - 1
        guard names.indices.contains(index) else { return "?" }
        return names[index]
    }
}

struct WeatherSnapshot: Codable, Equatable {
    var cityName: String
    var temperature: Double
    var apparentTemperature: Double
    var weatherCode: Int
    var description: String
    var high: Double
    var low: Double
    var precipitationProbability: Int?
    var updatedAt: Date

    var shortText: String {
        String(format: "%@ %.0f°（%.0f° ~ %.0f°）", description, temperature, low, high)
    }

    var detailText: String {
        var text = shortText
        if let probability = precipitationProbability {
            text += " · 降水概率 \(probability)%"
        }
        return text
    }

    /// 起床语音播报用的句子。
    var spokenText: String {
        var text = "今天\(cityName)\(description)，气温\(Int(low.rounded()))到\(Int(high.rounded()))度，当前\(Int(temperature.rounded()))度"
        if let probability = precipitationProbability, probability >= 30 {
            text += "，降水概率百分之\(probability)"
        }
        return text + "。"
    }
}

struct NewsItem: Identifiable, Codable, Equatable {
    var title: String
    var link: String
    var source: String
    var published: Date?
    var summary: String

    var id: String {
        link.isEmpty ? title + "|" + source : link
    }
}

struct NewsSource: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    var url: String
    var isEnabled: Bool = true
}

enum WeatherCode {
    static func describe(_ code: Int) -> String {
        switch code {
        case 0: return "晴"
        case 1: return "晴间少云"
        case 2: return "局部多云"
        case 3: return "阴"
        case 45, 48: return "有雾"
        case 51, 53, 55: return "毛毛雨"
        case 56, 57: return "冻毛毛雨"
        case 61: return "小雨"
        case 63: return "中雨"
        case 65: return "大雨"
        case 66, 67: return "冻雨"
        case 71: return "小雪"
        case 73: return "中雪"
        case 75: return "大雪"
        case 77: return "米雪"
        case 80, 81, 82: return "阵雨"
        case 85, 86: return "阵雪"
        case 95: return "雷阵雨"
        case 96, 99: return "雷暴伴冰雹"
        default: return "天气未知"
        }
    }
}
