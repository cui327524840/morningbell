import Combine

/// 极简路由：让通知点击、播报控件能把界面切到指定页签。
final class AppRouter: ObservableObject {
    static let shared = AppRouter()

    /// 0 = 闹钟，1 = 时政，2 = 设置
    @Published var selectedTab: Int = 0

    private init() {}

    /// 点通知进来的场景：直接落到「时政」页看全文。
    func openDigest() {
        selectedTab = 1
    }
}
