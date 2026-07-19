import Foundation
import HealthKit

/// HealthKit から読み取る型の一覧と、認可・値の短縮名変換を扱う。
///
/// 型名・カテゴリ値の短縮ルールは Apple の「すべてのデータを書き出す」
/// (export.xml)の命名と揃えている(LocalAnalytics のロジックとの整合のため)。
final class HealthKitReader: Sendable {
    let store = HKHealthStore()

    /// 分析対象の数量型: (HK identifier, 集計に使う単位, 単位文字列)
    static let quantityTypes: [(HKQuantityTypeIdentifier, HKUnit, String)] = [
        (.stepCount, .count(), "count"),
        (.distanceWalkingRunning, .meterUnit(with: .kilo), "km"),
        (.flightsClimbed, .count(), "count"),
        (.activeEnergyBurned, .kilocalorie(), "kcal"),
        (.basalEnergyBurned, .kilocalorie(), "kcal"),
        (.appleExerciseTime, .minute(), "min"),
        (.appleStandTime, .minute(), "min"),
        (.heartRate, HKUnit.count().unitDivided(by: .minute()), "count/min"),
        (.restingHeartRate, HKUnit.count().unitDivided(by: .minute()), "count/min"),
        (.walkingHeartRateAverage, HKUnit.count().unitDivided(by: .minute()), "count/min"),
        (.heartRateVariabilitySDNN, .secondUnit(with: .milli), "ms"),
        (.heartRateRecoveryOneMinute, HKUnit.count().unitDivided(by: .minute()), "count/min"),
        (.oxygenSaturation, .percent(), "%"),
        (.respiratoryRate, HKUnit.count().unitDivided(by: .minute()), "count/min"),
        (.appleSleepingBreathingDisturbances, .count(), "count"),
        (.vo2Max, HKUnit(from: "ml/kg*min"), "mL/min·kg"),
        (.bodyMass, .gramUnit(with: .kilo), "kg"),
        (.bodyMassIndex, .count(), "count"),
        (.bodyFatPercentage, .percent(), "%"),
        (.height, .meterUnit(with: .centi), "cm"),
        (.appleSleepingWristTemperature, .degreeCelsius(), "degC"),
        (.walkingSpeed, HKUnit(from: "km/hr"), "km/hr"),
        (.walkingStepLength, .meterUnit(with: .centi), "cm"),
        (.walkingAsymmetryPercentage, .percent(), "%"),
        (.walkingDoubleSupportPercentage, .percent(), "%"),
        (.appleWalkingSteadiness, .percent(), "%"),
        (.dietaryEnergyConsumed, .kilocalorie(), "kcal"),
        (.dietaryProtein, .gram(), "g"),
        (.dietaryFatTotal, .gram(), "g"),
        (.dietaryCarbohydrates, .gram(), "g"),
        (.dietaryWater, .literUnit(with: .milli), "mL"),
    ]

    static let categoryTypes: [HKCategoryTypeIdentifier] = [
        .sleepAnalysis,
        .sleepApneaEvent,
        .menstrualFlow,
        .appleStandHour,
        .mindfulSession,
    ]

    /// 認可を求める型の一覧(読み取りのみ、書き込みはしない)。
    static func readTypes() -> Set<HKObjectType> {
        var types = Set<HKObjectType>()
        for (id, _, _) in quantityTypes {
            if let t = HKObjectType.quantityType(forIdentifier: id) { types.insert(t) }
        }
        for id in categoryTypes {
            if let t = HKObjectType.categoryType(forIdentifier: id) { types.insert(t) }
        }
        types.insert(HKObjectType.workoutType())
        // 年齢・性別で基準が変わる指標(体脂肪率・VO2 max)の判定に使う
        if let t = HKObjectType.characteristicType(forIdentifier: .dateOfBirth) { types.insert(t) }
        if let t = HKObjectType.characteristicType(forIdentifier: .biologicalSex) { types.insert(t) }
        return types
    }

    func requestAuthorization() async throws {
        try await store.requestAuthorization(toShare: [], read: Self.readTypes())
    }

