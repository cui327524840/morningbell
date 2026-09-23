import SwiftUI

struct AlarmListView: View {
    @EnvironmentObject private var store: AlarmStore
    @EnvironmentObject private var engine: AlarmEngine

    @State private var editTarget: EditTarget?

    private enum EditTarget: Identifiable {
        case new
        case existing(Alarm)

        var id: String {
            switch self {
            case .new: return "new"
            case .existing(let alarm): return alarm.id.uuidString
            }
        }
    }

    var body: some View {
        NavigationView {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(nextFireText)
                            .font(.headline)
                        Text(engine.statusMessage)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                Section(header: Text("我的闹钟")) {
                    ForEach(store.alarms) { alarm in
                        AlarmRow(alarm: alarm) {
                            editTarget = .existing(alarm)
                        }
                    }
                    .onDelete { offsets in
                        store.remove(at: offsets)
                        engine.applySettings()
                    }

                    if store.alarms.isEmpty {
                        Text("点右上角 + 添加第一个闹钟")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("闹钟")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        editTarget = .new
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(item: $editTarget) { target in
                switch target {
                case .new:
                    AlarmEditView(alarm: Alarm(), isNew: true)
                case .existing(let alarm):
                    AlarmEditView(alarm: alarm, isNew: false)
                }
            }
        }
        .navigationViewStyle(.stack)
        .onAppear { engine.updateNextFireDate() }
    }

    private var nextFireText: String {
        guard let date = engine.nextFireDate else {
            return "当前没有启用的闹钟"
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 EEEE HH:mm"
        return "下一次响铃：" + formatter.string(from: date)
    }
}

struct AlarmRow: View {
    @EnvironmentObject private var store: AlarmStore
    @EnvironmentObject private var engine: AlarmEngine

    let alarm: Alarm
    let onEdit: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(alarm.timeText)
                    .font(.system(size: 34, weight: .light, design: .rounded))
                    .monospacedDigit()
                Text("\(alarm.label) · \(alarm.repeatText)")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture { onEdit() }

            Spacer(minLength: 0)

            Toggle("", isOn: Binding(get: { alarm.isEnabled }, set: { newValue in
                var updated = alarm
                updated.isEnabled = newValue
                store.update(updated)
                engine.applySettings()
            }))
            .labelsHidden()
        }
        .padding(.vertical, 2)
    }
}
