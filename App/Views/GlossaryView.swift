import SwiftUI

/// 設定 → 「指標の説明」のインデックス。カテゴリごとの解説ページへ遷移する。
struct GlossaryView: View {
    var body: some View {
        List {
            Section {
                ForEach(Glossary.topics) { topic in
                    NavigationLink(
                        topic.title,
                        value: AppNavigation.SettingsRoute.glossaryTopic(
                            key: topic.key, focusEntry: nil))
                }
            } footer: {
                Text("ダッシュボードに表示している値の意味・単位・計算方法をまとめています。")
            }
        }
        .navigationTitle("指標の説明")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 1カテゴリ分の解説。概要 + 各指標のカードを縦に並べる。
///
/// `focusEntry` を指定すると、その項目までスクロールして一瞬ハイライトする
/// (ダッシュボードのグラフをタップして飛んできたとき)。
struct GlossaryTopicView: View {
    let topic: Glossary.Topic
    var focusEntry: String?

    @State private var highlighted: String?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let intro = topic.intro {
                        Text(intro)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    ForEach(topic.entries) { entry in
                        entryCard(entry).id(entry.id)
                    }
                }
                .padding()
            }
            .task {
                guard let focusEntry,
                      topic.entries.contains(where: { $0.id == focusEntry }) else { return }
                highlighted = focusEntry
                // レイアウトが確定してから移動する(直後に呼ぶと届かないことがある)
                try? await Task.sleep(for: .milliseconds(50))
                withAnimation { proxy.scrollTo(focusEntry, anchor: .top) }
                try? await Task.sleep(for: .seconds(1.5))
                withAnimation { highlighted = nil }
            }
        }
        .navigationTitle(topic.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func entryCard(_ entry: Glossary.Entry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(entry.term).font(.headline)
                if let unit = entry.unit {
                    Text(unit)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text(entry.detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.accentColor, lineWidth: 2)
                .opacity(highlighted == entry.id ? 1 : 0)
        }
    }
}
