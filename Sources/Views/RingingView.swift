import SwiftUI

struct RingingView: View {
    @EnvironmentObject private var engine: AlarmEngine
    let alarm: Alarm

    var body: some View {
        ZStack {
            LinearGradient(gradient: Gradient(colors: [
                Color(red: 0.11, green: 0.15, blue: 0.32),
                Color(red: 0.33, green: 0.17, blue: 0.43)
            ]), startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()

            VStack(spacing: 16) {
                Spacer()

                TimelineView(.periodic(from: Date(), by: 1)) { context in
                    Text(Self.clockText(context.date))
                        .font(.system(size: 68, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundColor(.white)
                }

                Text(alarm.label.isEmpty ? "闹钟" : alarm.label)
                    .font(.title3)
                    .foregroundColor(.white.opacity(0.92))

                if let weather = engine.weather {
                    Text(weather.detailText)
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.85))
                }

                if !engine.spokenText.isEmpty {
                    Text(engine.spokenText)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .foregroundColor(.white.opacity(0.7))
                        .padding(.horizontal, 28)
                }

                Spacer()

                if alarm.snoozeMinutes > 0 {
                    Button {
                        engine.snooze()
                    } label: {
                        Label("贪睡 \(alarm.snoozeMinutes) 分钟", systemImage: "zzz")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
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
                        .padding(.vertical, 16)
                        .background(Color.white)
                        .foregroundColor(Color(red: 0.15, green: 0.16, blue: 0.35))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
    }

    private static func clockText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}
