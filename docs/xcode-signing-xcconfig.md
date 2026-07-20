# iOS プロジェクトの署名設定を xcconfig に切り出す手順

Team ID と Bundle ID がリポジトリに固定されていると、他の人（や自分の別アカウント）が
そのプロジェクトをビルドできない。追跡ファイルを書き換えるしか方法が無く、
`git status` に差分が残り続けて誤コミットの原因になる。

この手順では、**既定値はコミットしたまま、各自がローカルで上書きできる**構成に変える。
上書き用ファイルは git 管理外なので、**追跡ファイルの差分は一切出ない**。

## 前提知識

### Team ID は秘密情報ではない

`DEVELOPMENT_TEAM`（例: `G72M73C546`）は配布したアプリの署名に
`application-identifier = TEAMID.bundleID` として埋め込まれており、
IPA を展開すれば誰でも読める。署名には別途**証明書の秘密鍵**（Keychain 内）と
App Store Connect の権限が必要なので、Team ID 単体では何もできない。

したがって**この作業の目的は秘匿ではなく、他者がビルドできるようにすること**。
既定値は堂々とコミットしてよい。

### Bundle ID も必ず上書き対象にする

Team ID だけ差し替えても失敗する。Bundle ID は世界で一意で、
既存の Bundle ID は元の開発者のチームに登録済みのため、
他アカウントの Automatic signing は登録に失敗する。
**`DEVELOPMENT_TEAM` と `PRODUCT_BUNDLE_IDENTIFIER` はセットで扱う。**

## 手順

### 1. xcconfig を2つ用意する

`Config/Signing.xcconfig`（**コミットする**）:

```
// 署名まわりの既定値。
// 自分のアカウントでビルドする場合はこのファイルを編集せず、
// Config/Local.xcconfig を作って上書きする。

DEVELOPMENT_TEAM = XXXXXXXXXX
PRODUCT_BUNDLE_IDENTIFIER = com.example.myapp

// 末尾の "?" は「ファイルが無ければ無視する」の意味。
// これにより Local.xcconfig が無い環境（CI 等）でもそのままビルドできる。
#include? "Local.xcconfig"
```

> **`#include?` の `?` は必須。** `#include` にすると、ファイルが無い環境で
> ビルドが失敗する（CI が壊れる）。

`Config/Local.xcconfig.sample`（**コミットする**、記入例）:

```
// cp Config/Local.xcconfig.sample Config/Local.xcconfig して編集する。
DEVELOPMENT_TEAM = XXXXXXXXXX
PRODUCT_BUNDLE_IDENTIFIER = com.example.myapp
```

### 2. .gitignore に追加

```
Config/Local.xcconfig
```

### 3. xcconfig をプロジェクトに適用する

#### XcodeGen を使っている場合

`project.yml` に追加:

```yaml
configFiles:
  Debug: Config/Signing.xcconfig
  Release: Config/Signing.xcconfig
```

**そして `project.yml` から `DEVELOPMENT_TEAM` と `PRODUCT_BUNDLE_IDENTIFIER` を削除する。**
`settings:` に書いた値は pbxproj のビルド設定へ直接展開され、**xcconfig より優先される**ため、
残したままだと上書きが効かない。`settings.base` と `targets.<name>.settings.base` の
両方を確認すること。

削除後に `xcodegen generate` を実行する。

#### 素の Xcode プロジェクト（XcodeGen 無し）の場合

1. xcconfig ファイルを Xcode のプロジェクトナビゲータに追加する
2. プロジェクト（ターゲットではない）を選択 → **Info** タブ → **Configurations**
   → Debug / Release それぞれで xcconfig を選ぶ
3. **ターゲットの Build Settings から `DEVELOPMENT_TEAM` と
   `PRODUCT_BUNDLE_IDENTIFIER` を削除する**（値が設定されていると xcconfig を上書きする）。
   対象の行を選んで <kbd>Delete</kbd> で「未設定」に戻す。
   Signing & Capabilities で Team を選ぶと Build Settings に書き戻されるので、
   この後は GUI で Team を触らないこと。

## 検証（必ず実施する）

### 1. 上書きが実際に効くか

```sh
printf 'DEVELOPMENT_TEAM = TESTTEAM99\nPRODUCT_BUNDLE_IDENTIFIER = com.example.test\n' \
  > Config/Local.xcconfig
# XcodeGen を使っている場合は xcodegen generate
xcodebuild -project MyApp.xcodeproj -target MyApp -showBuildSettings 2>/dev/null \
  | grep -E "^\s+(DEVELOPMENT_TEAM|PRODUCT_BUNDLE_IDENTIFIER) "
```

`TESTTEAM99` / `com.example.test` が出れば成功。
既定値のままなら手順3の削除漏れ（Build Settings 側が勝っている）。

