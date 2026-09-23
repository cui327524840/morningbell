import Combine
import Foundation

final class NewsService: ObservableObject {
    static let shared = NewsService()

    @Published var items: [NewsItem] = []
    @Published var isLoading = false
    @Published var lastUpdated: Date?
    @Published var errorText: String?
    @Published var countBySource: [UUID: Int] = [:]

    private var cacheURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("news-cache.json")
    }

    private init() {
        loadCache()
    }

    func refresh(sources: [NewsSource]) {
        let active = sources.filter { $0.isEnabled && !$0.url.isEmpty }
        guard !active.isEmpty else {
            errorText = "没有启用的时政来源"
            return
        }
        isLoading = true
        errorText = nil

        let group = DispatchGroup()
        let lock = NSLock()
        var collected: [NewsItem] = []
        var counts: [UUID: Int] = [:]
        var failures: [String] = []

        for source in active {
            guard let url = URL(string: source.url) else {
                failures.append(source.name)
                continue
            }
            group.enter()
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 15_0 like Mac OS X) MorningBell/1.0",
                             forHTTPHeaderField: "User-Agent")
            URLSession.shared.dataTask(with: request) { data, _, error in
                defer { group.leave() }
                guard let data = data, error == nil else {
                    lock.lock(); failures.append(source.name); lock.unlock()
                    return
                }
                let parsed = RSSParser(sourceName: source.name).parse(data: data)
                lock.lock()
                collected.append(contentsOf: parsed)
                counts[source.id] = parsed.count
                if parsed.isEmpty { failures.append(source.name) }
                lock.unlock()
            }.resume()
        }

        group.notify(queue: .main) { [weak self] in
            guard let self = self else { return }
            self.isLoading = false
            self.countBySource = counts
            if collected.isEmpty {
                self.errorText = failures.isEmpty ? "没有抓到内容" : "以下来源抓取失败：\(failures.joined(separator: "、"))"
                return
            }
            var seen = Set<String>()
            let deduped = collected.filter { seen.insert($0.id).inserted }
            self.items = deduped.sorted { lhs, rhs in
                (lhs.published ?? Date.distantPast) > (rhs.published ?? Date.distantPast)
            }
            self.lastUpdated = Date()
            if !failures.isEmpty {
                self.errorText = "部分来源失败：\(failures.joined(separator: "、"))"
            }
            self.saveCache()
        }
    }

    func topHeadlines(limit: Int = 2) -> String? {
        let titles = items.prefix(limit).map { $0.title }
        guard !titles.isEmpty else { return nil }
        return "今日时政头条：" + titles.joined(separator: "；")
    }

    private func saveCache() {
        let cache = Cache(savedAt: Date(), items: items)
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: cacheURL)
    }

    private func loadCache() {
        guard let data = try? Data(contentsOf: cacheURL),
              let cache = try? JSONDecoder().decode(Cache.self, from: data) else { return }
        items = cache.items
        lastUpdated = cache.savedAt
    }

    private struct Cache: Codable {
        var savedAt: Date
        var items: [NewsItem]
    }
}

/// 极简 RSS / Atom 解析：只取标题、链接、时间、摘要。
final class RSSParser: NSObject, XMLParserDelegate {
    private let sourceName: String
    private var items: [NewsItem] = []
    private var isInsideItem = false
    private var buffer = ""
    private var title = ""
    private var link = ""
    private var date = ""
    private var summary = ""

    init(sourceName: String) {
        self.sourceName = sourceName
        super.init()
    }

    func parse(data: Data) -> [NewsItem] {
        items = []
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = false
        parser.parse()
        return items
    }

    func parser(_ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        let name = elementName.lowercased()
        if name == "item" || name == "entry" {
            isInsideItem = true
            title = ""
            link = ""
            date = ""
            summary = ""
        } else if isInsideItem, name == "link", link.isEmpty, let href = attributeDict["href"] {
            link = href
        }
        buffer = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        buffer += string
    }

    func parser(_ parser: XMLParser,
                didEndElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?) {
        let name = elementName.lowercased()
        if name == "item" || name == "entry" {
            isInsideItem = false
            let cleanedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleanedTitle.isEmpty {
                items.append(NewsItem(title: cleanedTitle,
                                      link: link.trimmingCharacters(in: .whitespacesAndNewlines),
                                      source: sourceName,
                                      published: RSSParser.parseDate(date),
                                      summary: RSSParser.clean(summary)))
            }
            buffer = ""
            return
        }
        guard isInsideItem else {
            buffer = ""
            return
        }
        let value = buffer
        switch name {
        case "title":
            if title.isEmpty { title = value }
        case "link", "guid", "id":
            if link.isEmpty { link = value.trimmingCharacters(in: .whitespacesAndNewlines) }
        case "pubdate", "published", "updated", "date", "dc:date":
            if date.isEmpty { date = value }
        case "description", "summary", "content", "encoded", "content:encoded":
            if summary.isEmpty { summary = value }
        default:
            break
        }
        buffer = ""
    }

    static func clean(_ html: String) -> String {
        var text = html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let entities = ["&nbsp;": " ", "&amp;": "&", "&quot;": "\"", "&#39;": "'", "&lt;": "<", "&gt;": ">"]
        for (key, value) in entities {
            text = text.replacingOccurrences(of: key, with: value)
        }
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))
    }

    static func parseDate(_ raw: String) -> Date? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        for formatter in dateFormatters {
            if let parsed = formatter.date(from: text) { return parsed }
        }
        return nil
    }

    private static let dateFormatters: [DateFormatter] = {
        let patterns = [
            "EEE, dd MMM yyyy HH:mm:ss Z",
            "EEE, dd MMM yyyy HH:mm:ss zzz",
            "EEE, dd MMM yyyy HH:mm Z",
            "yyyy-MM-dd'T'HH:mm:ssZ",
            "yyyy-MM-dd'T'HH:mm:ss.SSSZ",
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd"
        ]
        return patterns.map { pattern in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = pattern
            return formatter
        }
    }()
}
