import SwiftUI

/// 每日时政要点：编号列表 + 展开要点 + 标记已读 + 读原文。
struct DigestView: View {
    @EnvironmentObject private var digestService: DigestService
    @ObservedObject private var speech = SpeechService.shared

    @State private var expanded: Set<String> = []
    @State private var selectedItem: DigestItem?

    private var items: [DigestItem] {
        digestService.digest?.items ?? []
    }

    private var newsItems: [DigestItem] {
        digestService.digest?.newsItems ?? []
    }

    var body: some View {
        List {
            Section {
                statusCard
            }

            Section(header: Text(sectionHeader)) {
                ForEach(Array(items.enumerated()), id: \.element.id) { pair in
                    DigestRow(index: pair.offset + 1,
                              item: pair.element,
                              isRead: digestService.isRead(pair.element),
                              isExpanded: expanded.contains(pair.element.id),
                              isSpeaking: speech.isSpeaking && speech.currentID == pair.element.id,
                              onToggleExpand: { toggleExpand(pair.element.id) },
                              onToggleRead: { digestService.toggleRead(pair.element) },
                              onSpeak: { toggleSpeak(pair.element) },
                              onOpen: {
                                  if !pair.element.link.isEmpty {
                                      selectedItem = pair.element
                                  }
                              })
                }
                if items.isEmpty && !digestService.isLoading {
                    Text("还没有内容。下拉刷新，或者先去「要点接口」里填上仓库名。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
        }
        .listStyle(.insetGrouped)
        .sheet(item: $selectedItem) { item in
            ArticleReaderView(item: item)
        }
    }

    // MARK: - 子视图

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(dateTitle)
                    .font(.headline)
                Spacer()
                if digestService.isLoading {
                    ProgressView()
                }
            }

            Text(digestService.statusText)
                .font(.footnote)
                .foregroundColor(.secondary)

            if !newsItems.isEmpty {
                ProgressView(value: digestService.readProgress)
                HStack {
                    Text(digestService.readProgressText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(digestService.digest?.methodText ?? "")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if !digestService.mirrorReport.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(digestService.mirrorReport, id: \.self) { line in
                        Text(line)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }

            HStack(spacing: 12) {
                Button {
                    toggleSpeakAll()
                } label: {
                    Text(speech.isSpeaking ? "停止朗读" : "朗读全部")
                }
                .buttonStyle(CompactActionButtonStyle())

                Button {
                    digestService.refresh()
                } label: {
                    Text("立即更新")
                }
                .buttonStyle(CompactActionButtonStyle())

                NavigationLink(destination: DigestSetupView()) {
                    Text("要点接口").font(.footnote)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var dateTitle: String {
        guard let date = digestService.digest?.date, !date.isEmpty else {
            return "每日时政要点"
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd"
        guard let parsed = formatter.date(from: date) else { return "每日时政要点" }
        formatter.dateFormat = "M月d日"
        return formatter.string(from: parsed) + " 时政要点"
    }

    private var sectionHeader: String {
        if newsItems.isEmpty {
            return "还没有云端内容"
        }
        return "今日 \(newsItems.count) 条要点"
    }

    private func toggleExpand(_ id: String) {
        if expanded.contains(id) {
            expanded.remove(id)
        } else {
            expanded.insert(id)
        }
    }

    private func toggleSpeak(_ item: DigestItem) {
        if speech.isSpeaking && speech.currentID == item.id {
            speech.stop()
        } else {
            speech.speak(digestService.speechText(for: item), id: item.id)
        }
    }

    private func toggleSpeakAll() {
        if speech.isSpeaking {
            speech.stop()
        } else {
            speech.speakAll(digestService.speechQueue())
        }
    }

}

/// iOS 14 也能用的紧凑按钮样式（替代 iOS 15 才有的 .bordered 系列）。
struct CompactActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.footnote)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color(.secondarySystemFill)))
            .foregroundColor(.accentColor)
            .opacity(configuration.isPressed ? 0.6 : 1.0)
    }
}

struct DigestRow: View {
    let index: Int
    let item: DigestItem
    let isRead: Bool
    let isExpanded: Bool
    let isSpeaking: Bool
    let onToggleExpand: () -> Void
    let onToggleRead: () -> Void
    let onSpeak: () -> Void
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Text("\(index)")
                    .font(.caption.bold())
                    .foregroundColor(.white)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(isRead ? Color.secondary : Color.accentColor))

                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if !item.link.isEmpty { onOpen() }
                        }

                    HStack(spacing: 6) {
                        Text(item.categoryText)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color(.secondarySystemFill)))
                        Text(item.source)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        if let published = item.published {
                            Text(Self.shortDate(published))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }

