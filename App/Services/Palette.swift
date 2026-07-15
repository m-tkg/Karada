import Foundation

/// dataviz スキルの参照パレット。サーバー(chartspec.py)と同一の配色を使う。
enum Palette {
    static let series = ["#2a78d6", "#1baf7a", "#eda100", "#008300",
                         "#4a3aa7", "#e34948", "#e87ba4", "#eb6834"]

    // 睡眠深度は blue のランプ、未分類・覚醒は別色相で区別しやすく
    static let sleepColors: [String: String] = [
        "AsleepDeep": "#104281", "AsleepCore": "#2a78d6", "AsleepREM": "#86b6ef",
        "AsleepUnspecified": "#eda100", "Awake": "#9acd32",
    ]
    static let sleepLabels: [String: String] = [
        "AsleepDeep": "深い睡眠", "AsleepCore": "コア睡眠", "AsleepREM": "レム睡眠",
        "AsleepUnspecified": "睡眠(未分類)", "Awake": "覚醒",
    ]
    static let otherGray = "#c3c2b7"
}