### 2. 追跡ファイルが汚れないか（XcodeGen の場合）

`Local.xcconfig` の有無で生成物が変わらないことを確認する。

```sh
rm -f Config/Local.xcconfig && xcodegen generate >/dev/null
A=$(shasum MyApp.xcodeproj/project.pbxproj | cut -d' ' -f1)
printf 'DEVELOPMENT_TEAM = TESTTEAM99\n' > Config/Local.xcconfig && xcodegen generate >/dev/null
B=$(shasum MyApp.xcodeproj/project.pbxproj | cut -d' ' -f1)
[ "$A" = "$B" ] && echo "OK: 追跡ファイルは変化しない" || echo "NG: 差分が出る"
```

XcodeGen は `#include?` を辿らないため一致するはず。

### 3. 無視設定と実ビルド

```sh
git check-ignore -v Config/Local.xcconfig     # 無視されているか
rm -f Config/Local.xcconfig                    # 検証用ファイルを消す
# XcodeGen の場合は xcodegen generate で元に戻す

# 実機ターゲット（署名が実際に走る）でビルドする。シミュレータだけでは署名を検証できない
xcodebuild -project MyApp.xcodeproj -scheme MyApp \
  -destination 'generic/platform=iOS' -allowProvisioningUpdates build
```

### 4. CI

CI には `Local.xcconfig` が存在しないので既定値でビルドされる。
タグ push 等で CI が走る構成なら、**この変更だけを含むタグを打って検証する**と
失敗時の切り分けが楽になる。

## 落とし穴

| 症状 | 原因 |
|---|---|
| xcconfig を足したのに値が変わらない | ビルド設定（pbxproj / project.yml の `settings`）に値が残っている。ビルド設定は xcconfig より優先される |
| CI だけビルドが落ちる | `#include` の `?` が抜けていて、`Local.xcconfig` が無い環境で失敗している |
| Team を変えたのに署名に失敗する | Bundle ID を変えていない。既存 Bundle ID は元のチームに登録済みで他アカウントでは使えない |
| Xcode で Team を選び直したら元に戻った | Signing & Capabilities の操作が Build Settings に値を書き戻している |

pbxproj の `TargetAttributes` に `DevelopmentTeam` が残ることがあるが、これは
Xcode UI 表示用のレガシー項目で、実際の署名を決めるのは xcconfig 由来のビルド設定。
上の検証1が通っていれば実害は無い。

## README に書いておくこと

```markdown
### 自分のアカウントでビルドする

`Config/Signing.xcconfig` は編集せず、`Config/Local.xcconfig` を作って上書きする。

    cp Config/Local.xcconfig.sample Config/Local.xcconfig
    # DEVELOPMENT_TEAM と PRODUCT_BUNDLE_IDENTIFIER を自分の値に書き換える

`Config/Local.xcconfig` は .gitignore 済みなので、追跡ファイルの差分は出ない。
Bundle ID は必ず変更すること（元の Bundle ID は他アカウントでは使えない）。
```

HealthKit・Push 通知・App Groups などの capability を使う場合、
無料の Personal Team ではプロビジョニングできないことがある旨も添えておくとよい。

---

## Claude Code への指示文（そのまま貼れる）

> このプロジェクトの署名設定（`DEVELOPMENT_TEAM` / `PRODUCT_BUNDLE_IDENTIFIER`）が
> リポジトリに固定されていて、他の人が自分のアカウントでビルドできない。
> 既定値はコミットしたまま、各自が git 管理外のファイルで上書きできる構成に変えてほしい。
>
> - `Config/Signing.xcconfig`（コミット）に既定値を置き、末尾で
>   `#include? "Local.xcconfig"` する（`?` を必ず付ける。無いと CI が壊れる）
> - `Config/Local.xcconfig` は `.gitignore` に追加し、`.sample` を用意する
> - `DEVELOPMENT_TEAM` と `PRODUCT_BUNDLE_IDENTIFIER` は**セットで**扱う
>   （Team だけ変えても Bundle ID の衝突で署名に失敗するため）
> - **元のビルド設定からこの2つを必ず削除する**。ビルド設定は xcconfig より
>   優先されるため、残っていると上書きが効かない
>   （XcodeGen なら `project.yml` の `settings`、素の Xcode ならターゲットの Build Settings）
>
> 完了したら次を検証して結果を報告してほしい。
>
> 1. 仮の `Local.xcconfig` を置き、`xcodebuild -showBuildSettings` で値が上書きされること
> 2. （XcodeGen の場合）`Local.xcconfig` の有無で `project.pbxproj` が変化しないこと
> 3. `-destination 'generic/platform=iOS'` の実機ターゲットでビルドが通ること
> 4. 検証用の `Local.xcconfig` を消して元の状態に戻すこと
>
> README に「自分のアカウントでビルドする」手順も追記すること。
