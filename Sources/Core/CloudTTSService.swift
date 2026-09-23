import Foundation

/// 云端语音合成（微软 Azure 语音服务）。
/// 系统自带的中文朗读偏机械，云端神经音色（如 zh-CN-XiaoxiaoNeural）听起来接近真人。
/// 合成结果按「文本 + 音色」缓存到本地，同一段内容重复播放时不再走网络。
final class CloudTTSService {
    struct Config: Equatable {
        var key: String
        var region: String
        var voice: String
    }

    static let shared = CloudTTSService()

    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        return URLSession(configuration: configuration)
    }()

    private init() {}

    private var documentsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private var cacheDirectory: URL {
        documentsURL.appendingPathComponent("voice-cache", isDirectory: true)
    }

    func isConfigured(_ config: Config) -> Bool {
        !config.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !config.region.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func cachedAudio(for text: String, config: Config) -> Data? {
        let url = cacheURL(for: text, config: config)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try? Data(contentsOf: url)
    }

    func clearCache() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: cacheDirectory,
                                                                      includingPropertiesForKeys: nil) else { return }
        for file in files {
            try? FileManager.default.removeItem(at: file)
        }
    }

    func synthesize(text: String, config: Config, completion: @escaping (Result<Data, Error>) -> Void) {
        let region = config.region.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: "https://\(region).tts.speech.microsoft.com/cognitiveservices/v1") else {
            completion(.failure(CloudTTSError("区域名不合法：\(region)")))
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(config.key.trimmingCharacters(in: .whitespacesAndNewlines),
                         forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
        request.setValue("application/ssml+xml", forHTTPHeaderField: "Content-Type")
        request.setValue("audio-24khz-48kbitrate-mono-mp3", forHTTPHeaderField: "X-Microsoft-OutputFormat")
        request.setValue("MorningBell", forHTTPHeaderField: "User-Agent")
        request.httpBody = ssml(text: text, voice: config.voice).data(using: .utf8)

        session.dataTask(with: request) { [weak self] data, response, error in
            if let error = error {
                completion(.failure(CloudTTSError(error.localizedDescription)))
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200, let data = data, !data.isEmpty else {
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                let hint: String
                switch status {
                case 401: hint = "密钥无效"
                case 400: hint = "参数不对（检查区域和音色名）"
                case 429: hint = "超出免费额度或请求过快"
                default: hint = "HTTP \(status)"
                }
                completion(.failure(CloudTTSError("\(hint) \(body.prefix(120))")))
                return
            }
            self?.saveCache(data, for: text, config: config)
            completion(.success(data))
        }.resume()
    }

    private func saveCache(_ data: Data, for text: String, config: Config) {
        do {
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            try data.write(to: cacheURL(for: text, config: config))
        } catch {
            // 缓存失败不影响播放
        }
    }

    private func cacheURL(for text: String, config: Config) -> URL {
        cacheDirectory.appendingPathComponent("\(config.voice)-\(Self.hash(text)).mp3")
    }

    /// 稳定的短哈希，用来做缓存文件名（不引入额外依赖）。
    private static func hash(_ text: String) -> String {
        var value: UInt64 = 1469598103934665603
        for byte in text.utf8 {
            value ^= UInt64(byte)
            value = value &* 1099511628211
        }
        return String(value, radix: 16)
    }

    private func ssml(text: String, voice: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
        let trimmed = voice.trimmingCharacters(in: .whitespacesAndNewlines)
        let voiceName = trimmed.isEmpty ? "zh-CN-XiaoxiaoNeural" : trimmed
        return "<speak version='1.0' xml:lang='zh-CN'><voice xml:lang='zh-CN' name='\(voiceName)'><prosody rate='-4%'>\(escaped)</prosody></voice></speak>"
    }
}

struct CloudTTSError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}
