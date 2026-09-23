import SwiftUI
import UIKit
import WebKit

/// 时政页：上面切换「每日要点」和「新闻流」两种看法。
struct NewsView: View {
    @EnvironmentObject private var digest: DigestService

    @State private var mode: Mode = .digest

    enum Mode: String, CaseIterable, Identifiable {
        case digest = "每日要点"
        case stream = "新闻流"

        var id: String { rawValue }
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                Picker("视图", selection: $mode) {
                    ForEach(Mode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 4)

                if mode == .digest {
                    DigestView()
                } else {
                    NewsStreamView()
                }
            }
            .navigationTitle("时政")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if mode == .digest {
                        NavigationLink(destination: DigestSetupView()) {
                            Image(systemName: "slider.horizontal.3")
                        }
                    } else {
                        NavigationLink(destination: NewsSourceListView()) {
                            Image(systemName: "slider.horizontal.3")
                        }
                    }
                }
            }
            .onAppear {
                digest.loadFromDisk()
                if digest.digest?.date != digest.today {
                    digest.refresh()
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}

/// 补充视图：按时间排序的新闻流，用于想多读一点的时候。
struct NewsStreamView: View {
    @EnvironmentObject private var news: NewsService
    @EnvironmentObject private var settings: AppSettings

    @State private var selectedItem: NewsItem?

    var body: some View {
        List {
            if let error = news.errorText {
                Section {
                    Text(error)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }

            Section {
                Button("刷新新闻流") {
                    news.refresh(sources: settings.newsSources)
                }
                .disabled(news.isLoading)
                ForEach(news.items) { item in
                    Button {
                        selectedItem = item
                    } label: {
                        NewsRow(item: item)
                    }
                    .buttonStyle(.plain)
                }
                if news.items.isEmpty && !news.isLoading {
                    Text("还没有内容。下拉刷新，或者到「来源」里检查地址是否可用。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            } header: {
                Text(headerText)
            }
        }
        .listStyle(.insetGrouped)
        .sheet(item: $selectedItem) { item in
            NewsDetailView(item: item)
        }
        .onAppear {
            if news.items.isEmpty {
                news.refresh(sources: settings.newsSources)
            }
        }
    }

    private var headerText: String {
        guard let updated = news.lastUpdated else {
            return news.isLoading ? "正在抓取…" : "共 \(news.items.count) 条"
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        return "共 \(news.items.count) 条 · 更新于 " + formatter.string(from: updated)
    }
}

struct NewsRow: View {
    let item: NewsItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.title)
                .font(.body)
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)

            if !item.summary.isEmpty {
                Text(item.summary)
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 6) {
                Text(item.source)
                if let published = item.published {
                    Text("·")
                    Text(Self.dateText(published))
                }
            }
            .font(.caption)
            .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }

    private static func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter.string(from: date)
    }
}

struct NewsDetailView: View {
    @Environment(\.presentationMode) private var presentationMode
    let item: NewsItem

    var body: some View {
        NavigationView {
            Group {
                if let url = URL(string: item.link), !item.link.isEmpty {
                    WebView(url: url)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(item.title).font(.headline)
                            Text(item.summary).font(.body)
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle(item.source)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("关闭") { presentationMode.wrappedValue.dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        if let url = URL(string: item.link) {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        Image(systemName: "safari")
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}

struct NewsSourceListView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var news: NewsService

    @State private var newName = ""
    @State private var newURL = ""

    var body: some View {
        Form {
            Section(header: Text("已添加的来源")) {
                ForEach($settings.newsSources) { $source in
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle(source.name, isOn: $source.isEnabled)
                            .font(.body)
                        Text(source.url)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        if let count = news.countBySource[source.id] {
                            Text("上次抓到 \(count) 条")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .onDelete { offsets in
                    settings.newsSources.remove(atOffsets: offsets)
                }
            }

            Section(header: Text("添加来源")) {
                TextField("名称", text: $newName)
                TextField("RSS 地址", text: $newURL)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                Button("添加") {
                    let trimmed = newURL.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    let name = newName.isEmpty ? trimmed : newName
                    settings.newsSources.append(NewsSource(name: name, url: trimmed))
                    newName = ""
                    newURL = ""
                }
            }

            Section {
                Button("立即刷新") { news.refresh(sources: settings.newsSources) }
                Button("恢复默认来源") { settings.newsSources = AppSettings.defaultSources }
            }

            Section(header: Text("说明")) {
                Text("新闻流是「每日要点」的补充，靠 RSS 抓取。网站改版会导致某个源失效，换一个地址即可。")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle("新闻流来源")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 用系统 WebView 打开原文，避免跳转 Safari 打断阅读。
struct WebView: UIViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.allowsBackForwardNavigationGestures = true
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.loadedURL != url else { return }
        context.coordinator.loadedURL = url
        webView.load(URLRequest(url: url))
    }

    final class Coordinator {
        var loadedURL: URL?
    }
}
