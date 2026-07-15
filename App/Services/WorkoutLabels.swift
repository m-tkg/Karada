import Foundation

/// HKWorkoutActivityType の短縮名(HealthKitReader.WorkoutTypeNames と対応)を
/// 日本語表示に変換する(サーバー labels.py の WORKOUT_LABELS と同じ対訳)。
enum WorkoutLabels {
    static let labels: [String: String] = [
        "Running": "ランニング", "Walking": "ウォーキング", "Cycling": "サイクリング",
        "Hiking": "ハイキング", "Yoga": "ヨガ", "Swimming": "水泳",
        "FunctionalStrengthTraining": "筋力トレーニング(自重・ファンクショナル)",
        "TraditionalStrengthTraining": "筋力トレーニング(ウェイト)",
        "CoreTraining": "体幹トレーニング",
        "HighIntensityIntervalTraining": "HIIT",
        "Elliptical": "エリプティカル", "Rowing": "ローイング",
        "StairClimbing": "階段昇降", "Stairs": "階段",
        "Pilates": "ピラティス", "SocialDance": "社交ダンス",
        "CardioDance": "ダンス(有酸素)",
        "Cooldown": "クールダウン", "FlexibilityTraining": "ストレッチ",
        "CrossTraining": "クロストレーニング", "MixedCardio": "有酸素運動ミックス",
        "Soccer": "サッカー", "Basketball": "バスケットボール", "Baseball": "野球",
        "Tennis": "テニス", "TableTennis": "卓球", "Badminton": "バドミントン",
        "Golf": "ゴルフ", "MartialArts": "格闘技", "Bowling": "ボウリング",
        "Climbing": "クライミング", "SkatingSports": "スケート",
        "SnowSports": "スノースポーツ", "DownhillSkiing": "スキー",
        "Snowboarding": "スノーボード", "SurfingSports": "サーフィン",
        "PaddleSports": "パドルスポーツ", "JumpRope": "縄跳び",
        "Kickboxing": "キックボクシング", "Boxing": "ボクシング",
        "Other": "その他のワークアウト", "その他": "その他",
    ]

    static func label(for shortName: String) -> String { labels[shortName] ?? shortName }
}
