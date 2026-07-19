import Charts
import SwiftUI

/// HealthKit から端末上で組み立てたチャート spec を Swift Charts で描画する。
/// サーバーには依存しない(LocalAnalytics が HealthKit を直接集計する)。
struct ChartCard: View {
    let name: String
    let range: String

    @State private var spec: ChartSpec?
    @State private var failed = false

    var body: some View {
        Group {
            if let spec {
                VStack(alignment: .leading, spacing: 6) {
                    Text(spec.title).font(.subheadline).bold()
                    SpecChart(spec: spec)
                        .frame(height: 190)
                    if !SpecChart.zones(forChart: name).isEmpty {
                        zoneLegend
                    }
                }
                .padding(12)
                .background(Color(.secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 12))
            } else if failed {
                VStack(alignment: .leading, spacing: 10) {
                    Text(LocalAnalytics.chartTitle(name: name))
                        .font(.subheadline)
                        .bold()
                    ContentUnavailableView(
                        "データがありません",
                        systemImage: "chart.xyaxis.line",
                        description: Text("この期間に表示できる記録がありません。")
                    )
                    .frame(height: 160)
                }
                .padding(12)
                .background(Color(.secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 12))
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .frame(height: 190)
            }
        }
        .task(id: "\(name)-\(range)") {
            spec = nil
            failed = false
            do {
                spec = try await LocalAnalytics.buildChart(name: name, range: range)
            } catch {
                failed = true  // データ無しなどは静かに非表示
            }
        }
    }

    /// 背景の色分けの意味を示すコンパクトな凡例。そのグラフに存在する色だけ出す。
    private var zoneLegend: some View {
        let kinds = SpecChart.zones(forChart: name).map(\.kind)
        var items: [(String, Color)] = []
        if kinds.contains(.safe) { items.append(("目安の範囲", .green)) }
        if kinds.contains(.danger) { items.append(("注意", .red)) }
        return HStack(spacing: 14) {
            ForEach(items, id: \.0) { text, color in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color.opacity(0.3))
                        .frame(width: 12, height: 12)
                    Text(text)
                }
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
}

/// spec の kind に応じて LineMark / BarMark を組み立てる。
struct SpecChart: View {
    let spec: ChartSpec

    private struct Point: Identifiable {
        let id = UUID()
        let date: Date
        let value: Double
        let series: String
    }

    private var points: [Point] {
        let dates = spec.labels.map { DayFormat.date($0) }
        var out: [Point] = []
        for s in spec.series {
            let name = s.name ?? spec.title
            for (i, v) in s.values.enumerated() {
                guard let v, let d = dates[i] else { continue }
                out.append(Point(date: d, value: v, series: name))
            }
        }
        return out
    }

    private var seriesNames: [String] {
        spec.series.map { $0.name ?? spec.title }
    }

    private var seriesColors: [Color] {
        spec.series.map { Color(hex: $0.color) }
    }

    private var isLine: Bool { spec.kind == .line || spec.kind == .multiLine }

    var body: some View {
        let pts = points
        let bands = zoneBands(for: pts)
        Group {
            if isLine {
                Chart {
                    zoneMarks(bands)
                    ForEach(pts) { p in
                        LineMark(x: .value("日付", p.date), y: .value(spec.ylabel, p.value))
                            .foregroundStyle(by: .value("系列", p.series))
                            .interpolationMethod(.monotone)
                    }
                }
            } else {
                Chart {
                    zoneMarks(bands)
                    ForEach(pts) { p in
                        BarMark(x: .value("日付", p.date), y: .value(spec.ylabel, p.value))
                            .foregroundStyle(by: .value("系列", p.series))
                    }
                }
            }
        }
        .chartForegroundStyleScale(domain: seriesNames, range: seriesColors)
        .chartLegend(spec.series.count > 1 ? .visible : .hidden)
        .chartYAxisLabel(spec.ylabel)
    }

