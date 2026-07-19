import SwiftUI

/// 設定 → 「指標の説明」のインデックス。カテゴリごとの解説ページへ遷移する。
struct GlossaryView: View {
    var body: some View {
        List {
            Section {
                ForEach(Glossary.topics) { topic in
                    NavigationLink(topic.title) {
                        GlossaryTopicView(topic: topic)
                    }
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
struct GlossaryTopicView: View {
    let topic: Glossary.Topic

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let intro = topic.intro {
                    Text(intro)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                ForEach(topic.entries) { entry in
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
                }
            }
            .padding()
        }
        .navigationTitle(topic.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
