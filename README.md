# Karada(カラダ)

iPhone のヘルスケア(HealthKit)データを**端末上で直接分析**する個人用アプリ。
サーバーには依存せず、データは端末の外に出ない。

- 今日の発見(直近7日 vs 4週平均のルールベース洞察)
- 今月の評価(歩数・睡眠・運動量などを一般的な指針と前月比で評価)
- いまの数字(直近30日平均 + 前月比)
- 心肺・活動量・睡眠・体組成・歩き方・食事・月経周期・運動記録のグラフ
  (Swift Charts でネイティブ描画、期間切替つき)

歩数などの iPhone/Watch 二重計上回避、睡眠の重複区間マージ・ステージ優先
ソース選択など、集計ロジックはすべて `App/Services/LocalAnalytics.swift` に
まとまっている。

## ビルド / 実機インストール

`.xcodeproj` は [xcodegen](https://github.com/yonaskolb/XcodeGen) の生成物
(gitignore 対象)。`App/` のファイルを増減したら `xcodegen generate` を
再実行してからビルドする。

```sh
xcodegen generate
open Karada.xcodeproj   # Xcode で実機を選んで Run
# または CLI ビルド確認:
xcodebuild -project Karada.xcodeproj -scheme Karada \
  -destination 'generic/platform=iOS' -allowProvisioningUpdates build
```

署名は Team `G72M73C546` / Automatic(project.yml に定義済み)。
HealthKit を使うため**実データでの動作確認は実機のみ**。

初回起動 → ダッシュボードタブを開くとヘルスケアの認可シートが出るので
「すべてオンにする」→ 許可。

## デバッグ用起動引数(シミュレータ検証)

- `--debug-charts` — チャート描画を単体表示

## Xcode Cloud / TestFlight

`Karada.xcodeproj` は生成物なので、Xcode Cloud では `ci_scripts/ci_post_clone.sh`
が `xcodegen generate` を実行してからビルドする。

App Store Connect の Xcode Cloud ワークフローは以下で設定する。

- Scheme: `Karada`
- Archive configuration: `Release`
- Start Condition: tag push、例: `v*`

リリースタグは次で作成・push する。

```sh
make release-tag
```

配布ごとに `project.yml` の `CURRENT_PROJECT_VERSION` を上げる。同じビルド番号は
App Store Connect に拒否される。
