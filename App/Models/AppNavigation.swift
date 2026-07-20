import Foundation

/// タブをまたぐ遷移の状態。グラフ(ダッシュボード)から
/// 設定タブの解説へジャンプするために、選択中のタブと
/// 設定タブの NavigationStack のパスをアプリ全体で共有する。
@Observable
final class AppNavigation {
    enum Tab: Hashable {
        case dashboard
        case settings
    }

    /// 設定タブの NavigationStack で辿れる行き先。
    /// 手動タップ(SettingsView / GlossaryView の NavigationLink)と
    /// プログラム遷移の両方がこの型を通る。
    enum SettingsRoute: Hashable {
        case glossary
        case glossaryTopic(key: String, focusEntry: String?)
    }

    var tab: Tab = .dashboard
    var settingsPath: [SettingsRoute] = []

    /// グラフ名に対応する解説項目を設定タブで開く。
    /// 対応表に無いグラフでは何もしない。
    func showGlossary(forChart name: String) {
        guard let location = Glossary.location(forChart: name) else { return }
        // 「指標の説明」を間に挟むことで、戻るボタンで
        // 解説インデックス → 設定 と自然にたどれる。
        settingsPath = [
            .glossary,
            .glossaryTopic(key: location.topicKey, focusEntry: location.term),
        ]
        tab = .settings
    }
}
