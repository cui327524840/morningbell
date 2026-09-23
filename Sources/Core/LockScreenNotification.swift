import Foundation
import UserNotifications

extension AlarmEngine {
    /// 响铃时先把「今日时政要点」推到锁屏「正在播放」卡片上，
    /// 这样在音乐/播报开始前，锁屏就已经能看到时政内容。
    func publishLockScreenDigestCard(timeText: String) {
        guard let digestText = DigestService.shared.lockScreenText(limit: 6) else { return }
        LockScreenPresenter.shared.begin(
            title: "晨钟 · 今日时政要点",
            subtitle: timeText,
            body: digestText
        )
    }

    /// 响铃通知里带上今天的时政要点（锁屏一眼可见，点开进 App 看全文）。
    func applyLockScreenDigest(to content: UNMutableNotificationContent, wantsDigest: Bool) {
        guard wantsDigest, let digestText = DigestService.shared.lockScreenText(limit: 8) else { return }
        let originalTitle = content.title
        content.subtitle = originalTitle
        content.title = "晨钟 · 今日时政要点"
        content.body = digestText
        content.threadIdentifier = "morningbell.digest"
    }
}
