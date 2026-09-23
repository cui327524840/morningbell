import AVFoundation
import Combine

struct SoundOption: Identifiable, Equatable {
    var id: String
    var title: String
    var url: URL?
}

/// 铃声来源：内置铃声 + 用户自己放进 App 文档目录的音频。
final class SoundLibrary: ObservableObject {
    static let shared = SoundLibrary()
    /// 新闹钟默认用轻音乐（起床时先放轻音乐，再由语音播报）。
    static let defaultSoundName = "alarm_soft"

    /// 内置铃声：文件名 → 显示名
    static let bundledSounds: [(name: String, title: String)] = [
        ("alarm_soft", "轻音乐（柔和）"),
        ("alarm_default", "经典闹铃")
    ]

    @Published var importedFiles: [URL] = []

    private var documentsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private init() {
        refresh()
    }

    func bundledURL(name: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: "wav")
    }

    func refresh() {
        let contents = (try? FileManager.default.contentsOfDirectory(at: documentsURL,
                                                                     includingPropertiesForKeys: nil)) ?? []
        let extensions = ["mp3", "m4a", "wav", "caf", "aiff", "aif"]
        importedFiles = contents
            .filter { extensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    var options: [SoundOption] {
        var list: [SoundOption] = []
        for entry in Self.bundledSounds {
            guard let url = bundledURL(name: entry.name) else { continue }
            let mark = entry.name == Self.defaultSoundName ? "（默认）" : ""
            list.append(SoundOption(id: entry.name, title: entry.title + mark, url: url))
        }
        for file in importedFiles {
            list.append(SoundOption(id: file.lastPathComponent,
                                    title: file.deletingPathExtension().lastPathComponent,
                                    url: file))
        }
        return list
    }

    func url(for fileName: String?) -> URL? {
        let fallback = bundledURL(name: Self.defaultSoundName) ?? bundledURL(name: "alarm_default")
        guard let fileName = fileName, !fileName.isEmpty else { return fallback }
        let candidate = documentsURL.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        return bundledURL(name: fileName) ?? fallback
    }

    /// 标题：内置音名映射成中文，导入的音用文件名。
    func title(for fileName: String?) -> String {
        guard let fileName = fileName, !fileName.isEmpty else {
            return Self.bundledSounds.first { $0.name == Self.defaultSoundName }?.title ?? "内置铃声"
        }
        if let bundled = Self.bundledSounds.first(where: { $0.name == fileName }) {
            return bundled.title
        }
        return (fileName as NSString).deletingPathExtension
    }

    func importFile(from url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let destination = documentsURL.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: destination)
        try? FileManager.default.copyItem(at: url, to: destination)
        refresh()
    }

    func delete(fileName: String) {
        let target = documentsURL.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: target)
        refresh()
    }
}
