import Combine
import SwiftUI

/// 响铃界面：轻音乐打底，语音念「日期星期 → 天气 → 今日时政」，
/// 同时把内容直接显示在这里，不用跳网页。
struct RingingView: View {
    @EnvironmentObject private var engine: AlarmEngine
    @ObservedObject private var digestService = DigestService.shared

    let alarm: Alarm

    @State private var now = Date()
    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var items: [DigestItem] {
        Array(digestService.digest?.newsItems.prefix(6) ?? [])
    }

    var body: some View {
        ZStack {
            LinearGradient(gradient: Gradient(colors: [
                Color(red: 0.11, green: 0.15, blue: 0.32),
                Color(red: 0.33, green: 0.17, blue: 0.43)
            ]), startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()

            VStack(spacing: 10) {
                Text(Self.clockText(now))
                    .font(.system(size: 62, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundColor(.white)
                    .padding(.top, 24)

                Text(alarm.label.isEmpty ? "闹钟" : alarm.label)
                    .font(.title3)
                    .foregroundColor(.white.opacity(0.92))

                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(Self.dateLine(now))
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.9))

                        if let weather = engine.weather {
                            Text(weather.detailText)
                                .font(.subheadline)
                                .foregroundColor(.white.opacity(0.85))
                        } else {
                            Text("天气获取中…")
                                .font(.subheadline)
                                .foregroundColor(.white.opacity(0.6))
                        }

                        if items.isEmpty {
                            if !engine.spokenText.isEmpty {
                                Text(engine.spokenText)
                                    .font(.footnote)
                                    .foregroundColor(.white.opacity(0.75))
                            }
                        } else {
                            VStack(alignment: .leading, spacing: 9) {
                                Text("今日时政要点")
                                    .font(.footnote)
                                    .foregroundColor(.white.opacity(0.65))
                                ForEach(Array(items.enumerated()), id: \.element.id) { pair in
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("\(pair.offset + 1). \(pair.element.title)")
                                            .font(.subheadline)
                                            .foregroundColor(.white)
                                            .fixedSize(horizontal: false, vertical: true)
                                        if !pair.element.summary.isEmpty {
                                            Text(pair.element.summary)
                                                .font(.caption)
                                                .foregroundColor(.white.opacity(0.72))
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                    }
                                }
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.white.opacity(0.09))
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
                }

                if !engine.spokenText.isEmpty {
                    Button {
                        SpeechService.shared.speak(engine.spokenText)
                    } label: {
                        Text("再念一遍")
                            .font(.footnote)
                            .foregroundColor(.white.opacity(0.85))
                    }
                    .buttonStyle(.plain)
                }

                if alarm.snoozeMinutes > 0 {
                    Button {
                        engine.snooze()
                    } label: {
                        Label("贪睡 \(alarm.snoozeMinutes) 分钟", systemImage: "zzz")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .background(Color.white.opacity(0.18))
                            .foregroundColor(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }

                Button {
                    engine.stopRinging()
                } label: {
                    Text("停止")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(Color.white)
                        .foregroundColor(Color(red: 0.15, green: 0.16, blue: 0.35))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 28)
        }
        .onReceive(clock) { now = $0 }
    }

    private static func clockText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    private static func dateLine(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 EEEE"
        return "今天是 " + formatter.string(from: date)
    }
}
