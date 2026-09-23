import Combine
import Foundation

struct DigestItem: Identifiable, Codable, Equatable {
    var id: String
    var title: String
    var summary: String
    var category: String
    var tags: [String]?
    var source: String
    var link: String
    var published: Date?
    /// "notice" 表示这条不是新闻，而是使用说明。
    var kind: String?

    var isNotice: Bool {
        kind == "notice"
    }

    var categoryText: String {
        category.isEmpty ? "综合" : category
    }

    var tagText: String {
        (tags ?? []).joined(separator: " · ")
    }
}

struct DigestSourceStatus: Codable, Equatable {
    var name: String
    var ok: Bool
    var count: Int
    var note: String?
}

struct DailyDigest: Codable, Equatable {
    var date: String
    var generatedAt: Date?
    var method: String?
    var degraded: Bool?
    var count: Int?
    var items: [DigestItem]
    var sources: [DigestSourceStatus]?

    var methodText: String {
        switch method {
        case "llm": return "AI 精炼"
        case "extractive": return "抽取式摘要"
        case "seed": return "内置快照"
        default: return "未知来源"
        }
    }

    var newsItems: [DigestItem] {
        items.filter { !$0.isNotice }
    }
}

/// 每日时政要点：多镜像轮询 → 本地缓存 → 内置快照，三层兜底。
final class DigestService: ObservableObject {
    static let shared = DigestService()

    @Published var digest: DailyDigest?
    @Published var isLoading = false
    @Published var statusText = "尚未更新"
    @Published var isFromCache = false
    @Published var readIDs: Set<String> = []
    @Published var mirrorReport: [String] = []

    private weak var settings: AppSettings?
    private let defaults = UserDefaults.standard
    private var hasLoaded = false

    private init() {}

    func configure(settings: AppSettings) {
        self.settings = settings
    }

    private var documentsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private var cacheURL: URL {
        documentsURL.appendingPathComponent("digest-cache.json")
    }

    var today: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    // MARK: - 读取

    /// 先用缓存/内置快照顶上，避免打开 App 时一片空白。
    func loadFromDisk(force: Bool = false) {
        if hasLoaded && !force { return }
        hasLoaded = true

        if let data = try? Data(contentsOf: cacheURL), let cached = DigestStore.decode(data) {
            digest = cached
            isFromCache = true
            statusText = "本地缓存 · \(cached.date.isEmpty ? "未知日期" : cached.date)"
            loadReadState(for: cached.date)
            return
        }

        guard let seedURL = Bundle.main.url(forResource: "digest-seed", withExtension: "json"),
              let data = try? Data(contentsOf: seedURL),
              let seed = DigestStore.decode(data) else {
            statusText = "没有可用内容"
            return
        }
        digest = seed
        isFromCache = true
        statusText = "内置快照，等待联网更新"
        loadReadState(for: seed.date)
    }

    // MARK: - 更新

    func refresh(completion: (() -> Void)? = nil) {
        guard let settings = settings else {
            completion?()
            return
        }
        let prefixes = Self.mirrorPrefixes(settings: settings)
        guard !prefixes.isEmpty else {
            statusText = "还没填仓库名，先用离线内容"
            completion?()
            return
        }

        isLoading = true
        mirrorReport = []
        let today = self.today
        // 先试「今天的日期文件」，再试 latest；日期文件能避开 CDN 缓存。
        var urls: [String] = []
        for prefix in prefixes {
            urls.append("\(prefix)digest-\(today).json")
        }
        for prefix in prefixes {
            urls.append("\(prefix)digest-latest.json")
        }

        tryFetch(urls: urls, index: 0) { [weak self] result, errorText in
            guard let self = self else { return }
            self.isLoading = false
            if let result = result {
                self.digest = result
                self.isFromCache = false
                self.statusText = "已更新 · \(result.date) · \(result.newsItems.count) 条 · \(result.methodText)"
                self.saveCache(result)
                self.loadReadState(for: result.date)
            } else {
                self.loadFromDisk(force: true)
                self.statusText = "更新失败（\(errorText ?? "网络不可用")），正在用离线内容"
            }
            completion?()
        }
    }

