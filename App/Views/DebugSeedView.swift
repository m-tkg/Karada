#if DEBUG
import HealthKit
import SwiftUI

/// シミュレータ検証用: HealthKit にデモデータを書き込む(DEBUG ビルド限定)。
struct DebugSeedView: View {
    @State private var message = ""
    @State private var seeding = false

    var body: some View {
        Section("開発用") {
            Button {
                Task { await seed() }
            } label: {
                if seeding { ProgressView() } else { Text("HealthKit にデモデータを投入") }
            }
            if !message.isEmpty {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func seed() async {
        seeding = true
        defer { seeding = false }
        let store = HKHealthStore()
        let types: [HKSampleType] = [
            HKQuantityType(.stepCount), HKQuantityType(.restingHeartRate),
            HKQuantityType(.heartRateVariabilitySDNN), HKQuantityType(.bodyMass),
            HKQuantityType(.activeEnergyBurned), HKQuantityType(.appleExerciseTime),
            HKCategoryType(.sleepAnalysis), HKObjectType.workoutType(),
        ]
        do {
            try await store.requestAuthorization(toShare: Set(types), read: [])
            var samples: [HKSample] = []
            let cal = Calendar.current
            for dayOffset in 1...60 {
                guard let day = cal.date(byAdding: .day, value: -dayOffset, to: .now)
                else { continue }
                let morning = cal.date(bySettingHour: 8, minute: 0, second: 0, of: day)!

                func q(_ id: HKQuantityTypeIdentifier, _ unit: HKUnit, _ value: Double,
                       hour: Int, durationMin: Double = 1) {
                    let start = cal.date(bySettingHour: hour, minute: 0, second: 0, of: day)!
                    samples.append(HKQuantitySample(
                        type: HKQuantityType(id),
                        quantity: HKQuantity(unit: unit, doubleValue: value),
                        start: start, end: start.addingTimeInterval(durationMin * 60)))
                }

                q(.stepCount, .count(), Double.random(in: 6000...13000), hour: 12,
                  durationMin: 300)
                q(.restingHeartRate, HKUnit.count().unitDivided(by: .minute()),
                  Double.random(in: 52...62), hour: 6)
                q(.heartRateVariabilitySDNN, .secondUnit(with: .milli),
                  Double.random(in: 30...65), hour: 6)
                q(.bodyMass, .gramUnit(with: .kilo), 63 + Double.random(in: -1...1),
                  hour: 7)
                q(.activeEnergyBurned, .kilocalorie(), Double.random(in: 250...600),
                  hour: 20, durationMin: 60)
                q(.appleExerciseTime, .minute(), Double.random(in: 15...60),
                  hour: 19, durationMin: 60)

                // 睡眠(23時〜翌6時台、ステージ付き)
                let bed = cal.date(bySettingHour: 23, minute: Int.random(in: 0...40),
                                   second: 0, of: day)!
                var t = bed
                for (stage, frac) in [(HKCategoryValueSleepAnalysis.asleepCore, 0.55),
                                      (.asleepDeep, 0.2), (.asleepREM, 0.22),
                                      (.awake, 0.03)] {
                    let dur = 7.0 * 3600 * frac
                    samples.append(HKCategorySample(
                        type: HKCategoryType(.sleepAnalysis), value: stage.rawValue,
                        start: t, end: t.addingTimeInterval(dur)))
                    t = t.addingTimeInterval(dur)
                }

                if dayOffset % 3 == 0 {
                    let start = cal.date(bySettingHour: 18, minute: 0, second: 0,
                                         of: day)!
                    // HKWorkout の直接生成 API は非推奨だがシード用途では十分
                    samples.append(HKWorkout(
                        activityType: .running, start: start,
                        end: start.addingTimeInterval(1800),
                        duration: 1800,
                        totalEnergyBurned: HKQuantity(unit: .kilocalorie(),
                                                      doubleValue: 320),
                        totalDistance: HKQuantity(unit: .meterUnit(with: .kilo),
                                                  doubleValue: 5.0),
                        metadata: nil))
                }
                _ = morning
            }
            try await store.save(samples)
            message = "\(samples.count) 件を投入しました。同期タブから同期してください。"
        } catch {
            message = "失敗: \(error.localizedDescription)"
        }
    }
}
#endif
