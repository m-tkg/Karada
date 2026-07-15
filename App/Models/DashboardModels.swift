import Foundation

enum DashboardCategory {
    struct Item: Sendable, Identifiable {
        var key: String
        var title: String
        var id: String { key }
    }

    static let all: [Item] = [
        .init(key: "cardio", title: "心肺コンディション"),
        .init(key: "activity", title: "活動量"),
        .init(key: "sleep", title: "睡眠"),
        .init(key: "body", title: "体組成"),
        .init(key: "walking", title: "歩き方の質"),
        .init(key: "diet", title: "食事とエネルギー収支"),
        .init(key: "cycle", title: "月経周期"),
        .init(key: "workouts", title: "運動記録"),
    ]

    static let defaultStorageValue = all.map(\.key).joined(separator: ",")
}

/// ダッシュボードのデータ型。LocalAnalytics が HealthKit から端末上で直接
/// 組み立てる(サーバー・JSON デコードには依存しない)。
struct DashboardData: Sendable {
    var latest: String?
    var insights: [Insight]
    var assess: Assessments
    var numbers: [NumberItem]
    var sections: [Section]

    struct Insight: Sendable, Identifiable {
        var text: String
        var good: Bool?
        var id: String { text }
    }

    struct Assessments: Sendable {
        var good: [Item]
        var improve: [Item]

        struct Item: Sendable, Identifiable {
            var title: String
            var detail: String
            var evidence: Evidence? = nil
            var id: String { title }
        }

        struct Evidence: Sendable {
            var summary: String
            var metrics: [Metric] = []
            var reasons: [String] = []
            var chartNames: [String] = []
            var guidance: String? = nil

            struct Metric: Sendable, Identifiable {
                var label: String
                var value: String
                var id: String { label }
            }
        }
    }

    struct NumberItem: Sendable, Identifiable {
        var label: String
        var value: Double
        var unit: String
        var delta: Double?
        var deltaGood: Bool?
        var id: String { label }
    }

    struct Section: Sendable, Identifiable {
        var key: String
        var title: String
        var charts: [String]
        var recent: [RecentWorkout]?
        var cycles: [Cycle]?
        var avgCycle: Double?
        var id: String { key }
    }

    struct RecentWorkout: Sendable, Identifiable {
        var localDate: String?
        var activityType: String
        var activityLabel: String?
        var duration: Double?
        var totalDistance: Double?
        var totalDistanceUnit: String?
        var totalEnergyBurned: Double?
        var id: String { "\(localDate ?? "")-\(activityType)-\(duration ?? 0)" }
    }

    struct Cycle: Sendable, Identifiable {
        var start: String
        var flowDays: Int
        var cycleLen: Int?
        var id: String { start }
    }
}

/// チャートの系列データ。LocalAnalytics が組み立てる。
struct ChartSpec: Sendable {
    var name: String
    var title: String
    var ylabel: String
    var kind: Kind
    var labels: [String]
    var series: [Series]

    enum Kind: Sendable {
        case line, bar, multiLine, stackedBar
    }

    struct Series: Sendable, Identifiable {
        var name: String?
        var color: String
        var values: [Double?]
        var id: String { name ?? color }
    }
}

/// チャート未生成(データ無し)を表すエラー。
struct NoLocalData: Error {}