    /// 安全(薄緑)・危険(薄赤)エリアをデータの背後に敷くマーク。
    @ChartContentBuilder
    private func zoneMarks(_ bands: [Band]) -> some ChartContent {
        ForEach(bands) { band in
            RectangleMark(
                xStart: .value("期間開始", band.xLo),
                xEnd: .value("期間終了", band.xHi),
                yStart: .value(spec.ylabel, band.lo),
                yEnd: .value(spec.ylabel, band.hi)
            )
            .foregroundStyle(band.color.opacity(0.15))
        }
    }

    // ------------------------------------------------------------ 安全/危険エリア

    /// 描画用に、しきい値をデータの表示範囲へクランプしたバンド。
    /// 範囲外に伸ばすと Y 軸の縮尺が歪むため、データの min/max 内に収める。
    private struct Band: Identifiable {
        let id = UUID()
        let xLo: Date
        let xHi: Date
        let lo: Double
        let hi: Double
        let color: Color
    }

    private func zoneBands(for pts: [Point]) -> [Band] {
        let zones = SpecChart.zones(forChart: spec.name)
        guard !zones.isEmpty, !pts.isEmpty else { return [] }
        let dates = pts.map(\.date)
        guard let xLo = dates.min(), let xHi = dates.max() else { return [] }
        let values = pts.map(\.value)
        let isBar = spec.kind == .bar || spec.kind == .stackedBar
        // 棒グラフは基線が 0 のため下端を 0 まで含める
        let vMin = isBar ? Swift.min(0, values.min() ?? 0) : (values.min() ?? 0)
        let vMax = values.max() ?? 0
        guard vMax > vMin else { return [] }
        return zones.compactMap { z in
            let lo = Swift.max(z.lower ?? vMin, vMin)
            let hi = Swift.min(z.upper ?? vMax, vMax)
            guard hi > lo else { return nil }  // データと重ならない帯は描かない
            return Band(xLo: xLo, xHi: xHi, lo: lo, hi: hi, color: z.color)
        }
    }

    struct Zone {
        enum Kind { case safe, danger }
        var lower: Double?  // nil = 下端(データ最小)まで
        var upper: Double?  // nil = 上端(データ最大)まで
        var kind: Kind
        var color: Color { kind == .safe ? .green : .red }
    }

    /// グラフごとの安全(緑)・危険(赤)エリア。公的な一般目安に基づく概算で、
    /// 年齢・性別・個人差により最適値は異なる。アプリの「今月の評価」の判定基準に揃える。
    static func zones(forChart name: String) -> [Zone] {
        switch name {
        case "steps":  // 1日 8,000 歩以上が目安、6,000 歩未満は少なめ
            return [Zone(lower: 8000, upper: nil, kind: .safe),
                    Zone(lower: nil, upper: 6000, kind: .danger)]
        case "sleep_total":  // 成人の推奨 7〜9 時間、6 時間未満は不足
            return [Zone(lower: 7, upper: 9, kind: .safe),
                    Zone(lower: nil, upper: 6, kind: .danger)]
        case "exercise":  // WHO 推奨 週 150 分 ≒ 1日 21 分以上
            return [Zone(lower: 21, upper: nil, kind: .safe)]
        case "rhr":  // 安静時 60 bpm 以下は良好、100 bpm 以上は高め(頻脈域)
            return [Zone(lower: nil, upper: 60, kind: .safe),
                    Zone(lower: 100, upper: nil, kind: .danger)]
        case "vo2":  // 一般成人でおおむね 40 以上が良好、25 未満は低め
            return [Zone(lower: 40, upper: nil, kind: .safe),
                    Zone(lower: nil, upper: 25, kind: .danger)]
        case "body_fat":  // 一般成人の健康域の目安(性差大)。32% 以上は高め
            return [Zone(lower: 10, upper: 25, kind: .safe),
                    Zone(lower: 32, upper: nil, kind: .danger)]
        default:
            return []
        }
    }
}

extension Color {
    /// "#2a78d6" 形式の hex から生成する。
    init(hex: String) {
        var value: UInt64 = 0
        Scanner(string: String(hex.dropFirst())).scanHexInt64(&value)
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
