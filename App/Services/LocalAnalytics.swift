import Foundation
import HealthKit

/// analytics.py / chartspec.py / views._dashboard_sections の Swift 移植。
///
/// HealthKit から取得した値を **端末上で直接集計**し、サーバーを介さずに
/// ダッシュボード・チャートを構築する(アプリ単体動作の要)。サーバー同期は
/// あくまで web 版へのバックアップ用オプションで、ここには関与しない。
enum LocalAnalytics {
    static let rangeDaysMap: [String: Int?] = ["1w": 7, "1m": 31, "1y": 366, "3y": 366 * 3, "all": nil]
    static let rangeLabels: [String: String] = [
        "1w": "直近1週間", "1m": "直近1ヶ月", "1y": "直近1年", "3y": "直近3年", "all": "全期間",
    ]

    static func bucketLabel(_ range: String) -> String {
        switch range {
        case "1w", "1m": return "日"
        case "1y": return "週平均"
        default: return "月平均"
        }
    }

    static func workoutBucketLabel(_ range: String) -> String {
        switch range {
        case "1w": return "日次"
        case "1m": return "週次"
        default: return "月次"
        }
    }

    // ------------------------------------------------------------ 日付ユーティリティ

    static func cutoffDate(range: String, latest: Date) -> Date? {
        guard let daysOptional = rangeDaysMap[range], let days = daysOptional else { return nil }
        return Calendar.current.date(byAdding: .day, value: -days, to: latest)
    }

    static func endExclusive(_ latest: Date) -> Date {
        Calendar.current.date(byAdding: .day, value: 1,
                              to: Calendar.current.startOfDay(for: latest))!
    }

    private static func quantityStartDate(
        identifier: HKQuantityTypeIdentifier, range: String, latest: Date
    ) async -> Date? {
        if let cutoff = cutoffDate(range: range, latest: latest) { return cutoff }
        guard range == "all" else { return nil }
        return await LocalHealthStore.shared.earliestStartDate(type: HKQuantityType(identifier))
    }

    private static func categoryStartDate(
        identifier: HKCategoryTypeIdentifier, range: String, latest: Date
    ) async -> Date? {
        if let cutoff = cutoffDate(range: range, latest: latest) { return cutoff }
        guard range == "all" else { return nil }
        return await LocalHealthStore.shared.earliestStartDate(type: HKCategoryType(identifier))
    }

    private static func weekBucketKey(_ date: Date) -> String {
        // Python date.weekday()(Monday=0)相当のオフセットで週初(月曜)へ丸める
        let weekday = Calendar.current.component(.weekday, from: date)  // 1=Sun...7=Sat
        let offset = (weekday + 5) % 7
        let monday = Calendar.current.date(byAdding: .day, value: -offset, to: date)!
        return DayFormat.string(monday)
    }

    private static func monthBucketKey(_ dateString: String) -> String {
        String(dateString.prefix(7)) + "-01"
    }

    /// {date: value} を期間バケット(1m=日/1y=週/3y・all=月)の平均に畳む。
    static func bucketize(_ daily: [String: Double], range: String) -> ([String], [Double]) {
        if range == "1m" || range == "1w" {
            let items = daily.sorted { $0.key < $1.key }
            return (items.map(\.key), items.map(\.value))
        }
        var buckets: [String: [Double]] = [:]
        for (d, v) in daily {
            guard let date = DayFormat.date(d) else { continue }
            let key = range == "1y" ? weekBucketKey(date) : monthBucketKey(d)
            buckets[key, default: []].append(v)
        }
        let keys = buckets.keys.sorted()
        return (keys, keys.map { k in
            let vs = buckets[k]!
            return vs.reduce(0, +) / Double(vs.count)
        })
    }

    // ------------------------------------------------------------ 数量型の共通取得

    static func quantityUnit(_ id: HKQuantityTypeIdentifier) -> (HKUnit, String) {
        if let e = HealthKitReader.quantityTypes.first(where: { $0.0 == id }) {
            return (e.1, e.2)
        }
        return (.count(), "")
    }

    /// type の日次値を期間バケットで平均した系列(サーバー daily_series と同じ)。
    ///
    /// dedupe=true: 複数ソースがあれば日ごとに合計最大の単一ソースを採用
    /// (歩数等の累積型。iPhone/Watch の二重計上を回避)。
    /// dedupe=false, useSum=true: 全ソース合算(食事記録等、単一ソース想定)。
    /// dedupe=false, useSum=false: 全ソース込みの平均(心拍・体重等)。
    static func dailySeries(identifier: HKQuantityTypeIdentifier, range: String, latest: Date,
                            dedupe: Bool, useSum: Bool) async -> ([String], [Double]) {
        let (unit, _) = quantityUnit(identifier)
        guard let start = await quantityStartDate(identifier: identifier, range: range,
                                                  latest: latest) else {
            return ([], [])
        }
        let end = endExclusive(latest)
        let daily: [String: Double]
        if dedupe {
            daily = await LocalHealthStore.shared.dominantDailySum(
                identifier: identifier, unit: unit, start: start, end: end)
        } else if useSum {
            daily = await LocalHealthStore.shared.dailySum(
                identifier: identifier, unit: unit, start: start, end: end)
        } else {
            daily = await LocalHealthStore.shared.dailyAverage(
                identifier: identifier, unit: unit, start: start, end: end)
        }
        return bucketize(daily, range: range)
    }

    // ------------------------------------------------------------------ 睡眠

    static let asleepStages: Set<String> = ["AsleepUnspecified", "AsleepCore", "AsleepDeep", "AsleepREM"]
    private static let stageOrder = ["AsleepDeep", "AsleepCore", "AsleepREM", "AsleepUnspecified", "Awake"]

    static func shortSleepStage(_ raw: Int) -> String? {
        guard let full = HealthKitReader.sleepValueName(raw) else { return nil }
        let short = String(full.dropFirst("HKCategoryValueSleepAnalysis".count))
        return short == "Asleep" ? "AsleepUnspecified" : short  // 旧形式を統合
    }

    /// 睡眠日を導く(18時以降開始=当日夜、それ以前=前日夜の続き。サーバー v_sleep と同じ)。
    static func sleepDate(for date: Date) -> String {
        let cal = Calendar.current
        let day = cal.startOfDay(for: date)
        let base = cal.component(.hour, from: date) >= 18
            ? day : cal.date(byAdding: .day, value: -1, to: day)!
        return DayFormat.string(base)
    }

    /// 重複・入れ子の区間をマージした合計秒。
    static func mergeSeconds(_ intervals: [(Date, Date)]) -> TimeInterval {
        guard !intervals.isEmpty else { return 0 }
        let sorted = intervals.sorted { $0.0 < $1.0 }
        var total: TimeInterval = 0
        var curStart = sorted[0].0
        var curEnd = sorted[0].1
        for (s, e) in sorted.dropFirst() {
            if s <= curEnd {
                curEnd = max(curEnd, e)
            } else {
                total += curEnd.timeIntervalSince(curStart)
                curStart = s
                curEnd = e
            }
        }
        total += curEnd.timeIntervalSince(curStart)
        return total
    }

    /// 睡眠日ごとの実睡眠時間(時間)。ソース間の重複区間はマージする。
    static func sleepDailyHours(samples: [HKCategorySample]) -> [String: Double] {
        var byDate: [String: [(Date, Date)]] = [:]
        for s in samples {
            guard let stage = shortSleepStage(s.value), asleepStages.contains(stage) else { continue }
            byDate[sleepDate(for: s.startDate), default: []].append((s.startDate, s.endDate))
        }
        var out: [String: Double] = [:]
        for (d, ivs) in byDate { out[d] = mergeSeconds(ivs) / 3600.0 }
        return out
    }

