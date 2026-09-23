import Foundation

extension DigestService {
    /// 锁屏通知正文：把今天的时政要点逐条列出来，不解锁也能扫一眼。
    func lockScreenText(limit: Int = 8) -> String? {
        let items = digest?.newsItems ?? []
        guard !items.isEmpty else { return nil }

        let shown = limit > 0 ? Array(items.prefix(limit)) : items
        let dateText = digest?.date ?? today
        var lines: [String] = ["\(dateText) · 共 \(items.count) 条"]
        for (index, item) in shown.enumerated() {
            lines.append("\(index + 1). \(item.title)")
        }
        if items.count > shown.count {
            lines.append("…还有 \(items.count - shown.count) 条，点开看全文")
        }
        return lines.joined(separator: "\n")
    }

    /// 播报队列（带标题，供锁屏「正在播放」卡片显示）。
    func fullSpeechEntries(limit: Int = 0) -> [SpeechEntry] {
        let all = digest?.newsItems ?? []
        let items = limit > 0 ? Array(all.prefix(limit)) : all
        return items.enumerated().map { index, item in
            SpeechEntry(
                id: item.id,
                title: "第\(index + 1)条 · \(item.title)",
                text: fullSpeechText(for: item)
            )
        }
    }
}
