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
    static let bundledSoundName = "alarm_default"

    @Published var importedFiles: [URL] = []

    private var documentsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private init() {
        refresh()
    }

    var bundledURL: URL? {
        Bundle.main.url(forResource: Self.bundledSoundName, withExtension: "wav")
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
        var list = [SoundOption(id: "default", title: "内置闹铃", url: bundledURL)]
        for file in importedFiles {
            list.append(SoundOption(id: file.lastPathComponent,
                                    title: file.deletingPathExtension().lastPathComponent,
                                    url: file))
        }
        return list
    }

    func url(for fileName: String?) -> URL? {
        guard let fileName = fileName, !fileName.isEmpty else { return bundledURL }
        let candidate = documentsURL.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        return bundledURL
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
