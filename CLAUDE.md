# Karada

HealthKit のデータを端末上で直接分析する iOS アプリ(SwiftUI、サーバー非依存)。

## 構成

- `App/Services/LocalHealthStore.swift` — HealthKit への生クエリ層
  (HKStatisticsCollectionQuery でのソース別/日次集計、カテゴリサンプル取得等)
- `App/Services/LocalAnalytics.swift` — 集計ロジック本体。歩数等の
  iPhone/Watch 二重計上回避(日ごとに合計最大のソースを採用)、睡眠の
  重複区間マージ、ステージ優先ソース選択、今日の発見・今月の評価・
  いまの数字、16種のチャート組み立て
- `App/Models/DashboardModels.swift` — 画面表示用の純粋な値型
  (DashboardData / ChartSpec)。JSON デコードには依存しない
- `App/Views/` — DashboardView(メイン画面)、ChartCard/SpecChart
  (Swift Charts 描画)、SettingsView

## ビルド / テスト

`App/` 配下のファイルを**追加・削除・リネームしたら必ず `xcodegen generate`**
してからビルドする。

```sh
xcodegen generate
xcodebuild -project Karada.xcodeproj -scheme Karada \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' build
xcodebuild -project Karada.xcodeproj -scheme Karada \
  -destination 'generic/platform=iOS' -allowProvisioningUpdates build
```

- **SourceKit が出す `Cannot find 'X' in scope` はノイズ**。`xcodebuild` の
  結果で判断する
- 変更後は **シミュレータと実機ターゲットの両方**をビルドして確認する
- HealthKit の認可ダイアログはシミュレータでは CLI から操作できない
  (`simctl privacy` は health サービス非対応)。集計ロジックの純粋関数
  (区間マージ・週バケット・剰余算など)はスタンドアロン Swift スクリプトで
  個別に検証できる
