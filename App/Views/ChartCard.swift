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
                }
                .padding(12)
                .background(Color(.secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 12))
            } else if failed {
                EmptyView()
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .frame(height: 190)
            }
        }
        .task(id: range) {
            spec = nil
            failed = false
            do {
                spec = try await LocalAnalytics.buildChart(name: name, range: range)
            } catch {
                failed = true  // データ無しなどは静かに非表示
            }
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

    var body: some View {
        let pts = points
        Group {
            if spec.kind == .line || spec.kind == .multiLine {
                Chart(pts) { p in
                    LineMark(x: .value("日付", p.date), y: .value(spec.ylabel, p.value))
                        .foregroundStyle(by: .value("系列", p.series))
                        .interpolationMethod(.monotone)
                }
            } else {
                Chart(pts) { p in
                    BarMark(x: .value("日付", p.date), y: .value(spec.ylabel, p.value))
                        .foregroundStyle(by: .value("系列", p.series))
                }
            }
        }
        .chartForegroundStyleScale(domain: seriesNames, range: seriesColors)
        .chartLegend(spec.series.count > 1 ? .visible : .hidden)
        .chartYAxisLabel(spec.ylabel)
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