    private func tryFetch(urls: [String], index: Int, completion: @escaping (DailyDigest?, String?) -> Void) {
        guard index < urls.count else {
            completion(nil, "所有镜像地址都不通")
            return
        }
        guard let url = URL(string: urls[index]) else {
            tryFetch(urls: urls, index: index + 1, completion: completion)
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("MorningBell/1.0", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            let statusCode = (response as? HTTPURLResponse)?.statusCode
            var failure: String?
            if let error = error {
                failure = error.localizedDescription
            } else if let statusCode = statusCode, statusCode != 200 {
                failure = "HTTP \(statusCode)"
            } else if let data = data, let parsed = DigestStore.decode(data), !parsed.items.isEmpty {
                DispatchQueue.main.async { completion(parsed, nil) }
                return
            } else {
                failure = "内容解析失败"
            }

            let host = url.host ?? url.absoluteString
            DispatchQueue.main.async {
                self?.mirrorReport.append("\(host)：\(failure ?? "失败")")
                self?.tryFetch(urls: urls, index: index + 1, completion: completion)
            }
        }.resume()
    }

    /// 设置页的「诊断接口」：逐个镜像报告状态。
    func diagnose(completion: @escaping ([String]) -> Void) {
        guard let settings = settings else {
            completion(["设置还没准备好"])
            return
        }
        let prefixes = Self.mirrorPrefixes(settings: settings)
        guard !prefixes.isEmpty else {
            completion(["还没填仓库名"])
            return
        }
        var lines: [String] = []
        let group = DispatchGroup()
        let lock = NSLock()

        for prefix in prefixes {
            guard let url = URL(string: "\(prefix)digest-latest.json") else { continue }
            var request = URLRequest(url: url)
            request.timeoutInterval = 12
            request.cachePolicy = .reloadIgnoringLocalCacheData
            group.enter()
            URLSession.shared.dataTask(with: request) { data, response, error in
                defer { group.leave() }
                var line: String
                if let error = error {
                    line = "❌ \(url.host ?? prefix)：\(error.localizedDescription)"
                } else if let data = data, let parsed = DigestStore.decode(data) {
                    line = "✅ \(url.host ?? prefix)：\(parsed.date) · \(parsed.newsItems.count) 条"
                } else {
                    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                    line = "❌ \(url.host ?? prefix)：HTTP \(code)"
                }
                lock.lock()
                lines.append(line)
                lock.unlock()
            }.resume()
        }
        group.notify(queue: .main) {
            self.mirrorReport = lines
            completion(lines)
        }
    }

    static func mirrorPrefixes(settings: AppSettings) -> [String] {
        var list: [String] = []
        var repo = settings.digestRepo.trimmingCharacters(in: .whitespacesAndNewlines)
        repo = repo.replacingOccurrences(of: "https://github.com/", with: "")
        repo = repo.replacingOccurrences(of: "https://raw.githubusercontent.com/", with: "")
        repo = repo.replacingOccurrences(of: "https://gitee.com/", with: "")
        repo = repo.replacingOccurrences(of: "@main", with: "")
        repo = repo.replacingOccurrences(of: ".git", with: "")
        repo = repo.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        if !repo.isEmpty {
            list.append("https://cdn.jsdelivr.net/gh/\(repo)@main/data/")
            list.append("https://raw.githubusercontent.com/\(repo)/main/data/")
            list.append("https://gitee.com/\(repo)/raw/main/data/")
        }
        let custom = settings.digestCustomURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty {
            var prefix = custom
            if !prefix.hasSuffix("/") { prefix += "/" }
            list.append(prefix)
        }
        return list
    }

    // MARK: - 已读进度

    func isRead(_ item: DigestItem) -> Bool {
        readIDs.contains(item.id)
    }

    func toggleRead(_ item: DigestItem) {
        if readIDs.contains(item.id) {
            readIDs.remove(item.id)
        } else {
            readIDs.insert(item.id)
        }
        persistReadState()
    }

    var readProgressText: String {
        let items = digest?.newsItems ?? []
        guard !items.isEmpty else { return "暂无可读内容" }
        let read = items.filter { readIDs.contains($0.id) }.count
        return "已读 \(read)/\(items.count)"
    }

    var readProgress: Double {
        let items = digest?.newsItems ?? []
        guard !items.isEmpty else { return 0 }
        return Double(items.filter { readIDs.contains($0.id) }.count) / Double(items.count)
    }

    private func readStateKey(for date: String) -> String {
        "morningbell.digest.read.\(date.isEmpty ? "seed" : date)"
    }

    private func loadReadState(for date: String) {
        let stored = defaults.array(forKey: readStateKey(for: date)) as? [String] ?? []
        readIDs = Set(stored)
    }

    private func persistReadState() {
        let date = digest?.date ?? ""
        defaults.set(Array(readIDs), forKey: readStateKey(for: date))
    }

    private func saveCache(_ digest: DailyDigest) {
        guard let data = try? JSONEncoder().encode(digest) else { return }
        try? data.write(to: cacheURL)
    }

    /// 起床播报用的要点串。
    func spokenHeadlines(limit: Int = 2) -> String? {
        let items = Array(digest?.newsItems.prefix(limit) ?? [])
        guard !items.isEmpty else { return nil }
        let parts = items.enumerated().map { index, item in
            "第\(index + 1)条，\(item.title)"
        }
        return "今日时政要点，" + parts.joined(separator: "；")
    }
}

enum DigestStore {
    static func decode(_ data: Data) -> DailyDigest? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            if let date = fractionalFormatter.date(from: text) ?? plainFormatter.date(from: text) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "无法解析日期：\(text)")
        }
        return try? decoder.decode(DailyDigest.self, from: data)
    }

    private static let plainFormatter = ISO8601DateFormatter()

    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
