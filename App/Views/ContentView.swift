import SwiftUI

struct ContentView: View {
    @State private var nav = AppNavigation()

    var body: some View {
        content.environment(nav)
    }

    @ViewBuilder
    private var content: some View {
        #if DEBUG
        // シミュレータ検証用: チャート描画を単体で確認する
        if CommandLine.arguments.contains("--debug-charts") {
            ScrollView {
                VStack(spacing: 12) {
                    ChartCard(name: "steps", range: "1m")
                    ChartCard(name: "rhr", range: "1y")
                    ChartCard(name: "sleep_stages", range: "1m")
                    ChartCard(name: "energy_balance", range: "1m")
                    ChartCard(name: "workouts", range: "all")
                }
                .padding()
            }
        } else {
            tabs
        }
        #else
        tabs
        #endif
    }

    private var tabs: some View {
        TabView(selection: $nav.tab) {
            Tab("ダッシュボード", systemImage: "chart.xyaxis.line", value: AppNavigation.Tab.dashboard) {
                NavigationStack { DashboardView() }
            }
            Tab("設定", systemImage: "gearshape", value: AppNavigation.Tab.settings) {
                NavigationStack(path: $nav.settingsPath) {
                    SettingsView()
                        .navigationDestination(for: AppNavigation.SettingsRoute.self) { route in
                            settingsDestination(route)
                        }
                }
            }
        }
    }

    /// 設定タブの遷移先。手動タップもグラフからのジャンプもここを通る。
    @ViewBuilder
    private func settingsDestination(_ route: AppNavigation.SettingsRoute) -> some View {
        switch route {
        case .glossary:
            GlossaryView()
        case let .glossaryTopic(key, focusEntry):
            if let topic = Glossary.topics.first(where: { $0.key == key }) {
                GlossaryTopicView(topic: topic, focusEntry: focusEntry)
            }
        }
    }
}
