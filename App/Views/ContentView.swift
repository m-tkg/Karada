import SwiftUI

struct ContentView: View {
    var body: some View {
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
        TabView {
            NavigationStack { DashboardView() }
                .tabItem { Label("ダッシュボード", systemImage: "chart.xyaxis.line") }
            NavigationStack { SettingsView() }
                .tabItem { Label("設定", systemImage: "gearshape") }
        }
    }
}
