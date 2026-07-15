import SwiftUI

struct SettingsView: View {
    @AppStorage("visibleDashboardCategories")
    private var visibleDashboardCategories = DashboardCategory.defaultStorageValue

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

            Section("ダッシュボードに表示するカテゴリ") {
                ForEach(DashboardCategory.all) { category in
                    Toggle(category.title, isOn: categoryBinding(for: category.key))
                }

                Button("すべて表示") {
                    visibleDashboardCategories = DashboardCategory.defaultStorageValue
                }
            }

            Section("情報") {
                LabeledContent("バージョン",
                               value: Bundle.main.infoDictionary?["CFBundleShortVersionString"]
                               as? String ?? "-")
            }

        }
        .navigationTitle("設定")
    }

    private func categoryBinding(for key: String) -> Binding<Bool> {
        Binding {
            visibleKeys.contains(key)
        } set: { isVisible in
            var next = visibleKeys
            if isVisible {
                next.insert(key)
            } else {
                next.remove(key)
            }
            visibleDashboardCategories = DashboardCategory.all
                .map(\.key)
                .filter { next.contains($0) }
                .joined(separator: ",")
        }
    }

    private var visibleKeys: Set<String> {
        Set(visibleDashboardCategories.split(separator: ",").map(String.init))
    }
}
