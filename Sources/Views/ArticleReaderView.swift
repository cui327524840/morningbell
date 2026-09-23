import SwiftUI
import UIKit

/// 原生阅读页：内容直接在 App 里看，不跳浏览器。
/// 正文优先用生成器抓好的；没有就自己抓一次并缓存（之后断网也能看）。
struct ArticleReaderView: View {
    @Environment(\.presentationMode) private var presentationMode
    @ObservedObject private var speech = SpeechService.shared

    let title: String
    let source: String
    let category: String
    let summary: String
    let link: String
    let published: Date?
    let initialBody: String?

    @State private var bodyText = ""
    @State private var isLoading = false
    @State private var failed = false

    init(item: DigestItem) {
        title = item.title
        source = item.source
        category = item.categoryText
        summary = item.summary
        link = item.link
        published = item.published
        initialBody = item.body
    }

    init(item: NewsItem) {
        title = item.title
        source = item.source
        category = ""
        summary = item.summary
        link = item.link
        published = item.published
        initialBody = nil
    }

    private var paragraphs: [String] {
        bodyText
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private var speechText: String {
        var text = title + "。"
        if !summary.isEmpty { text += summary + "。" }
        if !bodyText.isEmpty { text += bodyText.replacingOccurrences(of: "\n", with: "") }
        return text
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(title)
                        .font(.title3.bold())
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 8) {
                        if !category.isEmpty {
                            Text(category)
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color(.secondarySystemFill)))
                        }
                        Text(source)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        if let published = published {
                            Text(Self.dateText(published))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    if !summary.isEmpty {
                        Text(summary)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Divider()
                    }

                    if isLoading {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("正在抓取正文…")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                    }

                    ForEach(Array(paragraphs.enumerated()), id: \.offset) { pair in
                        Text(pair.element)
                            .font(.body)
                            .lineSpacing(7)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if paragraphs.isEmpty && failed && !isLoading {
                        Text("这条没抓到正文（个别站点结构特殊）。可以点右上角用浏览器打开原文。")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            .navigationTitle(source.isEmpty ? "阅读" : source)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("关闭") { speech.stop(); presentationMode.wrappedValue.dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 16) {
                        Button {
                            if speech.isSpeaking {
                                speech.stop()
                            } else {
                                speech.speak(speechText)
                            }
                        } label: {
                            Image(systemName: speech.isSpeaking ? "stop.circle" : "speaker.wave.2")
                        }
                        Button {
                            openInBrowser()
                        } label: {
                            Image(systemName: "safari")
                        }
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
        .onAppear { loadIfNeeded() }
    }

    private func loadIfNeeded() {
        guard bodyText.isEmpty else { return }
        if let initial = initialBody, initial.count >= 80 {
            bodyText = initial
            return
        }
        guard !link.isEmpty else {
            failed = true
            return
        }
        if let cached = ArticleExtractor.shared.cachedBody(for: link) {
            bodyText = cached
            return
        }
        isLoading = true
        ArticleExtractor.shared.load(url: link) { body in
            isLoading = false
            if let body = body, body.count >= 80 {
                bodyText = body
            } else {
                failed = true
            }
        }
    }

    private func openInBrowser() {
        guard let url = URL(string: link) else { return }
        UIApplication.shared.open(url)
    }

    private static func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return formatter.string(from: date)
    }
}
