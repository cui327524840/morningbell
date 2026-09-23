import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

struct AlarmEditView: View {
    @EnvironmentObject private var store: AlarmStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var engine: AlarmEngine
    @ObservedObject private var soundLibrary = SoundLibrary.shared
    @Environment(\.presentationMode) private var presentationMode

    @State private var draft: Alarm
    @State private var soundID: String
    @State private var showImporter = false
    @State private var previewPlayer: AVAudioPlayer?

    private let isNew: Bool

    init(alarm: Alarm, isNew: Bool) {
        _draft = State(initialValue: alarm)
        _soundID = State(initialValue: alarm.soundFileName ?? SoundLibrary.defaultSoundName)
        self.isNew = isNew
    }

    var body: some View {
        NavigationView {
            Form {
                Section {
                    DatePicker("响铃时间", selection: timeBinding, displayedComponents: .hourAndMinute)
                        .datePickerStyle(.wheel)
                        .labelsHidden()
                        .frame(maxWidth: .infinity)
                }

                Section(header: Text("重复")) {
                    HStack(spacing: 8) {
                        ForEach(Weekday.ordered, id: \.self) { day in
                            weekdayButton(day)
                        }
                    }
                    .padding(.vertical, 4)
                    Text(draft.weekdays.isEmpty ? "当前设置：只响一次" : "当前设置：\(draft.repeatText)")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                Section(header: Text("标签")) {
                    TextField("例如：起床 · 晨读时政", text: $draft.label)
                }

                Section(header: Text("铃声")) {
                    Picker("铃声", selection: $soundID) {
                        ForEach(soundLibrary.options) { option in
                            Text(option.title).tag(option.id)
                        }
                    }
                    HStack {
                        Button(previewing ? "停止试听" : "试听铃声") { togglePreview() }
                        Spacer()
                        Button("导入音频") { showImporter = true }
                    }
                    ForEach(soundLibrary.importedFiles, id: \.lastPathComponent) { file in
                        HStack {
                            Text(file.deletingPathExtension().lastPathComponent)
                                .font(.subheadline)
                            Spacer()
                            Button("删除") {
                                soundLibrary.delete(fileName: file.lastPathComponent)
                                if soundID == file.lastPathComponent { soundID = SoundLibrary.defaultSoundName }
                            }
                            .font(.subheadline)
                            .foregroundColor(.red)
                        }
                    }
                }

                Section(header: Text("起床播报")) {
                    Toggle("播报当前时间", isOn: $draft.speakTime)
                    Toggle("播报今日天气", isOn: $draft.speakWeather)
                    Toggle("播报时政头条", isOn: $draft.speakNews)
                    if draft.speakNews {
                        Toggle("连要点详情一起念（更长）", isOn: $draft.speakNewsDetail)
                            .padding(.leading, 8)
                    }
                    HStack {
                        Text("城市")
                        Spacer()
                        TextField(settings.defaultCity, text: $draft.cityName)
                            .multilineTextAlignment(.trailing)
                    }
                    Text("留空则使用设置里的默认城市。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                Section(header: Text("贪睡")) {
                    Picker("贪睡时长", selection: $draft.snoozeMinutes) {
                        Text("不允许贪睡").tag(0)
                        Text("5 分钟").tag(5)
                        Text("10 分钟").tag(10)
                        Text("15 分钟").tag(15)
                    }
                }

                if !isNew {
                    Section {
                        Button("删除这个闹钟") { deleteAlarm() }
                            .foregroundColor(.red)
                    }
                }
            }
            .navigationTitle(isNew ? "新建闹钟" : "编辑闹钟")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("保存") { save() }
                }
            }
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: [.audio],
                          allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let url = urls.first {
                    soundLibrary.importFile(from: url)
                    soundID = url.lastPathComponent
                }
            }
        }
        .navigationViewStyle(.stack)
        .onDisappear {
            stopPreview()
            engine.resume()
        }
    }

    private var previewing: Bool {
        previewPlayer?.isPlaying ?? false
    }

    private var timeBinding: Binding<Date> {
        Binding(get: {
            let calendar = Calendar.current
            var components = calendar.dateComponents([.year, .month, .day], from: Date())
            components.hour = draft.hour
            components.minute = draft.minute
            return calendar.date(from: components) ?? Date()
        }, set: { newValue in
            let components = Calendar.current.dateComponents([.hour, .minute], from: newValue)
            draft.hour = components.hour ?? draft.hour
            draft.minute = components.minute ?? draft.minute
        })
    }

    private func weekdayButton(_ day: Int) -> some View {
        let selected = draft.weekdays.contains(day)
        return Button {
            if selected {
                draft.weekdays.remove(day)
            } else {
                draft.weekdays.insert(day)
            }
        } label: {
            Text(Weekday.short(day))
                .font(.system(size: 15, weight: .medium))
                .frame(width: 36, height: 36)
                .background(Circle().fill(selected ? Color.accentColor : Color(.secondarySystemFill)))
                .foregroundColor(selected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }

    private func save() {
        var alarm = draft
        alarm.soundFileName = soundID
        if isNew {
            store.add(alarm)
        } else {
            store.update(alarm)
        }
        engine.applySettings()
        dismiss()
    }

    private func deleteAlarm() {
        store.remove(id: draft.id)
        engine.applySettings()
        dismiss()
    }

    private func dismiss() {
        stopPreview()
        presentationMode.wrappedValue.dismiss()
    }

    private func togglePreview() {
        if previewing {
            stopPreview()
            return
        }
        guard let url = SoundLibrary.shared.url(for: soundID),
              let player = try? AVAudioPlayer(contentsOf: url) else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [])
        try? session.setActive(true)
        player.numberOfLoops = 0
        player.prepareToPlay()
        player.play()
        previewPlayer = player
    }

    private func stopPreview() {
        previewPlayer?.stop()
        previewPlayer = nil
    }
}
