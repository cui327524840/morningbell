import SwiftUI

struct RootView: View {
    @ObservedObject private var router = AppRouter.shared
    var body: some View {
        TabView(selection: $router.selectedTab) {
            AlarmListView()
                .tabItem { Label("闹钟", systemImage: "alarm") }.tag(0)

            NewsView()
                .tabItem { Label("时政", systemImage: "newspaper") }.tag(1)

            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }.tag(2)
        }
    }
}