    static func sleepTotalSeries(range: String, latest: Date) async -> ([String], [Double]) {
        guard let start = await categoryStartDate(identifier: .sleepAnalysis, range: range,
                                                  latest: latest) else {
            return ([], [])
        }
        let samples = await LocalHealthStore.shared.categorySamples(
            identifier: .sleepAnalysis, start: start, end: endExclusive(latest))
        return bucketize(sleepDailyHours(samples: samples), range: range)
    }

    /// 睡眠日ごとに「ステージ情報を持つソース優先→合計時間」で単一ソースを選ぶ
    /// (混ぜるとステージが二重計上されるため。サーバーと同じ基準)。
    private static func dominantStageSource(
        _ perSourceStageSec: [SleepKey: [String: Double]]
    ) -> [String: String] {
        var bySourceTotals: [String: [(source: String, hasStage: Bool, total: Double)]] = [:]
        for (key, m) in perSourceStageSec {
            let hasStage = m.keys.contains { $0 == "AsleepCore" || $0 == "AsleepDeep" || $0 == "AsleepREM" }
            bySourceTotals[key.date, default: []].append((key.source, hasStage, m.values.reduce(0, +)))
        }
        var dominant: [String: String] = [:]
        for (date, list) in bySourceTotals {
            let best = list.sorted {
                if $0.hasStage != $1.hasStage { return $0.hasStage }
                if $0.total != $1.total { return $0.total > $1.total }
                return $0.source < $1.source
            }.first
            if let best { dominant[date] = best.source }
        }
        return dominant
    }

    private struct SleepKey: Hashable { let date: String; let source: String }

    private static func perSourceStageSeconds(_ samples: [HKCategorySample]) -> [SleepKey: [String: Double]] {
        var out: [SleepKey: [String: Double]] = [:]
        for s in samples {
            guard let stage = shortSleepStage(s.value), stageOrder.contains(stage) else { continue }
            let key = SleepKey(date: sleepDate(for: s.startDate), source: s.sourceRevision.source.name)
            out[key, default: [:]][stage, default: 0] += s.endDate.timeIntervalSince(s.startDate)
        }
        return out
    }

    /// ステージ別時間(時間/日平均)の積み上げ用系列。(サーバー sleep_stage_series と同じ)
    static func sleepStageSeries(range: String, latest: Date) async -> ([String], [String: [Double]]) {
        guard let start = await categoryStartDate(identifier: .sleepAnalysis, range: range,
                                                  latest: latest) else {
            return ([], [:])
        }
        let samples = await LocalHealthStore.shared.categorySamples(
            identifier: .sleepAnalysis, start: start, end: endExclusive(latest))

        let perSource = perSourceStageSeconds(samples)
        let dominant = dominantStageSource(perSource)

        var daily: [String: [String: Double]] = [:]
        for (key, m) in perSource where dominant[key.date] == key.source {
            for (stage, sec) in m {
                daily[key.date, default: [:]][stage, default: 0] += sec / 3600.0
            }
        }

        var labels: [String] = []
        var series: [String: [Double]] = [:]
        for stage in stageOrder {
            var m: [String: Double] = [:]
            for date in daily.keys { m[date] = daily[date]?[stage] ?? 0.0 }
            let (lab, vals) = bucketize(m, range: range)
            labels = lab
            series[stage] = vals
        }
        series = series.filter { _, vals in vals.contains { $0 > 0 } }
        return (labels, series)
    }

    /// 深い睡眠の割合(ステージ優先の dominant ソース基準)。データが無ければ nil。
    static func deepSleepRatio(samples: [HKCategorySample], sinceExclusive: String) -> Double? {
        let filtered = samples.filter { sleepDate(for: $0.startDate) > sinceExclusive }
        let perSource = perSourceStageSeconds(filtered)
        let dominant = dominantStageSource(perSource)
        var deep = 0.0, total = 0.0
        for (key, m) in perSource where dominant[key.date] == key.source {
            for (stage, sec) in m {
                total += sec
                if stage == "AsleepDeep" { deep += sec }
            }
        }
        guard total > 0 else { return nil }
        return deep / total
    }

    /// 就床時刻(睡眠日ごとの最初の記録)のばらつき(標準偏差、分)。10晩未満なら nil。
    static func bedtimeSDMinutes(samples: [HKCategorySample], sinceExclusive: String) -> Double? {
        var minTimeByDate: [String: (h: Int, m: Int)] = [:]
        let cal = Calendar.current
        for s in samples {
            guard let stage = shortSleepStage(s.value), stage != "InBed" else { continue }
            let sd = sleepDate(for: s.startDate)
            guard sd > sinceExclusive else { continue }
            let hm = (cal.component(.hour, from: s.startDate), cal.component(.minute, from: s.startDate))
            if minTimeByDate[sd] == nil || hm < minTimeByDate[sd]! {
                minTimeByDate[sd] = hm
            }
        }
        guard minTimeByDate.count >= 10 else { return nil }
        let mins = minTimeByDate.values.map { (($0.h * 60 + $0.m - 18 * 60) % 1440 + 1440) % 1440 }
        let mean = Double(mins.reduce(0, +)) / Double(mins.count)
        let variance = mins.reduce(0.0) { $0 + pow(Double($1) - mean, 2) } / Double(mins.count)
        return variance.squareRoot()
    }

    // ------------------------------------------------------------ 月経周期・運動記録

    static func menstrualCycles(samples: [HKCategorySample]) -> [DashboardData.Cycle] {
        var days = Set<String>()
        for s in samples {
            guard let full = HealthKitReader.menstrualValueName(s.value) else { continue }
            let short = String(full.dropFirst("HKCategoryValueMenstrualFlow".count))
            guard short != "None" else { continue }
            days.insert(DayFormat.string(s.startDate))
        }
        let sortedDates = days.compactMap { DayFormat.date($0) }.sorted()
        guard !sortedDates.isEmpty else { return [] }
        var blocks: [[Date]] = [[sortedDates[0]]]
        for d in sortedDates.dropFirst() {
            let lastInBlock = blocks[blocks.count - 1].last!
            let gap = Calendar.current.dateComponents([.day], from: lastInBlock, to: d).day ?? 0
            if gap <= 2 {
                blocks[blocks.count - 1].append(d)
            } else {
                blocks.append([d])
            }
        }
        var cycles: [DashboardData.Cycle] = []
        for (i, block) in blocks.enumerated() {
            var cycleLen: Int?
            if i + 1 < blocks.count {
                cycleLen = Calendar.current.dateComponents([.day], from: block[0],
                                                           to: blocks[i + 1][0]).day
            }
            cycles.append(.init(start: DayFormat.string(block[0]), flowDays: block.count,
                                cycleLen: cycleLen))
        }
        return cycles
    }

    static func recentWorkouts(workouts: [HKWorkout], n: Int) -> [DashboardData.RecentWorkout] {
        let sorted = workouts.sorted { $0.startDate > $1.startDate }.prefix(n)
        return sorted.map { w in
            let distanceQty = w.statistics(for: HKQuantityType(.distanceWalkingRunning))?.sumQuantity()
                ?? w.statistics(for: HKQuantityType(.distanceCycling))?.sumQuantity()
                ?? w.statistics(for: HKQuantityType(.distanceSwimming))?.sumQuantity()
            let energyQty = w.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity()
            let activityFull = WorkoutTypeNames.name(for: w.workoutActivityType)
            let activityShort = String(activityFull.dropFirst("HKWorkoutActivityType".count))
            return DashboardData.RecentWorkout(
                localDate: DayFormat.string(w.startDate),
                activityType: activityShort,
                activityLabel: WorkoutLabels.label(for: activityShort),
                duration: w.duration / 60.0,
                totalDistance: distanceQty?.doubleValue(for: .meterUnit(with: .kilo)),
                totalDistanceUnit: distanceQty != nil ? "km" : nil,
                totalEnergyBurned: energyQty?.doubleValue(for: .kilocalorie()))
        }
    }