    /// 年齢・性別で基準が変わる指標の判定に使うプロフィール。
    /// 未設定・未認可なら nil のままにして、呼び出し側で判定を諦める。
    func profile() -> HealthProfile {
        var age: Int?
        if let components = try? store.dateOfBirthComponents(),
           let birth = Calendar.current.date(from: components) {
            age = Calendar.current.dateComponents([.year], from: birth, to: Date()).year
        }
        var isFemale: Bool?
        if let sex = try? store.biologicalSex().biologicalSex {
            switch sex {
            case .female: isFemale = true
            case .male: isFemale = false
            default: isFemale = nil  // other / notSet は判定しない
            }
        }
        return HealthProfile(age: age, isFemale: isFemale)
    }

    // MARK: - カテゴリ値の短縮名

    static func sleepValueName(_ raw: Int) -> String? {
        let names: [Int: String] = [
            0: "InBed", 1: "AsleepUnspecified", 2: "Awake",
            3: "AsleepCore", 4: "AsleepDeep", 5: "AsleepREM",
        ]
        guard let n = names[raw] else { return nil }
        return "HKCategoryValueSleepAnalysis\(n)"
    }

    static func menstrualValueName(_ raw: Int) -> String? {
        let names: [Int: String] = [
            1: "Unspecified", 2: "Light", 3: "Medium", 4: "Heavy", 5: "None",
        ]
        guard let n = names[raw] else { return nil }
        return "HKCategoryValueMenstrualFlow\(n)"
    }

    // MARK: - アンカー付き差分クエリ(将来の増分取得用に維持)

    struct Batch: Sendable {
        var samples: [HKSample]
        var newAnchor: HKQueryAnchor?
    }

    /// アンカー以降のサンプルを最大 limit 件取得する。
    func fetchBatch(type: HKSampleType, anchor: HKQueryAnchor?,
                    since: Date?, limit: Int) async throws -> Batch {
        let predicate = since.map {
            HKQuery.predicateForSamples(withStart: $0, end: nil, options: [])
        }
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKAnchoredObjectQuery(
                type: type, predicate: predicate, anchor: anchor, limit: limit
            ) { _, samples, _, newAnchor, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: Batch(samples: samples ?? [],
                                                         newAnchor: newAnchor))
                }
            }
            store.execute(query)
        }
    }
}

/// HKWorkoutActivityType の短縮名(WorkoutLabels の対訳キーと対応)。
enum WorkoutTypeNames {
    static let names: [HKWorkoutActivityType: String] = [
        .running: "Running", .walking: "Walking", .cycling: "Cycling",
        .hiking: "Hiking", .yoga: "Yoga", .swimming: "Swimming",
        .functionalStrengthTraining: "FunctionalStrengthTraining",
        .traditionalStrengthTraining: "TraditionalStrengthTraining",
        .coreTraining: "CoreTraining",
        .highIntensityIntervalTraining: "HighIntensityIntervalTraining",
        .elliptical: "Elliptical", .rowing: "Rowing",
        .stairClimbing: "StairClimbing", .stairs: "Stairs",
        .pilates: "Pilates", .socialDance: "SocialDance",
        .cardioDance: "CardioDance",
        .cooldown: "Cooldown", .flexibility: "FlexibilityTraining",
        .crossTraining: "CrossTraining", .mixedCardio: "MixedCardio",
        .soccer: "Soccer", .basketball: "Basketball", .baseball: "Baseball",
        .tennis: "Tennis", .tableTennis: "TableTennis", .badminton: "Badminton",
        .golf: "Golf", .martialArts: "MartialArts", .bowling: "Bowling",
        .climbing: "Climbing", .skatingSports: "SkatingSports",
        .snowSports: "SnowSports", .downhillSkiing: "DownhillSkiing",
        .snowboarding: "Snowboarding", .surfingSports: "SurfingSports",
        .paddleSports: "PaddleSports", .jumpRope: "JumpRope",
        .kickboxing: "Kickboxing", .boxing: "Boxing",
    ]

    static func name(for type: HKWorkoutActivityType) -> String {
        "HKWorkoutActivityType" + (names[type] ?? "Other")
    }
}

/// 基準値の切り替えに使う利用者属性。ヘルスケアに未登録なら nil。
struct HealthProfile: Sendable, Equatable {
    var age: Int?
    var isFemale: Bool?
}
