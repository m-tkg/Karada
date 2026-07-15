import HealthKit
import SwiftUI

struct DashboardView: View {
    @AppStorage("dashboardRange") private var range = "1m"
    @State private var data: DashboardData?
    @State private var errorText: String?

    private let ranges: [(String, String)] = [
        ("1m", "1ヶ月"), ("1y", "1年"), ("3y", "3年"), ("all", "全期間"),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Picker("期間", selection: $range) {
                    ForEach(ranges, id: \.0) { key, label in
                        Text(label).tag(key)
                    }
                }
                .pickerStyle(.segmented)

                if let errorText {
                    ContentUnavailableView(
                        "HealthKit を利用できません", systemImage: "heart.text.square",
                        description: Text(errorText)
                    )
                } else if let data, data.latest == nil {
                    ContentUnavailableView(
                        "まだデータがありません",
                        systemImage: "heart.text.square",
                        description: Text("ヘルスケアにデータが記録されると、ここに分析結果が表示されます。")
                    )
                } else if let data {
                    dashboardBody(data)
                } else {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 200)
                }
            }
            .padding()
        }
        .navigationTitle("カラダの記録")
        .task(id: range) { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        errorText = nil
        guard HKHealthStore.isHealthDataAvailable() else {
            errorText = "この端末では HealthKit を利用できません"
            return
        }
        // ダッシュボードは HealthKit から端末上で直接計算する(サーバー不要)。
        // 未認可の型があれば認可シートが出る(初回のみ)。
        try? await HealthKitReader().requestAuthorization()
        data = await LocalAnalytics.buildDashboard(range: range)
    }

    @ViewBuilder
    private func dashboardBody(_ data: DashboardData) -> some View {
        if let latest = data.latest {
            Text("最終データ日: \(latest)")
                .font(.caption).foregroundStyle(.secondary)
        }

        if !data.insights.isEmpty {
            sectionHeader("今日の発見")
            ForEach(data.insights) { insight in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: insight.good == true ? "arrowtriangle.up.fill"
                          : insight.good == false ? "arrowtriangle.down.fill" : "circle.fill")
                        .font(.caption)
                        .foregroundStyle(insight.good == true ? .green
                                         : insight.good == false ? .red : .secondary)
                        .padding(.top, 3)
                    Text(insight.text).font(.subheadline)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color(.secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 10))
            }
        }

        if !data.assess.good.isEmpty || !data.assess.improve.isEmpty {
            sectionHeader("今月の評価")
            if !data.assess.good.isEmpty {
                assessGroup("👏 よくできている", items: data.assess.good, tint: .green)
            }
            if !data.assess.improve.isEmpty {
                assessGroup("💡 改善のヒント", items: data.assess.improve, tint: .orange)
            }
        }

        if !data.numbers.isEmpty {
            sectionHeader("いまの数字(直近30日平均)")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 10)],
                      spacing: 10) {
                ForEach(data.numbers) { n in
                    NumberCard(item: n)
                }
            }
        }

        ForEach(data.sections) { section in
            sectionHeader(section.title)

            if section.key == "cycle", let avg = section.avgCycle {
                Text("平均周期: \(avg, specifier: "%.1f") 日").font(.subheadline)
            }

            ForEach(section.charts, id: \.self) { chart in
                ChartCard(name: chart, range: range)
            }

            if let recent = section.recent, !recent.isEmpty {
                RecentWorkoutsTable(workouts: recent)
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title).font(.headline).padding(.top, 6)
    }

    private func assessGroup(_ title: String, items: [DashboardData.Assessments.Item],
                             tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline).bold().foregroundStyle(tint)
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).font(.subheadline).bold()
                    Text(item.detail).font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color(.secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }
}

struct NumberCard: View {
    let item: DashboardData.NumberItem

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(formatted(item.value))
                .font(.title3).bold().foregroundStyle(.teal)
            Text("\(item.label) ").font(.caption)
                + Text(item.unit).font(.caption2).foregroundStyle(.secondary)
            if let delta = item.delta {
                Text("\(delta > 0 ? "▲" : delta < 0 ? "▼" : "→") \(formatted(delta, signed: true)) 前月比")
                    .font(.caption2)
                    .foregroundStyle(item.deltaGood == true ? .green
                                     : item.deltaGood == false ? .red : .secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 10))
    }

    private func formatted(_ v: Double, signed: Bool = false) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = v == v.rounded() ? 0 : 1
        f.positivePrefix = signed ? "+" : ""
        return f.string(from: NSNumber(value: v)) ?? "\(v)"
    }
}

struct RecentWorkoutsTable: View {
    let workouts: [DashboardData.RecentWorkout]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("最近のワークアウト").font(.subheadline).bold()
                .padding(.bottom, 6)
            ForEach(workouts) { w in
                HStack {
                    Text(w.localDate ?? "").font(.caption).monospacedDigit()
                    Text(w.activityLabel ?? w.activityType).font(.caption)
                    Spacer()
                    if let d = w.duration {
                        Text("\(Int(d))分").font(.caption).foregroundStyle(.secondary)
                    }
                    if let kcal = w.totalEnergyBurned {
                        Text("\(Int(kcal))kcal").font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
                Divider()
            }
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 12))
    }
}
