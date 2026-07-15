import HealthKit
import SwiftUI

struct DashboardView: View {
    @AppStorage("dashboardRange") private var range = "1m"
    @AppStorage("lastDashboardSyncAt") private var lastDashboardSyncAt = 0.0
    @AppStorage("visibleDashboardCategories")
    private var visibleDashboardCategories = DashboardCategory.defaultStorageValue
    @State private var expandedSectionKeys: Set<String> = [
        "cardio", "activity", "sleep", "body", "walking", "diet", "cycle", "workouts",
    ]
    @State private var data: DashboardData?
    @State private var errorText: String?

    private let ranges: [(String, String)] = [
        ("1m", "1ヶ月"), ("1y", "1年"), ("3y", "3年"), ("all", "全期間"),
    ]

    private var visibleCategoryKeys: Set<String> {
        Set(visibleDashboardCategories.split(separator: ",").map(String.init))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Picker("期間", selection: $range) {
                    ForEach(ranges, id: \.0) { key, label in
                        Text(label).tag(key)
                    }
                }
                .pickerStyle(.segmented)

                syncStatus

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
        lastDashboardSyncAt = Date().timeIntervalSince1970
    }

    @ViewBuilder
    private var syncStatus: some View {
        if lastDashboardSyncAt > 0 {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.2.circlepath")
                Text("最終同期日時: \(formatSyncDate(Date(timeIntervalSince1970: lastDashboardSyncAt)))")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func formatSyncDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
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
                assessGroup("👏 よくできている", items: data.assess.good, tint: .green,
                            showsDetail: false)
            }
            if !data.assess.improve.isEmpty {
                assessGroup("💡 改善のヒント", items: data.assess.improve, tint: .orange,
                            showsDetail: true)
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

        let visibleSections = data.sections.filter { visibleCategoryKeys.contains($0.key) }
        if visibleSections.isEmpty {
            ContentUnavailableView(
                "表示するカテゴリがありません",
                systemImage: "chart.line.uptrend.xyaxis",
                description: Text("設定でダッシュボードに表示するカテゴリを選んでください。")
            )
        } else {
            ForEach(visibleSections) { section in
                chartSection(section)
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title).font(.headline).padding(.top, 6)
    }

    private func chartSection(_ section: DashboardData.Section) -> some View {
        DisclosureGroup(
            isExpanded: Binding(
                get: { expandedSectionKeys.contains(section.key) },
                set: { isExpanded in
                    if isExpanded {
                        expandedSectionKeys.insert(section.key)
                    } else {
                        expandedSectionKeys.remove(section.key)
                    }
                }
            )
        ) {
            VStack(alignment: .leading, spacing: 12) {
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
            .padding(.top, 8)
        } label: {
            HStack {
                Text(section.title).font(.headline)
                Spacer()
                Text("\(section.charts.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.vertical, 4)
        }
    }

    private func assessGroup(_ title: String, items: [DashboardData.Assessments.Item],
                             tint: Color, showsDetail: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline).bold().foregroundStyle(tint)
            ForEach(items) { item in
                if showsDetail, let evidence = item.evidence {
                    NavigationLink {
                        AssessmentDetailView(item: item, evidence: evidence, range: range)
                    } label: {
                        assessmentRow(item, showsChevron: true)
                    }
                    .buttonStyle(.plain)
                } else {
                    assessmentRow(item, showsChevron: false)
                }
            }
        }
    }

    private func assessmentRow(_ item: DashboardData.Assessments.Item,
                               showsChevron: Bool) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.subheadline).bold()
                Text(item.detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 10))
    }
}

struct AssessmentDetailView: View {
    let item: DashboardData.Assessments.Item
    let evidence: DashboardData.Assessments.Evidence
    let range: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.title).font(.title3).bold()
                    Text(evidence.summary).font(.subheadline).foregroundStyle(.secondary)
                }

                if !evidence.metrics.isEmpty {
                    sectionTitle("判断に使った数字")
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 10)],
                              spacing: 10) {
                        ForEach(evidence.metrics) { metric in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(metric.value)
                                    .font(.headline)
                                    .foregroundStyle(.orange)
                                Text(metric.label)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(Color(.secondarySystemGroupedBackground),
                                        in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }

                if !evidence.reasons.isEmpty {
                    sectionTitle("判断理由")
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(evidence.reasons, id: \.self) { reason in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "checkmark.circle")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                                    .padding(.top, 2)
                                Text(reason).font(.subheadline)
                            }
                        }
                    }
                }

                if !evidence.chartNames.isEmpty {
                    sectionTitle("関連グラフ")
                    ForEach(evidence.chartNames, id: \.self) { chart in
                        ChartCard(name: chart, range: range)
                    }
                }

                if let guidance = evidence.guidance {
                    sectionTitle("見るポイント")
                    Text(guidance)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Color(.secondarySystemGroupedBackground),
                                    in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .padding()
        }
        .navigationTitle("判断の根拠")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.headline).padding(.top, 4)
    }
}

struct NumberCard: View {
    let item: DashboardData.NumberItem

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(formatted(item.value))
                .font(.title3).bold().foregroundStyle(.teal)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(item.label).font(.caption)
                Text(item.unit).font(.caption2).foregroundStyle(.secondary)
            }
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
