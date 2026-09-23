import SwiftUI

struct RootView: View {
    var body: some View {
        TabView {
            AlarmListView()
                .tabItem { Label("闹钟", systemImage: "alarm") }

            NewsView()
                .tabItem { Label("时政", systemImage: "newspaper") }

            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
        }
    }
}
