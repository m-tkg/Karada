import Foundation
import HealthKit

/// HealthKit から端末上で直接データを取得する層。
///
/// アプリはサーバーに依存せず動作する。サーバー側の SQL 集計
/// (v_daily / v_daily_dominant / v_sleep)と同じロジックを
/// HKStatisticsCollectionQuery で再現している。
final class LocalHealthStore: @unchecked Sendable {
    static let shared = LocalHealthStore()
    private let store = HKHealthStore()

    private func querySamples(type: HKSampleType, predicate: NSPredicate?,
                              limit: Int, sort: [NSSortDescriptor]) async -> [HKSample] {
        await withCheckedContinuation { cont in
            let q = HKSampleQuery(sampleType: type, predicate: predicate, limit: limit,
                                  sortDescriptors: sort) { _, samples, _ in
                cont.resume(returning: samples ?? [])
            }
            store.execute(q)
        }
    }

    /// 指定サンプル型群のうち最新のデータ日(端末ローカル)。1件も無ければ nil。
    /// 型ごとの問い合わせは並列実行する。
    func latestDay(sampleTypes: [HKSampleType]) async -> Date? {
        await withTaskGroup(of: Date?.self) { group in
            for type in sampleTypes {
                group.addTask {
                    let sort = [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]
                    let samples = await self.querySamples(type: type, predicate: nil,
                                                           limit: 1, sort: sort)
                    return samples.first?.endDate
                }
            }
            var latest: Date?
            for await d in group where d != nil {
                if latest == nil || d! > latest! { latest = d }
            }
            return latest
        }
    }

    /// 指定型のサンプルが1件でも存在するか(ダッシュボードのセクション表示判定用)。
    func hasAnySample(type: HKSampleType) async -> Bool {
        !(await querySamples(type: type, predicate: nil, limit: 1, sort: [])).isEmpty
    }

    /// 指定型の最新サンプルの値。身長のように「最後に記録された1件」を使う型向け。
    func latestQuantity(identifier: HKQuantityTypeIdentifier, unit: HKUnit) async -> Double? {
        let sort = [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]
        let samples = await querySamples(type: HKQuantityType(identifier), predicate: nil,
                                         limit: 1, sort: sort)
        return (samples.first as? HKQuantitySample)?.quantity.doubleValue(for: unit)
    }

    /// 指定型の最古サンプル開始日。全期間チャートで無駄に 1970 年から走査しないために使う。
    func earliestStartDate(type: HKSampleType) async -> Date? {
        let sort = [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
        let samples = await querySamples(type: type, predicate: nil, limit: 1, sort: sort)
        return samples.first?.startDate
    }

    /// 累積型(歩数等)の日次合計。ソースが複数あれば「日ごとに合計最大の
    /// 単一ソース」だけを採用し二重計上を避ける(サーバー v_daily_dominant と同じ)。
    func dominantDailySum(identifier: HKQuantityTypeIdentifier, unit: HKUnit,
                          start: Date, end: Date) async -> [String: Double] {
        let type = HKQuantityType(identifier)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end,
                                                     options: [.strictStartDate])
        let anchor = Calendar.current.startOfDay(for: start)

        return await withCheckedContinuation { cont in
            let query = HKStatisticsCollectionQuery(
                quantityType: type, quantitySamplePredicate: predicate,
                options: [.cumulativeSum, .separateBySource],
                anchorDate: anchor, intervalComponents: DateComponents(day: 1))
            query.initialResultsHandler = { _, results, _ in
                var out: [String: Double] = [:]
                results?.enumerateStatistics(from: start, to: end) { stats, _ in
                    var best: Double?
                    for source in stats.sources ?? [] {
                        guard let q = stats.sumQuantity(for: source) else { continue }
                        let v = q.doubleValue(for: unit)
                        if best == nil || v > best! { best = v }
                    }
                    if let best { out[DayFormat.string(stats.startDate)] = best }
                }
                cont.resume(returning: out)
            }
            store.execute(query)
        }
    }

    /// 累積型の日次合計(全ソース合算、重複排除なし)。食事記録など単一ソース
    /// 想定の型に使う(サーバー v_daily の "total" 列と同じ)。
    func dailySum(identifier: HKQuantityTypeIdentifier, unit: HKUnit,
                 start: Date, end: Date) async -> [String: Double] {
        let type = HKQuantityType(identifier)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end,
                                                     options: [.strictStartDate])
        let anchor = Calendar.current.startOfDay(for: start)

        return await withCheckedContinuation { cont in
            let query = HKStatisticsCollectionQuery(
                quantityType: type, quantitySamplePredicate: predicate,
                options: [.cumulativeSum],
                anchorDate: anchor, intervalComponents: DateComponents(day: 1))
            query.initialResultsHandler = { _, results, _ in
                var out: [String: Double] = [:]
                results?.enumerateStatistics(from: start, to: end) { stats, _ in
                    if let q = stats.sumQuantity() {
                        out[DayFormat.string(stats.startDate)] = q.doubleValue(for: unit)
                    }
                }
                cont.resume(returning: out)
            }
            store.execute(query)
        }
    }

    /// 非累積型(心拍・体重等)の日次平均(全ソース込み、v_daily の avg 列と同じ)。
    func dailyAverage(identifier: HKQuantityTypeIdentifier, unit: HKUnit,
                      start: Date, end: Date) async -> [String: Double] {
        let type = HKQuantityType(identifier)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end,
                                                     options: [.strictStartDate])
        let anchor = Calendar.current.startOfDay(for: start)

        return await withCheckedContinuation { cont in
            let query = HKStatisticsCollectionQuery(
                quantityType: type, quantitySamplePredicate: predicate,
                options: [.discreteAverage],
                anchorDate: anchor, intervalComponents: DateComponents(day: 1))
            query.initialResultsHandler = { _, results, _ in
                var out: [String: Double] = [:]
                results?.enumerateStatistics(from: start, to: end) { stats, _ in
                    if let q = stats.averageQuantity() {
                        out[DayFormat.string(stats.startDate)] = q.doubleValue(for: unit)
                    }
                }
                cont.resume(returning: out)
            }
            store.execute(query)
        }
    }

    func categorySamples(identifier: HKCategoryTypeIdentifier,
                         start: Date, end: Date) async -> [HKCategorySample] {
        let type = HKCategoryType(identifier)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        let sort = [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
        let samples = await querySamples(type: type, predicate: predicate,
                                         limit: HKObjectQueryNoLimit, sort: sort)
        return samples.compactMap { $0 as? HKCategorySample }
    }

    func workouts(start: Date, end: Date) async -> [HKWorkout] {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        let sort = [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)]
        let samples = await querySamples(type: HKObjectType.workoutType(), predicate: predicate,
                                         limit: HKObjectQueryNoLimit, sort: sort)
        return samples.compactMap { $0 as? HKWorkout }
    }
}
