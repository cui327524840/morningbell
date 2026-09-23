import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var engine: AlarmEngine
    @EnvironmentObject private var weather: WeatherService
    @EnvironmentObject private var news: NewsService
    @EnvironmentObject private var digestService: DigestService

    @State private var cityDraft = ""
    @State private var criticalMessage = ""

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("响铃方式")) {
                    Toggle("后台保活（推荐）", isOn: $settings.keepAlive)
                        .onChange(of: settings.keepAlive) { _ in
                            engine.applySettings()
                        }
                    Text("打开后 App 会常驻后台，到点准时响铃，静音拨片也挡不住，能同时放音乐和语音。代价是耗电，具体比例建议在你机器上实测算账。")
                        .font(.footnote)
                        .foregroundColor(.secondary)

                    Toggle("通知兜底", isOn: $settings.notificationFallback)
                        .onChange(of: settings.notificationFallback) { _ in
                            engine.applySettings()
                        }
                    Text("App 被上滑强退、或手机重启后没打开过 App 时，只能靠通知提醒：最长 30 秒，静音开关会挡住声音。")
                        .font(.footnote)
                        .foregroundColor(.secondary)

                    HStack {
                        Text("当前状态")
                        Spacer()
                        Text(engine.statusMessage)
                            .foregroundColor(.secondary)
                    }
                    .font(.subheadline)

                    HStack {
                        Text("响铃后自动停止")
                        Spacer()
                        Picker("", selection: $settings.autoStopMinutes) {
                            Text("5 分钟").tag(5)
                            Text("10 分钟").tag(10)
                            Text("20 分钟").tag(20)
                            Text("30 分钟").tag(30)
                        }
                        .labelsHidden()
                    }
                }

                Section(header: Text("重要警告（实验性）")) {
                    Toggle("尝试启用重要警告", isOn: $settings.criticalAlerts)
                        .onChange(of: settings.criticalAlerts) { enabled in
                            if enabled {
                                engine.requestCriticalAuthorization { available in
                                    criticalMessage = available ? "已获得重要警告权限，静音和勿扰都挡不住。" : "没有拿到权限，仍按普通通知响铃，不影响使用。"
                                }
                            }
                            engine.applySettings()
                        }
                    Text(criticalMessage.isEmpty
                         ? "重要警告能穿透静音和勿扰，普通安装拿不到这个权限。既然你有巨魔，值得试一次：能开最好，开不了也不影响其他功能。"
                         : criticalMessage)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                Section(header: Text("语音播报")) {
                    Toggle("启用语音", isOn: $settings.voiceEnabled)
                    HStack {
                        Text("语速")
                        Slider(value: $settings.speechRate, in: 0.3...0.6)
                    }
                    Button("试听一段播报") { engine.previewSpeech() }
                }

                Section(header: Text("天气")) {
                    HStack {
                        Text("默认城市")
                        Spacer()
                        TextField("北京", text: $cityDraft)
                            .multilineTextAlignment(.trailing)
                            .onSubmit { applyCity() }
                    }
                    Button("更新天气") { applyCity() }
                    if let snapshot = weather.snapshot {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(snapshot.cityName) · \(snapshot.detailText)")
                            Text("更新于 " + Self.timeText(snapshot.updatedAt))
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                    }
                    if let error = weather.errorText {
                        Text(error).font(.footnote).foregroundColor(.red)
                    }
                }

                Section(header: Text("每日时政要点")) {
                    NavigationLink(destination: DigestSetupView()) {
                        HStack {
                            Text("要点接口")
                            Spacer()
                            Text(repoStatusText)
                                .foregroundColor(.secondary)
                        }
                    }
                    HStack {
                        Text("内容日期")
                        Spacer()
                        Text(digestDateText).foregroundColor(.secondary)
                    }
                    HStack {
                        Text("今日要点")
                        Spacer()
                        Text("\(digestService.digest?.newsItems.count ?? 0) 条").foregroundColor(.secondary)
                    }
                    HStack {
                        Text("阅读进度")
                        Spacer()
                        Text(digestService.readProgressText).foregroundColor(.secondary)
                    }
                    Button("立即更新要点") { digestService.refresh() }
                }

                Section(header: Text("新闻流（补充阅读）")) {
                    NavigationLink(destination: NewsSourceListView()) {
                        HStack {
                            Text("新闻流来源")
                            Spacer()
                            Text("\(settings.newsSources.filter { $0.isEnabled }.count) 个启用")
                                .foregroundColor(.secondary)
                        }
                    }
                    HStack {
                        Text("已缓存")
                        Spacer()
                        Text("\(news.items.count) 条").foregroundColor(.secondary)
                    }
                    Button("立即刷新新闻流") { news.refresh(sources: settings.newsSources) }
                }

                Section(header: Text("诊断")) {
                    infoRow("机型", DeviceInfo.friendlyName)
                    infoRow("硬件标识", DeviceInfo.hardwareIdentifier)
                    infoRow("系统版本", DeviceInfo.systemVersion)
                    infoRow("通知权限", engine.authorizationText)
                    infoRow("重要警告", engine.criticalAlertsAvailable ? "可用" : "不可用")
                    infoRow("后台保活", BackgroundKeeper.shared.isRunning ? "运行中" : (BackgroundKeeper.shared.isEnabled ? "未运行" : "已关闭"))
                    if let error = BackgroundKeeper.shared.lastError {
                        Text(error).font(.footnote).foregroundColor(.red)
                    }
                }

                Section(header: Text("使用须知")) {
                    Text("""
                    1. 只有巨魔安装的版本才有完整能力：App Store 上架版本做不到真闹钟。
                    2. 上滑强退 App，或手机重启后没打开过 App，这两种情况只能靠通知兜底；重新打开一次 App 就会恢复准点响铃。
                    3. 自定义铃声：把 MP3 放进 App 的文档目录（用「文件」App 或电脑上的文件共享），或者在编辑闹钟页点「导入音频」。
                    4. 起床播报的顺序是：时间 → 时政头条 → 今日天气，可在每个闹钟里单独开关。
                    """)
                    .font(.footnote)
                    .foregroundColor(.secondary)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("设置")
            .onAppear {
                cityDraft = settings.defaultCity
                engine.refreshAuthorizationStatus()
            }
        }
        .navigationViewStyle(.stack)
    }

    private func applyCity() {
        let city = cityDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !city.isEmpty else { return }
        settings.defaultCity = city
        weather.refresh(city: city) { _ in }
    }

    private var repoStatusText: String {
        let repo = settings.digestRepo.trimmingCharacters(in: .whitespacesAndNewlines)
        return repo.isEmpty ? "未填写" : repo
    }

    private var digestDateText: String {
        guard let date = digestService.digest?.date, !date.isEmpty else { return "无" }
        return date
    }

    @ViewBuilder
    private func infoRow(_ name: String, _ value: String) -> some View {
        HStack {
            Text(name)
            Spacer()
            Text(value)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }

    private static func timeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}
