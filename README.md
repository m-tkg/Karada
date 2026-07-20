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

> **自分のアカウントでビルドする場合**は、先に `Config/Local.xcconfig` を作って
> Team ID と Bundle ID を自分の値に差し替える必要がある。
> 手順は[こちら](#自分のアカウントでビルドする)。

## ビルド / 実機インストール

`.xcodeproj` は [xcodegen](https://github.com/yonaskolb/XcodeGen) で
`project.yml` から生成して git 管理している。`App/` のファイルを増減したら
`xcodegen generate` を再実行し、`Karada.xcodeproj` の差分もコミットする。

```sh
xcodegen generate
open Karada.xcodeproj   # Xcode で実機を選んで Run
# または CLI ビルド確認:
xcodebuild -project Karada.xcodeproj -scheme Karada \
  -destination 'generic/platform=iOS' -allowProvisioningUpdates build
```

署名は Automatic。Team ID と Bundle ID は `Config/Signing.xcconfig` に定義。
HealthKit を使うため**実データでの動作確認は実機のみ**。

### 自分のアカウントでビルドする

`Config/Signing.xcconfig` は編集せず、`Config/Local.xcconfig` を作って上書きする。

```sh
cp Config/Local.xcconfig.sample Config/Local.xcconfig
# DEVELOPMENT_TEAM と PRODUCT_BUNDLE_IDENTIFIER を自分の値に書き換える
xcodegen generate
```

`Config/Local.xcconfig` は `.gitignore` 済みで、`xcodegen generate` の出力にも
影響しない。そのため**追跡ファイルの差分は一切出ない**(誤コミットの心配が無い)。

Bundle ID は必ず変更すること。`com.mtkg.karada` は元の開発者のチームに
登録済みで、他のアカウントでは Automatic signing に失敗する。
HealthKit の entitlement を使うため、無料の Personal Team では
プロビジョニングできない場合がある。

初回起動 → ダッシュボードタブを開くとヘルスケアの認可シートが出るので
「すべてオンにする」→ 許可。

## デバッグ用起動引数(シミュレータ検証)

- `--debug-charts` — チャート描画を単体表示

## Xcode Cloud / TestFlight

Xcode Cloud では git 管理している `Karada.xcodeproj` を使ってビルドする。
`ci_scripts/ci_post_clone.sh` は `project.yml` との同期確認用に
`xcodegen generate` を実行する。

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
