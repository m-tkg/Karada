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
                    zoneLegend(for: SpecChart.zoneLayout(for: spec).bands)
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

    /// 背景の色分けの凡例。実際に描画された帯だけを載せる
    /// (説明があるのに帯が無い、という食い違いを防ぐ)。
    private func zoneLegend(for bands: [SpecChart.Band]) -> some View {
        let kinds = bands.map(\.kind)
        let items: [(String, Color)] = [
            kinds.contains(.safe) ? ("目安の範囲", Color.green) : nil,
            kinds.contains(.danger) ? ("注意", Color.red) : nil,
        ].compactMap { $0 }
        return HStack(spacing: 14) {
            ForEach(items, id: \.0) { text, color in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color.opacity(0.18))
                        .frame(width: 12, height: 12)
                    Text(text)
                }
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
}

/// ドメイン指定がある時だけ Y 軸の範囲を固定する。
private struct OptionalYScale: ViewModifier {
    let domain: ClosedRange<Double>?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let domain {
            content.chartYScale(domain: domain)
        } else {
            content
        }
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

    private var points: [Point] { Self.makePoints(spec) }

    private static func makePoints(_ spec: ChartSpec) -> [Point] {
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
        let layout = SpecChart.zoneLayout(for: spec)
        Group {
            if isLine {
                Chart {
                    zoneMarks(layout)
                    ForEach(pts) { p in
                        LineMark(x: .value("日付", p.date), y: .value(spec.ylabel, p.value))
                            .foregroundStyle(by: .value("系列", p.series))
                            .interpolationMethod(.monotone)
                    }
                }
            } else {
                Chart {
                    zoneMarks(layout)
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
        .modifier(OptionalYScale(domain: layout.domain))
    }

    /// 安全(薄緑)・危険(薄赤)エリアをデータの背後に敷くマーク。
    @ChartContentBuilder
    private func zoneMarks(_ layout: ZoneLayout) -> some ChartContent {
        ForEach(layout.bands) { band in
            RectangleMark(
                xStart: .value("期間開始", band.xLo),
                xEnd: .value("期間終了", band.xHi),
                yStart: .value(spec.ylabel, band.lo),
                yEnd: .value(spec.ylabel, band.hi)
            )
            .foregroundStyle(band.color.opacity(0.08))
        }
    }

    // ------------------------------------------------------------ 安全/危険エリア

    /// 実際に描画する帯。Y 軸ドメインへクランプ済み。
    struct Band: Identifiable {
        let id = UUID()
        let xLo: Date
        let xHi: Date
        let lo: Double
        let hi: Double
        let kind: Zone.Kind
        var color: Color { kind == .safe ? .green : .red }
    }

    /// 帯と、それを見せるための Y 軸ドメイン。
    struct ZoneLayout {
        var domain: ClosedRange<Double>?
        var bands: [Band] = []
    }

    /// しきい値がデータの外にあると帯が一切描かれないため、データの近くにある
    /// しきい値は Y 軸ドメインに含めて必ず見えるようにする。逆に遠すぎるしきい値
    /// (例: 安静時心拍 60bpm 台の人にとっての 100bpm)は含めない。含めるとデータが
    /// 潰れて読めなくなるうえ、その範囲は現状問題が無いことを意味するため。
    static func zoneLayout(for spec: ChartSpec) -> ZoneLayout {
        let zones = zones(forChart: spec.name)
        guard !zones.isEmpty else { return ZoneLayout(domain: nil) }
        let pts = makePoints(spec)
        let values = pts.map(\.value)
        guard let rawMin = values.min(), let dMax = values.max(),
              let xLo = pts.map(\.date).min(), let xHi = pts.map(\.date).max()
        else { return ZoneLayout(domain: nil) }

        let isBar = spec.kind == .bar || spec.kind == .stackedBar
        let dMin = isBar ? Swift.min(0, rawMin) : rawMin  // 棒グラフの基線は 0

        var spread = dMax - dMin
        if spread <= 0 { spread = Swift.max(abs(dMax) * 0.2, 1) }  // 値が一定の場合
        let reachLo = dMin - spread
        let reachHi = dMax + spread

        // データの手が届く範囲にあるしきい値だけ軸に取り込む
        var lo = dMin
        var hi = dMax
        var extended = false
        for bound in zones.flatMap({ [$0.lower, $0.upper] }).compactMap({ $0 }) {
            guard bound >= reachLo, bound <= reachHi else { continue }
            lo = Swift.min(lo, bound)
            hi = Swift.max(hi, bound)
            extended = true
        }

        var domain: ClosedRange<Double>?
        if extended {
            // 端に来たしきい値でも帯に厚みが出るよう余白を足す
            var span = hi - lo
            if span <= 0 { span = Swift.max(abs(hi) * 0.2, 1) }
            let pad = span * 0.12
            lo = isBar ? Swift.min(lo, 0) : lo - pad
            hi += pad
            domain = lo...hi
        }

        let bands: [Band] = zones.compactMap { z in
            let bLo = Swift.max(z.lower ?? lo, lo)
            let bHi = Swift.min(z.upper ?? hi, hi)
            guard bHi > bLo else { return nil }  // 表示範囲と重ならない帯は描かない
            return Band(xLo: xLo, xHi: xHi, lo: bLo, hi: bHi, kind: z.kind)
        }
        guard !bands.isEmpty else { return ZoneLayout(domain: domain) }
        return ZoneLayout(domain: domain, bands: bands)
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
        case "walking_speed":  // 歩行速度 ≒ 1.2 m/s(4.3 km/h)以上で良好、0.8 m/s(2.9 km/h)未満は要注意
            return [Zone(lower: 4.3, upper: nil, kind: .safe),
                    Zone(lower: nil, upper: 2.9, kind: .danger)]
        case "cycle_len":  // 正常な月経周期はおおむね 21〜35 日、45 日以上は長め
            return [Zone(lower: 21, upper: 35, kind: .safe),
                    Zone(lower: 45, upper: nil, kind: .danger)]
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
