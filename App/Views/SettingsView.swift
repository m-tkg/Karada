import SwiftUI

struct SettingsView: View {
    var body: some View {
        Form {
            Section {
                Text("""
                ダッシュボードは HealthKit のデータを端末上で直接分析します。\
                データはこの端末の外に送信されません。
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("情報") {
                LabeledContent("バージョン",
                               value: Bundle.main.infoDictionary?["CFBundleShortVersionString"]
                               as? String ?? "-")
            }

        }
        .navigationTitle("設定")
    }
}