    /// 期間バケット × 種別のワークアウト回数。上位5種以外は「その他」。
    /// 戻り値の `order` は表示・配色に使う挿入順(上位種目 → その他)。
    static func workoutsBucketed(workouts: [HKWorkout], range: String,
                                 ) -> (labels: [String], order: [String], series: [String: [Double]]) {
        guard !workouts.isEmpty else { return ([], [], [:]) }
        let bucketKey: (Date) -> String
        switch range {
        case "1w": bucketKey = { DayFormat.string($0) }
        case "1m": bucketKey = weekBucketKey
        default:   bucketKey = { monthBucketKey(DayFormat.string($0)) }
        }
        struct Row { let bucket: String; let activity: String }
        let rows: [Row] = workouts.map { w in
            let bucket = bucketKey(w.startDate)
            let full = WorkoutTypeNames.name(for: w.workoutActivityType)
            return Row(bucket: bucket, activity: String(full.dropFirst("HKWorkoutActivityType".count)))
        }
        var totals: [String: Int] = [:]
        for r in rows { totals[r.activity, default: 0] += 1 }
        let top = totals.sorted { $0.value > $1.value }.prefix(5).map(\.key)
        let months = Array(Set(rows.map(\.bucket))).sorted()
        let idx = Dictionary(uniqueKeysWithValues: months.enumerated().map { ($1, $0) })

        var series: [String: [Double]] = [:]
        for t in top { series[t] = [Double](repeating: 0, count: months.count) }
        var other = [Double](repeating: 0, count: months.count)
        for r in rows {
            guard let i = idx[r.bucket] else { continue }
            if series[r.activity] != nil { series[r.activity]![i] += 1 } else { other[i] += 1 }
        }
        var order = Array(top)
        if other.contains(where: { $0 > 0 }) {
            series["その他"] = other
            order.append("その他")
        }
        return (months, order, series)
    }

    // ---------------------------------------------- いまの数字 / 今日の発見

    private struct NowMetric {
        let label: String
        let identifier: HKQuantityTypeIdentifier?
        let dedupe: Bool
        let useSum: Bool
        let unit: String
        let decimals: Int
        let upGood: Bool?
    }

    private static let nowMetrics: [NowMetric] = [
        .init(label: "歩数", identifier: .stepCount, dedupe: true, useSum: true,
             unit: "歩/日", decimals: 0, upGood: true),
        .init(label: "睡眠", identifier: nil, dedupe: false, useSum: false,
             unit: "時間/日", decimals: 1, upGood: true),
        .init(label: "安静時心拍", identifier: .restingHeartRate, dedupe: false, useSum: false,
             unit: "bpm", decimals: 1, upGood: false),
        .init(label: "HRV", identifier: .heartRateVariabilitySDNN, dedupe: false, useSum: false,
             unit: "ms", decimals: 1, upGood: true),
        .init(label: "体重", identifier: .bodyMass, dedupe: false, useSum: false,
             unit: "kg", decimals: 2, upGood: nil),
        .init(label: "消費エネルギー", identifier: .activeEnergyBurned, dedupe: true, useSum: true,
             unit: "kcal/日", decimals: 0, upGood: true),
    ]

    static func roundVal(_ v: Double, _ nd: Int) -> Double {
        let m = pow(10.0, Double(nd))
        return (v * m).rounded() / m
    }

    static func formatComma(_ v: Double, decimals: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = ","
        f.minimumFractionDigits = decimals
        f.maximumFractionDigits = decimals
        return f.string(from: NSNumber(value: v)) ?? "\(v)"
    }

    static func signedPercent(_ pct: Double) -> String { String(format: "%+.0f%%", pct) }

    /// daily マップの lo < 日付 <= hi の平均。件数不足なら nil。
    static func avgWindow(_ daily: [String: Double], lo: String, hi: String? = nil,
                          minN: Int = 1) -> Double? {
        let vals = daily.compactMap { (d, v) -> Double? in
            guard d > lo, hi == nil || d <= hi! else { return nil }
            return v
        }
        guard vals.count >= minN else { return nil }
        return vals.reduce(0, +) / Double(vals.count)
    }

    static func valuesWindow(_ daily: [String: Double], lo: String,
                             hi: String? = nil) -> [Double] {
        daily.compactMap { d, v in
            guard d > lo, hi == nil || d <= hi! else { return nil }
            return v
        }
    }

