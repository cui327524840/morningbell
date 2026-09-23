import Foundation

/// 把新闻网页转成段落文本，让 App 内直接阅读（不跳浏览器）。
/// 生成器已经抓好的正文会直接用；没有时才自己抓一次，并缓存到本地（断网也能回看）。
final class ArticleExtractor {
    static let shared = ArticleExtractor()

    private init() {}

    private var documentsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private var cacheDirectory: URL {
        documentsURL.appendingPathComponent("article-cache", isDirectory: true)
    }

    func cachedBody(for link: String) -> String? {
        guard !link.isEmpty else { return nil }
        let url = cacheDirectory.appendingPathComponent(Self.hash(link) + ".txt")
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { return nil }
        return text.isEmpty ? nil : text
    }

    func load(url link: String, completion: @escaping (String?) -> Void) {
        if let cached = cachedBody(for: link) {
            completion(cached)
            return
        }
        guard let target = URL(string: link) else {
            completion(nil)
            return
        }
        var request = URLRequest(url: target)
        request.timeoutInterval = 15
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 14_0 like Mac OS X) MorningBell/1.0",
                         forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            let html = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let body = html.isEmpty ? nil : ArticleExtractor.extract(html)
            DispatchQueue.main.async {
                if let body = body, body.count >= 80 {
                    self?.save(body, for: link)
                }
                completion(body)
            }
        }.resume()
    }

    private func save(_ text: String, for link: String) {
        do {
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            try text.data(using: .utf8)?.write(to: cacheDirectory.appendingPathComponent(Self.hash(link) + ".txt"))
        } catch {
            // 缓存失败不影响阅读
        }
    }

    // MARK: - 解析

    static func extract(_ html: String, maxChars: Int = 4000) -> String? {
        var paragraphs = collectParagraphs(from: html)

        // 央视这类站点把正文放在 JS 字符串里：var contentdate = '<p>…</p>'
        if paragraphs.count < 2 {
            if let range = html.range(of: "(?:contentdate|articleContent)\\s*=\\s*['\"]", options: [.regularExpression, .caseInsensitive]) {
                let tail = String(html[range.upperBound...])
                if let end = tail.firstIndex(of: "'") ?? tail.firstIndex(of: "\"") {
                    let raw = String(tail[tail.startIndex..<end])
                        .replacingOccurrences(of: "\\'", with: "'")
                        .replacingOccurrences(of: "\\\"", with: "\"")
                        .replacingOccurrences(of: "\\/", with: "/")
                    paragraphs = collectParagraphs(from: raw)
                }
            }
        }

        // 还是不行就退回整页文本按句切
        if paragraphs.count < 2 {
            let whole = clean(html)
            let sentences = whole.split(whereSeparator: { "。！？".contains($0) })
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) + "。" }
                .filter { $0.count >= 18 && !isBoilerplate($0) }
            paragraphs = Array(sentences.prefix(12))
        }

        var kept: [String] = []
        var total = 0
        for paragraph in paragraphs where total < maxChars {
            kept.append(paragraph)
            total += paragraph.count
        }
        guard !kept.isEmpty else { return nil }
        return kept.joined(separator: "\n")
    }

    private static func collectParagraphs(from html: String) -> [String] {
        let scoped = stripBlocks(html)
        guard let regex = try? NSRegularExpression(pattern: "<p[^>]*>([\\s\\S]*?)</p>", options: [.caseInsensitive]) else {
            return []
        }
        let ns = scoped as NSString
        var paragraphs: [String] = []
        for match in regex.matches(in: scoped, options: [], range: NSRange(location: 0, length: ns.length)) {
            guard match.numberOfRanges > 1 else { continue }
            let text = clean(ns.substring(with: match.range(at: 1)))
            if text.count < 18 { continue }
            if isBoilerplate(text) { continue }
            if paragraphs.last == text { continue }
            paragraphs.append(text)
        }
        return paragraphs
    }

    private static func stripBlocks(_ html: String) -> String {
        var text = html
        for pattern in ["<script[\\s\\S]*?</script>", "<style[\\s\\S]*?</style>", "<!--[\\s\\S]*?-->",
                        "<nav[\\s\\S]*?</nav>", "<header[\\s\\S]*?</header>", "<footer[\\s\\S]*?</footer>",
                        "<aside[\\s\\S]*?</aside>", "<form[\\s\\S]*?</form>"] {
            text = text.replacingOccurrences(of: pattern, with: " ", options: [.regularExpression, .caseInsensitive])
        }
        return text
    }

    private static func clean(_ html: String) -> String {
        var text = stripBlocks(html)
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let entities = ["&nbsp;": " ", "&amp;": "&", "&quot;": "\"", "&#39;": "'", "&apos;": "'",
                        "&lt;": "<", "&gt;": ">", "&ldquo;": "“", "&rdquo;": "”", "&middot;": "·", "&mdash;": "—"]
        for (key, value) in entities {
            text = text.replacingOccurrences(of: key, with: value)
        }
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isBoilerplate(_ text: String) -> Bool {
        let keywords = ["责任编辑", "来源：", "来源:", "声明", "版权", "免责", "扫码", "关注微信", "微信公众号",
                        "上一页", "下一页", "相关阅读", "热门推荐", "编辑：", "转载", "纠错", "返回顶部",
                        "分享到", "打印本页", "关闭窗口", "广告", "原标题", "更多精彩", "频道导航", "网站地图",
                        "关于我们", "联系方式", "京ICP", "举报"]
        return keywords.contains { text.contains($0) }
    }

    private static func hash(_ text: String) -> String {
        var value: UInt64 = 1469598103934665603
        for byte in text.utf8 {
            value ^= UInt64(byte)
            value = value &* 1099511628211
        }
        return String(value, radix: 16)
    }
}