            Text(item.summary)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .lineLimit(isExpanded ? nil : 2)
                .fixedSize(horizontal: false, vertical: true)

            if isExpanded && !item.tagText.isEmpty {
                Text("考点标签：" + item.tagText)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 16) {
                Button(isSpeaking ? "停止朗读" : "朗读") { onSpeak() }
                if !item.link.isEmpty {
                    Button("阅读全文") { onOpen() }
                }
                Spacer()
                Button(isExpanded ? "收起" : "展开要点") { onToggleExpand() }
                Button(isRead ? "取消已读" : "标记已读") { onToggleRead() }
            }
            .font(.footnote)
            .buttonStyle(.plain)
            .foregroundColor(.accentColor)
        }
        .padding(.vertical, 6)
        .opacity(isRead ? 0.55 : 1)
    }

    private static func shortDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return formatter.string(from: date)
    }
}

/// 要点接口设置：仓库名、自定义地址、诊断。
struct DigestSetupView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var digestService: DigestService

    @State private var repoDraft = ""
    @State private var customDraft = ""
    @State private var diagnoses: [String] = []

    var body: some View {
        Form {
            Section(header: Text("内容仓库")) {
                TextField("用户名/仓库名，例如 zhangsan/morningbell", text: $repoDraft)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                Button("保存并更新") {
                    applyRepo()
                    digestService.refresh()
                }
                Text("填你的 GitHub 账号名和仓库名，例如 zhangsan/morningbell；直接把整个仓库网址粘进来也可以。保存后 App 会依次尝试 jsDelivr、GitHub Raw、Gitee 三个镜像读取 data/digest-latest.json。")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }

            Section(header: Text("自定义接口（可选）")) {
                TextField("https://你的域名/data/", text: $customDraft)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                Button("保存自定义地址") {
                    settings.digestCustomURL = customDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                Text("如果三个默认镜像在国内都不通，把 JSON 放到任何能公网访问的地址（对象存储、自己的服务器都行），把前缀填在这里。")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }

            Section(header: Text("当前状态")) {
                infoRow("内容日期", digestService.digest?.date.isEmpty == false ? (digestService.digest?.date ?? "-") : "无")
                infoRow("要点条数", "\(digestService.digest?.newsItems.count ?? 0)")
                infoRow("生成方式", digestService.digest?.methodText ?? "-")
                infoRow("内容来源", digestService.isFromCache ? "离线内容" : "云端最新")

                if let sources = digestService.digest?.sources, !sources.isEmpty {
                    ForEach(sources, id: \.name) { source in
                        HStack(spacing: 8) {
                            Text(source.ok ? "✅" : "❌")
                            Text(source.name)
                                .font(.footnote)
                            Spacer()
                            Text(source.note ?? "\(source.count) 条")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                }
            }

            Section {
                Button("立即更新") { digestService.refresh() }
                Button("诊断接口") {
                    digestService.diagnose { lines in
                        diagnoses = lines
                    }
                }
                if !diagnoses.isEmpty {
                    ForEach(diagnoses, id: \.self) { line in
                        Text(line)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Section(header: Text("说明")) {
                Text("""
                要点内容由仓库里的 build-digest 工作流每天 05:30（北京时间）生成，抓取政策文件与权威媒体，按国考相关性打分、去重后输出 5~10 条。
                抓到多少个来源、每个来源多少条，都会记在生成的 JSON 里，「当前状态」里能看到。
                如果某天内容没更新，多半是某个来源改版了，去 Actions 看日志，再来找我改。
                """)
                .font(.footnote)
                .foregroundColor(.secondary)
            }
        }
        .navigationTitle("要点接口")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            repoDraft = settings.digestRepo
            customDraft = settings.digestCustomURL
        }
    }

    private func applyRepo() {
        settings.digestRepo = repoDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @ViewBuilder
    private func infoRow(_ name: String, _ value: String) -> some View {
        HStack {
            Text(name)
            Spacer()
            Text(value)
                .foregroundColor(.secondary)
        }
        .font(.subheadline)
    }
}