    static func standardDeviation(_ values: [Double]) -> Double? {
        guard values.count >= 2 else { return nil }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0.0) { $0 + pow($1 - mean, 2) } / Double(values.count)
        return variance.squareRoot()
    }

    static func longestStreak(_ daily: [String: Double], lo: String,
                              matching predicate: (Double) -> Bool) -> Int {
        let dates = daily.keys.filter { $0 > lo }.sorted()
        var best = 0
        var current = 0
        for date in dates {
            if let value = daily[date], predicate(value) {
                current += 1
                best = max(best, current)
            } else {
                current = 0
            }
        }
        return best
    }

    static func pctChange(cur: Double?, prev: Double?) -> Double? {
        guard let cur, let prev, prev != 0 else { return nil }
        return (cur - prev) / abs(prev) * 100
    }

    private static func dailyMap(for m: NowMetric, sleepMap: [String: Double],
                                 start: Date, end: Date) async -> [String: Double] {
        guard let id = m.identifier else { return sleepMap }
        let (unit, _) = quantityUnit(id)
        if m.dedupe {
            return await LocalHealthStore.shared.dominantDailySum(identifier: id, unit: unit,
                                                                   start: start, end: end)
        } else if m.useSum {
            return await LocalHealthStore.shared.dailySum(identifier: id, unit: unit,
                                                           start: start, end: end)
        }
        return await LocalHealthStore.shared.dailyAverage(identifier: id, unit: unit,
                                                           start: start, end: end)
    }

    static func nowNumbers(latest: Date) async -> [DashboardData.NumberItem] {
        let d30Date = Calendar.current.date(byAdding: .day, value: -30, to: latest)!
        let d60Date = Calendar.current.date(byAdding: .day, value: -60, to: latest)!
        let d30 = DayFormat.string(d30Date)
        let d60 = DayFormat.string(d60Date)
        let end = endExclusive(latest)

        let sleepSamples = await LocalHealthStore.shared.categorySamples(
            identifier: .sleepAnalysis, start: d60Date, end: end)
        let sleepMap = sleepDailyHours(samples: sleepSamples)

        var out: [DashboardData.NumberItem] = []
        for m in nowMetrics {
            let daily = await dailyMap(for: m, sleepMap: sleepMap, start: d60Date, end: end)
            guard let curAvg = avgWindow(daily, lo: d30, minN: 1) else { continue }
            let prevAvg = avgWindow(daily, lo: d60, hi: d30, minN: 1)
            let delta = prevAvg.map { curAvg - $0 }
            let deltaGood: Bool? = {
                guard let delta, let up = m.upGood else { return nil }
                return (delta >= 0) == up
            }()
            out.append(.init(label: m.label, value: roundVal(curAvg, m.decimals), unit: m.unit,
                             delta: delta.map { roundVal($0, m.decimals) }, deltaGood: deltaGood))
        }
        return out
    }

    static func insights(latest: Date) async -> [DashboardData.Insight] {
        let d7 = DayFormat.string(Calendar.current.date(byAdding: .day, value: -7, to: latest)!)
        let d35Date = Calendar.current.date(byAdding: .day, value: -35, to: latest)!
        let d35 = DayFormat.string(d35Date)
        let end = endExclusive(latest)

        let sleepSamples = await LocalHealthStore.shared.categorySamples(
            identifier: .sleepAnalysis, start: d35Date, end: end)
        let sleepMap = sleepDailyHours(samples: sleepSamples)

        struct Found { let text: String; let good: Bool?; let magnitude: Double }
        var found: [Found] = []
        for m in nowMetrics {
            let daily = await dailyMap(for: m, sleepMap: sleepMap, start: d35Date, end: end)
            let cur = daily.compactMap { $0.key > d7 ? $0.value : nil }
            let base = daily.compactMap { $0.key >= d35 && $0.key <= d7 ? $0.value : nil }
            guard cur.count >= 3, base.count >= 7 else { continue }
            let curAvg = cur.reduce(0, +) / Double(cur.count)
            let baseAvg = base.reduce(0, +) / Double(base.count)
            guard baseAvg != 0 else { continue }
            let pct = (curAvg - baseAvg) / abs(baseAvg) * 100
            guard abs(pct) >= 5 else { continue }
            let direction = pct > 0 ? "増加" : "減少"
            let good = m.upGood.map { (pct > 0) == $0 }
            let unitShort = m.unit.split(separator: "/").first.map(String.init) ?? m.unit
            let valStr = formatComma(roundVal(curAvg, m.decimals), decimals: m.decimals)
            found.append(Found(
                text: "\(m.label)が直近7日で \(valStr) \(unitShort)"
                    + "(それ以前の4週平均比 \(signedPercent(pct)) \(direction))",
                good: good, magnitude: abs(pct)))
        }
        found.sort { $0.magnitude > $1.magnitude }
        return found.prefix(5).map { DashboardData.Insight(text: $0.text, good: $0.good) }
    }

    static func assessments(latest: Date) async -> DashboardData.Assessments {
        let d30Date = Calendar.current.date(byAdding: .day, value: -30, to: latest)!
        let d60Date = Calendar.current.date(byAdding: .day, value: -60, to: latest)!
        let d30 = DayFormat.string(d30Date)
        let d60 = DayFormat.string(d60Date)
        let end = endExclusive(latest)

        var good: [DashboardData.Assessments.Item] = []
        var improve: [DashboardData.Assessments.Item] = []
        typealias Evidence = DashboardData.Assessments.Evidence
        typealias Metric = DashboardData.Assessments.Evidence.Metric
        func defaultCharts(for title: String) -> [String] {
            if title.contains("睡眠") || title.contains("就寝") || title.contains("呼吸") {
                return ["sleep_total", "sleep_stages", "breathing_disturbances"]
            }
            if title.contains("歩数") || title.contains("活動量") {
                return ["steps", "exercise", "active_energy"]
            }
            if title.contains("運動量") {
                return ["exercise", "active_energy", "steps"]
            }
            if title.contains("安静時心拍") {
                return ["rhr", "sleep_total"]
            }
            if title.contains("HRV") || title.contains("回復") {
                return ["hrv", "rhr", "sleep_total"]
            }
            if title.contains("心肺") || title.contains("VO2") {
                return ["vo2", "exercise", "rhr"]
            }
            if title.contains("体重") {
                return ["body_mass", "active_energy", "energy_balance"]
            }
            if title.contains("カロリー") || title.contains("エネルギー") {
                return ["energy_balance", "active_energy"]
            }
            if title.contains("歩き方") {
                return ["walking_speed", "walking_steplen", "walking_balance"]
            }
            return []
        }
        func add(_ list: inout [DashboardData.Assessments.Item], _ title: String, _ detail: String,
                 metrics: [Metric] = [], reasons: [String] = [], charts: [String]? = nil,
                 guidance: String? = nil) {
            let chartNames = charts ?? defaultCharts(for: title)
            let visibleMetrics = metrics.isEmpty
                ? [Metric(label: "評価期間", value: "直近30日")]
                : metrics
            let evidence = Evidence(
                summary: detail,
                metrics: visibleMetrics,
                reasons: reasons.isEmpty ? [detail] : reasons,
                chartNames: chartNames,
                guidance: guidance)
            list.append(.init(title: title, detail: detail, evidence: evidence))
        }

        let (stepUnit, _) = quantityUnit(.stepCount)
        let steps = await LocalHealthStore.shared.dominantDailySum(
            identifier: .stepCount, unit: stepUnit, start: d60Date, end: end)
        if let cur = avgWindow(steps, lo: d30, minN: 7) {
            if cur >= 8000 {
                add(&good, "よく歩けています",
                    "1日平均 \(formatComma(cur, decimals: 0)) 歩。目安の 8,000 歩を上回っています。",
                    metrics: [Metric(label: "直近30日平均", value: "\(formatComma(cur, decimals: 0)) 歩/日"),
                              Metric(label: "目安", value: "8,000 歩/日")])
            } else if cur >= 6000 {
                add(&improve, "歩数はあと一歩",
                    "1日平均 \(formatComma(cur, decimals: 0)) 歩。"
                    + "あと \(formatComma(8000 - cur, decimals: 0)) 歩で目安の 8,000 歩です。",
                    metrics: [Metric(label: "直近30日平均", value: "\(formatComma(cur, decimals: 0)) 歩/日"),
                              Metric(label: "目安との差", value: "\(formatComma(8000 - cur, decimals: 0)) 歩")],
                    reasons: ["直近30日の平均歩数が 8,000 歩/日を下回っています。",
                              "6,000 歩/日は超えているため、少し上乗せできる余地として扱っています。"],
                    guidance: "歩数グラフで、少ない曜日や落ち込みが続く期間がないかを見ると、増やしやすいタイミングを見つけやすくなります。")
            } else {
                add(&improve, "歩数を増やしましょう",
                    "1日平均 \(formatComma(cur, decimals: 0)) 歩と少なめです。まずは 6,000 歩を目標に。",
                    metrics: [Metric(label: "直近30日平均", value: "\(formatComma(cur, decimals: 0)) 歩/日"),
                              Metric(label: "最初の目安", value: "6,000 歩/日")],
                    reasons: ["直近30日の平均歩数が 6,000 歩/日を下回っています。",
                              "平均が低い時は、まず日常の移動量を増やす方が続けやすいです。"],
                    guidance: "歩数グラフでゼロに近い日や極端に少ない日が多いか確認してください。平均より、まず少ない日を底上げするのが効きます。")
            }
        }

        let sleepSamplesWide = await LocalHealthStore.shared.categorySamples(
            identifier: .sleepAnalysis, start: d60Date, end: end)
        let sleepMap = sleepDailyHours(samples: sleepSamplesWide)
        let sleepCur = avgWindow(sleepMap, lo: d30, minN: 7)
        if let sCur = sleepCur {
            if sCur >= 7.0 && sCur <= 9.0 {
                add(&good, "睡眠時間が適正",
                    "平均 \(String(format: "%.1f", sCur)) 時間。成人の推奨(7〜9時間)の範囲内です。")
            } else if sCur < 6.5 {
                add(&improve, "睡眠が足りていません",
                    "平均 \(String(format: "%.1f", sCur)) 時間。推奨の 7 時間まで"
                    + "あと \(String(format: "%.1f", 7 - sCur)) 時間です。就寝を少し早めてみましょう。")
            } else if sCur > 9.5 {
                add(&improve, "睡眠時間が長めです",
                    "平均 \(String(format: "%.1f", sCur)) 時間。過眠が続く場合は睡眠の質も確認を。")
            }
        }

        if let sd = bedtimeSDMinutes(samples: sleepSamplesWide, sinceExclusive: d30) {
            if sd <= 45 {
                add(&good, "就寝リズムが安定",
                    "就床時刻のばらつきは ±\(Int(sd.rounded())) 分。規則正しい生活ができています。")
            } else if sd >= 75 {
                add(&improve, "就寝時刻がばらついています",
                    "就床時刻のばらつきが ±\(Int(sd.rounded())) 分あります。"
                    + "毎日同じ時刻の就寝が睡眠の質を上げます。")
            }
        }

        let sleepVals = valuesWindow(sleepMap, lo: d30)
        if sleepVals.count >= 10 {
            let shortNights = sleepVals.filter { $0 < 6.0 }.count
            let veryShortNights = sleepVals.filter { $0 < 5.0 }.count
            let shortStreak = longestStreak(sleepMap, lo: d30) { $0 < 6.0 }
            if shortNights >= 10 || veryShortNights >= 3 || shortStreak >= 3 {
                add(&improve, "睡眠負債がたまっています",
                    "直近30日で6時間未満の睡眠が \(shortNights) 日"
                    + (shortStreak >= 3 ? "、最長 \(shortStreak) 日連続" : "")
                    + "あります。短い睡眠が続く週は予定や就寝時刻を見直しましょう。")
            } else if shortNights <= 3 {
                add(&good, "短い睡眠が少なめです",
                    "直近30日の6時間未満の睡眠は \(shortNights) 日。睡眠時間を安定して確保できています。")
            }
        }

        let (exUnit, _) = quantityUnit(.appleExerciseTime)
        let exercise = await LocalHealthStore.shared.dominantDailySum(
            identifier: .appleExerciseTime, unit: exUnit, start: d60Date, end: end)
        if let exCur = avgWindow(exercise, lo: d30, minN: 7) {
            let weekly = exCur * 7
            if weekly >= 150 {
                add(&good, "WHO 推奨の運動量を達成",
                    "エクササイズ 週 \(String(format: "%.0f", weekly)) 分。"
                    + "推奨の週 150 分をクリアしています。")
            } else {
                add(&improve, "運動量が推奨に届いていません",
                    "エクササイズ 週 \(String(format: "%.0f", weekly)) 分。WHO 推奨は週 150 分"
                    + "(あと \(String(format: "%.0f", 150 - weekly)) 分)です。")
            }
        }

        let (rhrUnit, _) = quantityUnit(.restingHeartRate)
        let rhr = await LocalHealthStore.shared.dailyAverage(
            identifier: .restingHeartRate, unit: rhrUnit, start: d60Date, end: end)
        let rCur = avgWindow(rhr, lo: d30, minN: 7)
        let rPrev = avgWindow(rhr, lo: d60, hi: d30, minN: 7)
        if let rCur, let rPrev {
            let delta = rCur - rPrev
            if delta <= -2 {
                add(&good, "安静時心拍が下がっています",
                    "前月比 \(String(format: "%+.1f", delta)) bpm(平均 \(String(format: "%.0f", rCur)) bpm)。"
                    + "心肺機能が向上している兆しです。")
            } else if delta >= 3 {
                add(&improve, "安静時心拍が上がっています",
                    "前月比 \(String(format: "%+.1f", delta)) bpm(平均 \(String(format: "%.0f", rCur)) bpm)。"
                    + "疲労・睡眠不足・体調変化のサインかもしれません。")
            } else if rCur < 60 {
                add(&good, "安静時心拍が良好", "平均 \(String(format: "%.0f", rCur)) bpm と低めで安定しています。")
            }
        }

        let (hrvUnit, _) = quantityUnit(.heartRateVariabilitySDNN)
        let hrv = await LocalHealthStore.shared.dailyAverage(
            identifier: .heartRateVariabilitySDNN, unit: hrvUnit, start: d60Date, end: end)
        let hCur = avgWindow(hrv, lo: d30, minN: 7)
        let hPrev = avgWindow(hrv, lo: d60, hi: d30, minN: 7)
        if let hCur, let hPrev, hPrev > 0 {
            let pct = (hCur - hPrev) / hPrev * 100
            if pct >= 10 {
                add(&good, "HRV が上昇しています",
                    "前月比 \(signedPercent(pct))(平均 \(String(format: "%.0f", hCur)) ms)。"
                    + "回復力が高まっています。")
            } else if pct <= -15 {
                add(&improve, "HRV が低下しています",
                    "前月比 \(signedPercent(pct))(平均 \(String(format: "%.0f", hCur)) ms)。"
                    + "ストレスや回復不足に心当たりがないか振り返ってみましょう。")
            }
        }

        let hrvPct = pctChange(cur: hCur, prev: hPrev)
        let rhrDelta = rCur.flatMap { cur in rPrev.map { cur - $0 } }
        if let sCur = sleepCur, let hrvPct, let rhrDelta {
            if sCur >= 7.0 && hrvPct >= -5 && rhrDelta <= 1 {
                add(&good, "回復コンディションが安定",
                    "睡眠は平均 \(String(format: "%.1f", sCur)) 時間、HRV と安静時心拍も大きく崩れていません。")
            } else if sCur < 6.5 && hrvPct <= -10 && rhrDelta >= 2 {
                add(&improve, "回復不足のサインが重なっています",
                    "睡眠短め、HRV 前月比 \(signedPercent(hrvPct))、安静時心拍 \(String(format: "%+.1f", rhrDelta)) bpm。"
                    + "数日単位で休息を優先して変化を見ましょう。")
            }
        }

        let (vo2Unit, _) = quantityUnit(.vo2Max)
        let vo2 = await LocalHealthStore.shared.dailyAverage(
            identifier: .vo2Max, unit: vo2Unit, start: d60Date, end: end)
        let vo2Cur = avgWindow(vo2, lo: d30, minN: 3)
        let vo2Prev = avgWindow(vo2, lo: d60, hi: d30, minN: 3)
        if let vo2Pct = pctChange(cur: vo2Cur, prev: vo2Prev), let vo2Cur {
            if vo2Pct >= 3 {
                add(&good, "心肺フィットネスが上向き",
                    "VO2 max が前月比 \(signedPercent(vo2Pct))、平均 \(String(format: "%.1f", vo2Cur)) mL/kg/min です。")
            } else if vo2Pct <= -3 {
                add(&improve, "心肺フィットネスが下がり気味",
                    "VO2 max が前月比 \(signedPercent(vo2Pct))。有酸素運動の頻度や強度を少し戻せるか確認しましょう。")
            }
        }

        if let deep = deepSleepRatio(samples: sleepSamplesWide, sinceExclusive: d30) {
            if deep >= 0.13 {
                add(&good, "深い睡眠が取れています", "実睡眠の \(String(format: "%.0f", deep * 100))% が深い睡眠です。")
            } else if deep < 0.08 {
                add(&improve, "深い睡眠が少なめ",
                    "実睡眠の \(String(format: "%.0f", deep * 100))% と少なめです。就寝前のスマホ・"
                    + "アルコール・カフェインを控えると改善しやすいです。")
            }
        }

        let (bdUnit, _) = quantityUnit(.appleSleepingBreathingDisturbances)
        let breathingDisturbances = await LocalHealthStore.shared.dailyAverage(
            identifier: .appleSleepingBreathingDisturbances, unit: bdUnit, start: d60Date, end: end)
        let elevatedBreathingDays = valuesWindow(breathingDisturbances, lo: d30).filter { value in
            let quantity = HKQuantity(unit: bdUnit, doubleValue: value)
            return HKAppleSleepingBreathingDisturbancesClassification(
                classifying: quantity) == .elevated
        }.count
        let apneaEvents = await LocalHealthStore.shared.categorySamples(
            identifier: .sleepApneaEvent, start: d30Date, end: end)
        if elevatedBreathingDays >= 3 || !apneaEvents.isEmpty {
            add(&improve, "睡眠中の呼吸の乱れが目立ちます",
                "直近30日で呼吸の乱れが高めの日が \(elevatedBreathingDays) 日"
                + (!apneaEvents.isEmpty ? "、睡眠時無呼吸関連イベントが \(apneaEvents.count) 件" : "")
                + "あります。いびき、息が止まる指摘、日中の強い眠気があれば医療機関で相談しましょう。")
        } else if valuesWindow(breathingDisturbances, lo: d30).count >= 10 {
            add(&good, "睡眠中の呼吸は大きく乱れていません",
                "記録のある範囲では、直近30日の呼吸の乱れが高めの日は多くありません。")
        }

        let (weightUnit, _) = quantityUnit(.bodyMass)
        let weight = await LocalHealthStore.shared.dailyAverage(
            identifier: .bodyMass, unit: weightUnit, start: d60Date, end: end)
        let wCur = avgWindow(weight, lo: d30, minN: 4)
        let wPrev = avgWindow(weight, lo: d60, hi: d30, minN: 4)
        if let wCur, let wPrev {
            let dw = wCur - wPrev
            if abs(dw) <= 0.5 {
                add(&good, "体重が安定", "前月比 \(String(format: "%+.1f", dw)) kg(平均 \(String(format: "%.1f", wCur)) kg)。")
            } else if abs(dw) >= 1.5 {
                add(&improve, "体重が変化しています",
                    "前月比 \(String(format: "%+.1f", dw)) kg(平均 \(String(format: "%.1f", wCur)) kg)。"
                    + "意図した変化か確認しましょう。")
            }
        }

        let (dietUnit, _) = quantityUnit(.dietaryEnergyConsumed)
        let (activeUnit, _) = quantityUnit(.activeEnergyBurned)
        let (basalUnit, _) = quantityUnit(.basalEnergyBurned)
        let intake = await LocalHealthStore.shared.dailySum(
            identifier: .dietaryEnergyConsumed, unit: dietUnit, start: d60Date, end: end)
        let active = await LocalHealthStore.shared.dominantDailySum(
            identifier: .activeEnergyBurned, unit: activeUnit, start: d60Date, end: end)
        let basal = await LocalHealthStore.shared.dominantDailySum(
            identifier: .basalEnergyBurned, unit: basalUnit, start: d60Date, end: end)
        let iCur = avgWindow(intake, lo: d30, minN: 14)
        let aCur = avgWindow(active, lo: d30, minN: 7)
        let bCur = avgWindow(basal, lo: d30, minN: 7)
        if let iCur, let aCur, let bCur {
            let balance = iCur - (aCur + bCur)
            if abs(balance) <= 200 {
                add(&good, "エネルギー収支が釣り合っています",
                    "摂取と消費の差は 1日平均 \(String(format: "%+.0f", balance)) kcal。")
            } else if balance > 300 {
                add(&improve, "摂取カロリーが消費を上回っています",
                    "1日平均 \(String(format: "%+.0f", balance)) kcal のプラス。"
                    + "この状態が続くと月 1kg 前後の体重増につながります。")
            }
        }

        let daysWithSteps = steps.keys.filter { $0 > d30 }.count
        let stepVals = valuesWindow(steps, lo: d30)
        let activeStepDays = stepVals.filter { $0 >= 5000 }.count
        if stepVals.count >= 14, let stepMean = avgWindow(steps, lo: d30, minN: 14),
           let stepSD = standardDeviation(stepVals), stepMean > 0 {
            let cv = stepSD / stepMean
            if activeStepDays >= 24 && cv <= 0.4 {
                add(&good, "活動量が安定しています",
                    "5,000歩以上の日が \(activeStepDays) 日。平均だけでなく日々の動きも安定しています。")
            } else if activeStepDays < 18 || cv >= 0.75 {
                add(&improve, "活動量に偏りがあります",
                    "5,000歩以上の日は \(activeStepDays) 日。まとめて動く日と少ない日の差が大きめです。")
            }
        }

        if daysWithSteps >= 28 {
            add(&good, "記録が毎日続いています",
                "直近30日のうち \(daysWithSteps) 日でデータが取れています。継続は最高の分析材料です。")
        }

        let (walkSpeedUnit, _) = quantityUnit(.walkingSpeed)
        let walkSpeed = await LocalHealthStore.shared.dailyAverage(
            identifier: .walkingSpeed, unit: walkSpeedUnit, start: d60Date, end: end)
        let (stepLenUnit, _) = quantityUnit(.walkingStepLength)
        let stepLen = await LocalHealthStore.shared.dailyAverage(
            identifier: .walkingStepLength, unit: stepLenUnit, start: d60Date, end: end)
        let (asymUnit, _) = quantityUnit(.walkingAsymmetryPercentage)
        let asym = await LocalHealthStore.shared.dailyAverage(
            identifier: .walkingAsymmetryPercentage, unit: asymUnit, start: d60Date, end: end)
        let (doubleUnit, _) = quantityUnit(.walkingDoubleSupportPercentage)
        let doubleSupport = await LocalHealthStore.shared.dailyAverage(
            identifier: .walkingDoubleSupportPercentage, unit: doubleUnit, start: d60Date, end: end)

        let speedPct = pctChange(cur: avgWindow(walkSpeed, lo: d30, minN: 5),
                                 prev: avgWindow(walkSpeed, lo: d60, hi: d30, minN: 5))
        let stepLenPct = pctChange(cur: avgWindow(stepLen, lo: d30, minN: 5),
                                   prev: avgWindow(stepLen, lo: d60, hi: d30, minN: 5))
        let asymDelta = avgWindow(asym, lo: d30, minN: 5).flatMap { cur in
            avgWindow(asym, lo: d60, hi: d30, minN: 5).map { cur - $0 }
        }
        let doubleDelta = avgWindow(doubleSupport, lo: d30, minN: 5).flatMap { cur in
            avgWindow(doubleSupport, lo: d60, hi: d30, minN: 5).map { cur - $0 }
        }
        if speedPct ?? 0 >= 4 || stepLenPct ?? 0 >= 4
            || asymDelta ?? 0 <= -0.002 || doubleDelta ?? 0 <= -0.01 {
            add(&good, "歩き方の指標が改善傾向",
                "歩行速度・歩幅・左右差・両脚支持時間のいずれかが前月より良い方向です。")
        } else if speedPct ?? 0 <= -5 || stepLenPct ?? 0 <= -5
                    || asymDelta ?? 0 >= 0.005 || doubleDelta ?? 0 >= 0.015 {
            add(&improve, "歩き方の質が下がり気味",
                "歩行速度や歩幅の低下、左右差・両脚支持時間の増加が見られます。疲労や靴、痛みの有無を確認しましょう。")
        }

        return DashboardData.Assessments(good: good, improve: improve)
    }

    // ------------------------------------------------------------------ latest

    static func latestDate() async -> Date? {
        let types = HealthKitReader.readTypes().compactMap { $0 as? HKSampleType }
        return await LocalHealthStore.shared.latestDay(sampleTypes: Array(types))
    }

    // ------------------------------------------------------------------ セクション構成

    static func buildSections(latest: Date) async -> [DashboardData.Section] {
        let store = LocalHealthStore.shared
        let mSamples = await store.categorySamples(identifier: .menstrualFlow,
                                                   start: Date(timeIntervalSince1970: 0),
                                                   end: endExclusive(latest))
        let cycles = menstrualCycles(samples: mSamples)
        let lens = cycles.compactMap(\.cycleLen)

        let workouts = await store.workouts(start: Date(timeIntervalSince1970: 0),
                                            end: endExclusive(latest))
        return [
            .init(key: "cardio", title: "心肺コンディション",
                  charts: ["rhr", "hrv", "vo2"]),
            .init(key: "activity", title: "活動量",
                  charts: ["steps", "exercise", "active_energy"]),
            .init(key: "sleep", title: "睡眠",
                  charts: ["sleep_total", "sleep_stages", "breathing_disturbances"]),
            .init(key: "body", title: "体組成",
                  charts: ["body_mass", "body_fat"]),
            .init(key: "walking", title: "歩き方の質",
                  charts: ["walking_speed", "walking_steplen", "walking_balance"]),
            .init(key: "diet", title: "食事とエネルギー収支",
                  charts: ["energy_balance", "macros"]),
            .init(key: "cycle", title: "月経周期",
                  charts: ["cycle_len"],
                  cycles: Array(cycles.suffix(6)),
                  avgCycle: lens.isEmpty ? nil
                      : roundVal(Double(lens.reduce(0, +)) / Double(lens.count), 1)),
            .init(key: "workouts", title: "運動記録",
                  charts: ["workouts"],
                  recent: recentWorkouts(workouts: workouts, n: 10)),
        ]
    }

    static func buildDashboard(range: String) async -> DashboardData {
        guard let latest = await latestDate() else {
            return DashboardData(latest: nil, insights: [],
                                 assess: .init(good: [], improve: []), numbers: [], sections: [])
        }
        async let insightsResult = insights(latest: latest)
        async let assessResult = assessments(latest: latest)
        async let numbersResult = nowNumbers(latest: latest)
        async let sectionsResult = buildSections(latest: latest)
        return DashboardData(latest: DayFormat.string(latest), insights: await insightsResult,
                             assess: await assessResult, numbers: await numbersResult,
                             sections: await sectionsResult)
    }

    // ------------------------------------------------------------------ チャート組み立て

    static func chartTitle(name: String) -> String {
        switch name {
        case "rhr": return "安静時心拍"
        case "hrv": return "HRV / SDNN"
        case "vo2": return "VO2 max"
        case "steps": return "歩数"
        case "exercise": return "運動時間"
        case "active_energy": return "消費エネルギー"
        case "sleep_total": return "実睡眠時間"
        case "sleep_stages": return "睡眠ステージ内訳"
        case "breathing_disturbances": return "睡眠中の呼吸の乱れ"
        case "body_mass": return "体重"
        case "body_fat": return "体脂肪率"
        case "walking_speed": return "歩行速度"
        case "walking_steplen": return "歩幅"
        case "walking_balance": return "歩き方のバランス"
        case "energy_balance": return "エネルギー収支"
        case "macros": return "三大栄養素"
        case "workouts": return "ワークアウト回数"
        case "cycle_len": return "月経周期"
        default: return "グラフ"
        }
    }

    private static func single(name: String, kind: ChartSpec.Kind, labels: [String],
                               values: [Double], title: String, ylabel: String) throws -> ChartSpec {
        guard !labels.isEmpty else { throw NoLocalData() }
        return ChartSpec(name: name, title: title, ylabel: ylabel, kind: kind, labels: labels,
                         series: [ChartSpec.Series(name: nil, color: Palette.series[0], values: values)])
    }

    private static func multi(name: String, kind: ChartSpec.Kind, labels: [String],
                              series: [String: [Double]], title: String, ylabel: String,
                              colors: [String: String], order: [String]) -> ChartSpec {
        let seriesArr = order.compactMap { k -> ChartSpec.Series? in
            guard let vals = series[k] else { return nil }
            return ChartSpec.Series(name: k, color: colors[k] ?? Palette.series[0], values: vals)
        }
        return ChartSpec(name: name, title: title, ylabel: ylabel, kind: kind,
                         labels: labels, series: seriesArr)
    }

    private static func seriesArrayOptional(_ series: [String: [Double?]],
                                            order: [String]) -> [ChartSpec.Series] {
        var out: [ChartSpec.Series] = []
        var i = 0
        for key in order {
            guard let vals = series[key] else { continue }
            out.append(ChartSpec.Series(name: key, color: Palette.series[i % Palette.series.count],
                                        values: vals))
            i += 1
        }
        return out
    }

    static func buildChart(name: String, range: String) async throws -> ChartSpec {
        guard let latest = await latestDate() else { throw NoLocalData() }
        let end = endExclusive(latest)
        let defaultStart = cutoffDate(range: range, latest: latest) ?? Date(timeIntervalSince1970: 0)
        let bl = bucketLabel(range)

        switch name {
        case "rhr":
            let (lab, v) = await dailySeries(identifier: .restingHeartRate, range: range,
                                             latest: latest, dedupe: false, useSum: false)
            return try single(name: name, kind: .line, labels: lab, values: v,
                              title: "安静時心拍(\(bl))", ylabel: "bpm")
        case "hrv":
            let (lab, v) = await dailySeries(identifier: .heartRateVariabilitySDNN, range: range,
                                             latest: latest, dedupe: false, useSum: false)
            return try single(name: name, kind: .line, labels: lab, values: v,
                              title: "HRV / SDNN(\(bl))", ylabel: "ms")
        case "vo2":
            let (lab, v) = await dailySeries(identifier: .vo2Max, range: range,
                                             latest: latest, dedupe: false, useSum: false)
            return try single(name: name, kind: .line, labels: lab, values: v,
                              title: "VO2 max(\(bl))", ylabel: "mL/kg/min")
        case "steps":
            let (lab, v) = await dailySeries(identifier: .stepCount, range: range,
                                             latest: latest, dedupe: true, useSum: true)
            return try single(name: name, kind: .bar, labels: lab, values: v,
                              title: "歩数(\(bl))", ylabel: "歩")
        case "exercise":
            let (lab, v) = await dailySeries(identifier: .appleExerciseTime, range: range,
                                             latest: latest, dedupe: true, useSum: true)
            return try single(name: name, kind: .bar, labels: lab, values: v,
                              title: "運動時間(\(bl))", ylabel: "分")
        case "active_energy":
            let (lab, v) = await dailySeries(identifier: .activeEnergyBurned, range: range,
                                             latest: latest, dedupe: true, useSum: true)
            return try single(name: name, kind: .bar, labels: lab, values: v,
                              title: "消費エネルギー(アクティブ、\(bl))", ylabel: "kcal")
        case "sleep_total":
            let (lab, v) = await sleepTotalSeries(range: range, latest: latest)
            return try single(name: name, kind: .line, labels: lab, values: v,
                              title: "実睡眠時間(重複除外、\(bl))", ylabel: "時間")
        case "sleep_stages":
            let (lab, series) = await sleepStageSeries(range: range, latest: latest)
            guard !lab.isEmpty else { throw NoLocalData() }
            let order = stageOrder.filter { series[$0] != nil }.map { Palette.sleepLabels[$0]! }
            var namedSeries: [String: [Double]] = [:]
            var colors: [String: String] = [:]
            for s in stageOrder {
                guard let v = series[s] else { continue }
                let jp = Palette.sleepLabels[s]!
                namedSeries[jp] = v
                colors[jp] = Palette.sleepColors[s]!
            }
            return multi(name: name, kind: .stackedBar, labels: lab, series: namedSeries,
                        title: "睡眠ステージ内訳(\(bl))", ylabel: "時間", colors: colors, order: order)
        case "breathing_disturbances":
            let (lab, v) = await dailySeries(identifier: .appleSleepingBreathingDisturbances,
                                             range: range, latest: latest,
                                             dedupe: false, useSum: false)
            return try single(name: name, kind: .line, labels: lab, values: v,
                              title: "睡眠中の呼吸の乱れ(\(bl))", ylabel: "回数")
        case "body_mass":
            let (lab, v) = await dailySeries(identifier: .bodyMass, range: range,
                                             latest: latest, dedupe: false, useSum: false)
            return try single(name: name, kind: .line, labels: lab, values: v,
                              title: "体重(\(bl))", ylabel: "kg")
        case "body_fat":
            let (lab, raw) = await dailySeries(identifier: .bodyFatPercentage, range: range,
                                               latest: latest, dedupe: false, useSum: false)
            let v = raw.map { $0 <= 1 ? $0 * 100 : $0 }
            return try single(name: name, kind: .line, labels: lab, values: v,
                              title: "体脂肪率(\(bl))", ylabel: "%")
        case "walking_speed":
            let (lab, v) = await dailySeries(identifier: .walkingSpeed, range: range,
                                             latest: latest, dedupe: false, useSum: false)
            return try single(name: name, kind: .line, labels: lab, values: v,
                              title: "歩行速度(\(bl))", ylabel: "km/hr")
        case "walking_steplen":
            let (lab, v) = await dailySeries(identifier: .walkingStepLength, range: range,
                                             latest: latest, dedupe: false, useSum: false)
            return try single(name: name, kind: .line, labels: lab, values: v,
                              title: "歩幅(\(bl))", ylabel: "cm")
        case "walking_balance":
            let (la, va) = await dailySeries(identifier: .walkingAsymmetryPercentage, range: range,
                                             latest: latest, dedupe: false, useSum: false)
            let (ld, vd) = await dailySeries(identifier: .walkingDoubleSupportPercentage, range: range,
                                             latest: latest, dedupe: false, useSum: false)
            let labels = Array(Set(la).union(ld)).sorted()
            guard !labels.isEmpty else { throw NoLocalData() }
            let ma = Dictionary(uniqueKeysWithValues: zip(la, va))
            let md = Dictionary(uniqueKeysWithValues: zip(ld, vd))
            func pct(_ m: [String: Double], _ x: String) -> Double? {
                guard let v = m[x] else { return nil }
                return v <= 1 ? v * 100 : v
            }
            var series: [String: [Double?]] = [:]
            if !la.isEmpty { series["左右非対称性"] = labels.map { pct(ma, $0) } }
            if !ld.isEmpty { series["両脚支持時間"] = labels.map { pct(md, $0) } }
            return ChartSpec(name: name, title: "歩き方のバランス(\(bl))", ylabel: "%",
                             kind: .multiLine, labels: labels,
                             series: seriesArrayOptional(series, order: ["左右非対称性", "両脚支持時間"]))
        case "energy_balance":
            let (labIn, intake) = await dailySeries(identifier: .dietaryEnergyConsumed, range: range,
                                                     latest: latest, dedupe: false, useSum: true)
            let (la, active) = await dailySeries(identifier: .activeEnergyBurned, range: range,
                                                 latest: latest, dedupe: true, useSum: true)
            let (lb, basal) = await dailySeries(identifier: .basalEnergyBurned, range: range,
                                                latest: latest, dedupe: true, useSum: true)
            var burnMap: [String: Double] = [:]
            for (l, v) in zip(la, active) { burnMap[l, default: 0] += v }
            for (l, v) in zip(lb, basal) { burnMap[l, default: 0] += v }
            let labels = Array(Set(labIn).union(burnMap.keys)).sorted()
            guard !labels.isEmpty else { throw NoLocalData() }
            let inMap = Dictionary(uniqueKeysWithValues: zip(labIn, intake))
            var series: [String: [Double?]] = [:]
            series["摂取"] = labels.map { inMap[$0] }
            series["消費(基礎+活動)"] = labels.map { burnMap[$0] }
            return ChartSpec(name: name, title: "エネルギー収支(\(bl))", ylabel: "kcal",
                             kind: .multiLine, labels: labels,
                             series: seriesArrayOptional(series, order: ["摂取", "消費(基礎+活動)"]))
        case "macros":
            let (lp, vp) = await dailySeries(identifier: .dietaryProtein, range: range,
                                             latest: latest, dedupe: false, useSum: true)
            let (lf, vf) = await dailySeries(identifier: .dietaryFatTotal, range: range,
                                             latest: latest, dedupe: false, useSum: true)
            let (lc, vc) = await dailySeries(identifier: .dietaryCarbohydrates, range: range,
                                             latest: latest, dedupe: false, useSum: true)
            let labels = Array(Set(lp).union(lf).union(lc)).sorted()
            guard !labels.isEmpty else { throw NoLocalData() }
            let mp = Dictionary(uniqueKeysWithValues: zip(lp, vp))
            let mf = Dictionary(uniqueKeysWithValues: zip(lf, vf))
            let mc = Dictionary(uniqueKeysWithValues: zip(lc, vc))
            var series: [String: [Double]] = [
                "たんぱく質": labels.map { mp[$0] ?? 0 },
                "脂質": labels.map { mf[$0] ?? 0 },
                "炭水化物": labels.map { mc[$0] ?? 0 },
            ]
            series = series.filter { _, v in v.contains { $0 != 0 } }
            guard !series.isEmpty else { throw NoLocalData() }
            return multi(name: name, kind: .stackedBar, labels: labels, series: series,
                        title: "三大栄養素(\(bl))", ylabel: "g",
                        colors: ["たんぱく質": Palette.series[0], "脂質": Palette.series[1],
                                "炭水化物": Palette.series[2]],
                        order: ["たんぱく質", "脂質", "炭水化物"])
        case "workouts":
            let start: Date
            if let cutoff = cutoffDate(range: range, latest: latest) {
                start = cutoff
            } else {
                start = await LocalHealthStore.shared.earliestStartDate(
                    type: HKObjectType.workoutType()) ?? defaultStart
            }
            let workouts = await LocalHealthStore.shared.workouts(start: start, end: end)
            let (lab, order, series) = workoutsBucketed(workouts: workouts, range: range)
            guard !lab.isEmpty else { throw NoLocalData() }
            let namedOrder = order.map { WorkoutLabels.label(for: $0) }
            var namedSeries: [String: [Double]] = [:]
            var colors: [String: String] = [:]
            var i = 0
            for key in order {
                let jp = WorkoutLabels.label(for: key)
                namedSeries[jp] = series[key]!
                colors[jp] = (key == "その他") ? Palette.otherGray : Palette.series[i % Palette.series.count]
                if key != "その他" { i += 1 }
            }
            return multi(name: name, kind: .stackedBar, labels: lab, series: namedSeries,
                        title: "ワークアウト回数(\(workoutBucketLabel(range)))", ylabel: "回",
                        colors: colors, order: namedOrder)
        case "cycle_len":
            let start: Date
            if let cutoff = cutoffDate(range: range, latest: latest) {
                start = cutoff
            } else {
                start = await LocalHealthStore.shared.earliestStartDate(
                    type: HKCategoryType(.menstrualFlow)) ?? defaultStart
            }
            let samples = await LocalHealthStore.shared.categorySamples(
                identifier: .menstrualFlow, start: start, end: end)
            let cycles = menstrualCycles(samples: samples).filter { $0.cycleLen != nil }
            guard !cycles.isEmpty else { throw NoLocalData() }
            return try single(name: name, kind: .bar, labels: cycles.map(\.start),
                              values: cycles.map { Double($0.cycleLen!) },
                              title: "月経周期の長さ(開始日ごと)", ylabel: "日")
        default:
            throw NoLocalData()
        }
    }
}
