import Charts
import SwiftUI

/// HealthKit から端末上で組み立てたチャート spec を Swift Charts で描画する。
/// サーバーには依存しない(LocalAnalytics が HealthKit を直接集計する)。
struct ChartCard: View {
    let name: String
    let range: String

    @Environment(AppNavigation.self) private var nav: AppNavigation?

    @State private var spec: ChartSpec?
    @State private var failed = false
    @State private var profile = HealthProfile()

    /// 解説へ飛べるグラフかどうか(将来チャートが増えても壊れないようにガードする)。
    private var hasGlossary: Bool { Glossary.location(forChart: name) != nil }

    var body: some View {
        Group {
            if let spec {
                if hasGlossary, let nav {
                    Button { nav.showGlossary(forChart: name) } label: { card(spec) }
                        .buttonStyle(.plain)
                        .accessibilityHint("この指標の説明を開きます")
                } else {
                    card(spec)
                }
            } else if failed {
                VStack(alignment: .leading, spacing: 10) {
                    Text(LocalAnalytics.chartTitle(name: name))
                        .font(.subheadline)
                        .bold()
                    ContentUnavailableView(
                        "データがありません",
                        systemImage: "chart.xyaxis.line",
                        description: Text("この期間にヘルスケアの記録がありません。"
                                          + "期間を広げるか、記録が保存されているか確認してください。")
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
            profile = await HealthKitReader().profile().withHeight()
            do {
                spec = try await LocalAnalytics.buildChart(name: name, range: range)
            } catch {
                failed = true  // データ無しなどは静かに非表示
            }
        }
    }

    /// グラフ本体のカード。タップで解説へ飛べるときはタイトル横に ⓘ を出す。
    private func card(_ spec: ChartSpec) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(spec.title).font(.subheadline).bold()
                Spacer(minLength: 4)
                if hasGlossary {
                    Image(systemName: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            SpecChart(spec: spec, profile: profile)
                .frame(height: 190)
            sparseNote(for: spec)
            zoneLegend(for: SpecChart.zoneLayout(for: spec, profile: profile).bands)
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 12))
    }

    /// 記録が少ないときに件数を明示する。点が数個しか無いグラフは一見して
    /// 「データが無い」のか「記録が少ないだけ」なのか区別が付かないため。
    @ViewBuilder
    private func sparseNote(for spec: ChartSpec) -> some View {
        let count = SpecChart.pointCount(of: spec)
        if count <= 5 {
            Text("この期間の記録は \(count) 件です。期間を広げると推移を確認できます。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    /// 背景の色分けの凡例。実際に描画された帯だけを載せる
    /// (説明があるのに帯が無い、という食い違いを防ぐ)。
    private func zoneLegend(for bands: [SpecChart.Band]) -> some View {
        let kinds = bands.map(\.kind)
        let items: [(String, Color)] = [SpecChart.Zone.Kind.safe, .caution, .danger]
            .filter { kinds.contains($0) }
            .map { (SpecChart.label(for: $0), SpecChart.color(for: $0)) }
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
    var profile: HealthProfile = .init()

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

    /// 記録が疎なほどシンボルを大きくする。
    /// 折れ線は点が1つだと線分を描けず、シンボルが無いと何も表示されないため
    /// (体重や VO2 max のように毎日記録されない指標で「データがあるのに空」に見える)。
    private var symbolSize: CGFloat {
        switch SpecChart.pointCount(of: spec) {
        case ..<3: return 80
        case 3..<15: return 50
        case 15..<60: return 20
        default: return 0  // 密すぎる折れ線は点を打つと潰れるので線だけ
        }
    }

    /// 系列あたりの実データ点数(最大)。
    static func pointCount(of spec: ChartSpec) -> Int {
        spec.series.map { $0.values.compactMap { $0 }.count }.max() ?? 0
    }

    var body: some View {
        let pts = points
        let layout = SpecChart.zoneLayout(for: spec, profile: profile)
        Group {
            if isLine {
                Chart {
                    zoneMarks(layout)
                    ForEach(pts) { p in
                        LineMark(x: .value("日付", p.date), y: .value(spec.ylabel, p.value))
                            .foregroundStyle(by: .value("系列", p.series))
                            .interpolationMethod(.monotone)
                            .symbol(by: .value("系列", p.series))
                            .symbolSize(symbolSize)
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
    ///
    /// x を指定せずプロット領域の全幅に敷く。データ点の最初〜最後を矩形にすると、
    /// VO2 max のように記録が疎な指標では帯が細くなり、1点しか無いと幅ゼロで
    /// 消えてしまうため(凡例だけ出て帯が見えない状態になる)。
    @ChartContentBuilder
    private func zoneMarks(_ layout: ZoneLayout) -> some ChartContent {
        ForEach(layout.bands) { band in
            RectangleMark(
                xStart: nil as CGFloat?,
                xEnd: nil as CGFloat?,
                yStart: .value(spec.ylabel, band.lo),
                yEnd: .value(spec.ylabel, band.hi)
            )
            .foregroundStyle(band.color.opacity(0.08))
        }
    }

    // ------------------------------------------------------------ 安全/危険エリア

    /// しきい値がデータ範囲からどれだけ離れているか(範囲内なら 0)。
    private static func distance(of value: Double, from lo: Double, to hi: Double) -> Double {
        if value < lo { return lo - value }
        if value > hi { return value - hi }
        return 0
    }

    /// 実際に描画する帯。Y 軸ドメインへクランプ済み。
    struct Band: Identifiable {
        let id = UUID()
        let lo: Double
        let hi: Double
        let kind: Zone.Kind
        var color: Color { SpecChart.color(for: kind) }
    }

    static func color(for kind: Zone.Kind) -> Color {
        switch kind {
        case .safe: return .green
        case .caution: return .orange
        case .danger: return .red
        }
    }

    /// 凡例に出す段階の名前。緑→橙→赤の順で重くなる。
    static func label(for kind: Zone.Kind) -> String {
        switch kind {
        case .safe: return "目安の範囲"
        case .caution: return "境界域"
        case .danger: return "注意"
        }
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
    static func zoneLayout(for spec: ChartSpec, profile: HealthProfile) -> ZoneLayout {
        let zones = zones(forChart: spec.name, profile: profile)
        guard !zones.isEmpty else { return ZoneLayout(domain: nil) }
        let pts = makePoints(spec)
        let values = pts.map(\.value)
        guard let rawMin = values.min(), let dMax = values.max()
        else { return ZoneLayout(domain: nil) }

        let isBar = spec.kind == .bar || spec.kind == .stackedBar
        let dMin = isBar ? Swift.min(0, rawMin) : rawMin  // 棒グラフの基線は 0

        // しきい値を近い順に Y 軸へ取り込む。判断基準は「データが縦幅の25%以上を
        // 保てるか」だけにする。距離で足切りすると、体脂肪率のように変動が小さい指標で
        // 目安の境界が永久に画面外となり、全体が一様な色になってしまうため。
        // 値が一定・1点だけだとデータ幅が 0 になり歯止めが効かないので下限を置く
        let dataSpan = Swift.max(dMax - dMin, abs(dMax) * 0.05)
        let candidates = zones.flatMap { [$0.lower, $0.upper] }
            .compactMap { $0 }
            .sorted { distance(of: $0, from: dMin, to: dMax) < distance(of: $1, from: dMin, to: dMax) }

        var lo = dMin
        var hi = dMax
        var extended = false
        for bound in candidates {
            let nextLo = Swift.min(lo, bound)
            let nextHi = Swift.max(hi, bound)
            let nextSpan = nextHi - nextLo
            guard nextSpan > 0 else { continue }
            // 最も近い1本は多少潰れても見せる(境界がどこかは必ず伝えたい)。
            // 2本目以降は、データの変化が読める場合だけ取り込む。
            let minRatio = extended ? 0.35 : 0.10
            if dataSpan / nextSpan < minRatio { continue }
            lo = nextLo
            hi = nextHi
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
            return Band(lo: bLo, hi: bHi, kind: z.kind)
        }
        guard !bands.isEmpty else { return ZoneLayout(domain: domain) }
        return ZoneLayout(domain: domain, bands: bands)
    }

    struct Zone {
        enum Kind { case safe, caution, danger }
        var lower: Double?  // nil = 下端(データ最小)まで
        var upper: Double?  // nil = 上端(データ最大)まで
        var kind: Kind
    }

    /// グラフごとの安全(緑)・境界(橙)・注意(赤)エリア。出典は各 case のコメント参照。
    /// 体脂肪率・VO2 max は年齢/性別で基準が変わるため、プロフィールが無ければ帯を出さない。
    static func zones(forChart name: String, profile: HealthProfile = .init()) -> [Zone] {
        switch name {
        case "steps":
            // Lancet Public Health 2022(15コホートのメタ解析)。8,000〜10,000歩で
            // 死亡リスク低下が頭打ち。最低四分位(中央値約3,500歩)がリスク最大。
            return [Zone(lower: 8000, upper: nil, kind: .safe),
                    Zone(lower: 4000, upper: 8000, kind: .caution),
                    Zone(lower: nil, upper: 4000, kind: .danger)]
        case "sleep_total":
            // 睡眠時間と総死亡のメタ解析(U字型、7時間が最小)。長時間側のリスクが
            // 大きく(9時間 RR1.21、10時間 RR1.37)、短時間側は6時間で RR1.01。
            return [Zone(lower: 7, upper: 9, kind: .safe),
                    Zone(lower: 6, upper: 7, kind: .caution),
                    Zone(lower: 9, upper: 10, kind: .caution),
                    Zone(lower: nil, upper: 6, kind: .danger),
                    Zone(lower: 10, upper: nil, kind: .danger)]
        case "exercise":
            // WHO 身体活動ガイドライン 2020: 中強度 週150〜300分(≒1日21.4分)。
            // 週75分(≒1日10.7分)未満は推奨の半分に満たない。
            return [Zone(lower: 150.0 / 7, upper: nil, kind: .safe),
                    Zone(lower: nil, upper: 75.0 / 7, kind: .caution)]
        case "rhr":
            // 日本人間ドック・予防医療学会の安静時心拍数の目安
            // 45〜85: 異常なし / 40〜44・86〜99: 要再検査 / 〜39・100〜: 要精密検査
            return [Zone(lower: 45, upper: 85, kind: .safe),
                    Zone(lower: 40, upper: 45, kind: .caution),
                    Zone(lower: 85, upper: 100, kind: .caution),
                    Zone(lower: nil, upper: 40, kind: .danger),
                    Zone(lower: 100, upper: nil, kind: .danger)]
        case "hrv":
            return hrvZones(profile: profile)
        case "vo2":
            return vo2Zones(profile: profile)
        case "body_fat":
            return bodyFatZones(profile: profile)
        case "body_mass":
            return bodyMassZones(profile: profile)
        case "bmi":
            // 日本肥満学会: 18.5未満 低体重 / 18.5〜25 普通体重 / 25以上 肥満
            // (1度25〜30、2度以上30〜)。性別・年齢に依存しない。
            return [Zone(lower: 18.5, upper: 25, kind: .safe),
                    Zone(lower: 25, upper: 30, kind: .caution),
                    Zone(lower: 17, upper: 18.5, kind: .caution),
                    Zone(lower: 30, upper: nil, kind: .danger),
                    Zone(lower: nil, upper: 17, kind: .danger)]
        case "walking_speed":
            // 歩行速度(m/s → km/h)。1.2 m/s(4.32 km/h)が健常成人の目安、
            // EWGSOP2 は 0.8 m/s(2.88 km/h)以下を低身体機能(サルコペニア)とする。
            return [Zone(lower: 4.32, upper: nil, kind: .safe),
                    Zone(lower: 2.88, upper: 4.32, kind: .caution),
                    Zone(lower: nil, upper: 2.88, kind: .danger)]
        case "cycle_len":
            // ACOG / NICHD: 正常な月経周期は 21〜35 日。範囲外は月経不整。
            return [Zone(lower: 21, upper: 35, kind: .safe),
                    Zone(lower: 35, upper: 45, kind: .caution),
                    Zone(lower: 18, upper: 21, kind: .caution),
                    Zone(lower: 45, upper: nil, kind: .danger),
                    Zone(lower: nil, upper: 18, kind: .danger)]
        default:
            return []
        }
    }

    /// VO2 max の年代別「良好」水準(mL/kg/min)。女性は男性比おおむね 10〜15% 低い。
    /// 出典: 一般成人の年代別 VO2 max 標準値(Cooper Institute 系の基準表)。
    private static func vo2Zones(profile: HealthProfile) -> [Zone] {
        guard let age = profile.age, let isFemale = profile.isFemale else { return [] }
        let good: Double  // これ以上で「良好」
        switch age {
        case ..<30: good = 39
        case 30..<40: good = 37
        case 40..<50: good = 35
        case 50..<60: good = 32
        case 60..<70: good = 28
        default: good = 25
        }
        let target = isFemale ? good * 0.87 : good  // 女性は約13%低い
        let low = target * 0.72                     // 最低五分位相当(死亡リスクが顕著に上昇)
        return [Zone(lower: target, upper: nil, kind: .safe),
                Zone(lower: low, upper: target, kind: .caution),
                Zone(lower: nil, upper: low, kind: .danger)]
    }

    /// HRV(SDNN)の年代別の目安。Apple Watch は約60秒の記録から算出するため、
    /// 24時間ホルター(健常成人 141±39ms)や5分記録(50〜100ms)の基準は使えない。
    /// ウェアラブル実測の分布(20〜30代で50〜70ms、50代で30〜55ms、全体平均約36ms)に合わせる。
    /// 個人差が非常に大きい指標なので、範囲外でも直ちに異常とは限らない。
    private static func hrvZones(profile: HealthProfile) -> [Zone] {
        guard let age = profile.age else { return [] }
        // 各年代の典型範囲の下限。平均的な値が緑に入るようにする
        // (「良好」水準を境にすると平均的な人まで境界域になってしまう)。
        let typical: Double
        switch age {
        case ..<30: typical = 50
        case 30..<40: typical = 45
        case 40..<50: typical = 38
        case 50..<60: typical = 32
        case 60..<70: typical = 27
        default: typical = 23
        }
        return [Zone(lower: typical, upper: nil, kind: .safe),
                Zone(lower: typical * 0.5, upper: typical, kind: .caution),
                Zone(lower: nil, upper: typical * 0.5, kind: .danger)]
    }

    /// 身長から求める体重の目安(日本肥満学会の BMI 判定基準)。
    /// BMI 18.5未満: 低体重 / 18.5〜25: 普通体重 / 25以上: 肥満(1度25〜30、2度以上30〜)。
    /// 標準体重(BMI22)= 身長(m)^2 × 22。
    private static func bodyMassZones(profile: HealthProfile) -> [Zone] {
        guard let h = profile.heightMeters, h > 0.5 else { return [] }
        func weight(bmi: Double) -> Double { bmi * h * h }
        return [Zone(lower: weight(bmi: 18.5), upper: weight(bmi: 25), kind: .safe),
                Zone(lower: weight(bmi: 25), upper: weight(bmi: 30), kind: .caution),
                Zone(lower: weight(bmi: 17), upper: weight(bmi: 18.5), kind: .caution),
                Zone(lower: weight(bmi: 30), upper: nil, kind: .danger),
                Zone(lower: nil, upper: weight(bmi: 17), kind: .danger)]
    }

    /// 体脂肪率の基準(American Council on Exercise)。
    /// 男性: 必須2〜5%、アスリート6〜13%、フィットネス14〜17%、標準18〜24%、25%以上で肥満。
    /// 女性: 必須10〜13%、アスリート14〜20%、フィットネス21〜24%、標準25〜31%、32%以上で肥満。
    ///
    /// アスリート域も健康な範囲なので緑に含める(ここを境界域にすると緑が不当に狭くなる)。
    /// 男性6%・女性14%を下回るのは危険な低さとされるため赤。
    private static func bodyFatZones(profile: HealthProfile) -> [Zone] {
        guard let isFemale = profile.isFemale else { return [] }
        let tooLow = isFemale ? 14.0 : 6.0   // これ未満は危険な低体脂肪
        let obese = isFemale ? 32.0 : 25.0   // これ以上で肥満
        return [Zone(lower: tooLow, upper: obese, kind: .safe),
                Zone(lower: obese, upper: nil, kind: .danger),
                Zone(lower: nil, upper: tooLow, kind: .danger)]
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
