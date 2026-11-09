# 引継ぎノート（いまの状況だけ）

新しいセッションで作業を始める時に、1回だけ読む。「今日はここまで」と言われたら、このファイルを**上書き**して最新にする（履歴は `docs/progress-log.md` に追記）。

最終更新：2026-11-09（夜）

## いまの状況（ひとことで）
**iPhone アプリを App Store に出す直前。** TestFlight に **1.0.0 (11)** を出した。これを審査に出すビルドにする予定。安全の総点検も済み、本番の Supabase で「悪い人のつもりの試し18項目」が全部 OK。残りは、学内での実機テストとすれ違いの動画、App Store Connect への入力、提出。

## 11/07〜11/09 にやったこと
- 今週のイベント（同じ答えが5人そろうと今週だけの部屋）→ マージ・SQL 実行済み
- ストアに出す手順書・ストアの文・安全対策のプロンプトを作った（`D:\ちかく\` の **S0〜S3**。下の「資料」）
- **安全の総点検**（PR #126）。穴をふさいだ：友達の申請の相手の書きかえ・「同じ人にだけ」の悩みがだれでも読めた・授業／昼の通知を外から連打できた・投稿の名前のなりすまし・止めた人の投稿が見えた・招待コードの当てずっぽう・アカウント削除の消し漏れ・XSS 2か所。NG ワードをサーバーの1つの表（`tama_ng_words`）と関数（`tama_ng_hit`）にまとめた
  - SQL：`tama_moderation.sql`・`tama_hardening.sql` は**実行済み**。`tama_audit.sql`（一覧）・`tama_attack_test.sql`（試し18項目、本番で全部 OK）
  - Edge Functions：`send-match-push`・`tama-delete-account`・`tama-remind` を**貼りかえ済み**
- 審査用アカウント2つ（`chikaku.hosei+review1@gmail.com`・`+review2`）を作り、`tama_demo.sql` を実行済み（友達・トーク3件・すれ違い・時間割）。**パスワードはあおが持っている**（リポジトリには書かない）
- アプリの設定：使っていない背景モード（fetch・processing）・動きのセンサーの説明文・Transistorsoft の名残りを外した。背景モードは location だけ
- 見た目の直し：iPhone Pro Max（幅440）でパソコン用のスマホの枠の中に小さく出ていた → アプリの中はいつも全画面（`html.native`）。初めての使い方の画面にシートが重なる・トーク中にタブが光らない・入力欄の下のすき間・地図の13:00の印・ちかくタイムのカードの余白・今日のレアの文が切れる など
- ストア用のスクリーンショット6枚（1320×2868）：`D:\ちかく\スクショ_2026-11-09\`

## 待っていること（人がやること）
1. **あお・しゅうすけさん（学内で2台）**：ビルド11で実機テスト（S0 の 1-3 の表。とくに閉じている時のすれ違い・友達が学内に来た通知・Pro Max で全画面か）
2. **同じく**：すれ違いの動画（30秒。S0 の 3-4）→ YouTube 限定公開などのリンクを Claude に
3. **Claude**：リンクが来たら、S1 の審査メモ（英語）に、パスワード（あおから聞く）と動画のリンクを入れて仕上げる
4. **しゅうすけさん**：App Store Connect に入れる（S0 の 4-3。スクショ6枚・S1 の文・年齢18+・プライバシーの申告・ビルド11・審査メモ・手動でリリース）→ 審査へ提出
5. **あお**：通報のメール（Resend）が本当に届くか確かめる（S3 の 3-3。審査メモに書いてあるので、提出の前に）
6. **あお**：二段階認証（S3 の 3-1）
7. **チーム**：公開の日を決める → `tama/index.html` の `APP_LAUNCH` に日付と App Store の URL

## ビルドのしかた（Mac。あおが「ビルドして」と言った時だけ）
- 道具は `/Volumes/T7/chikaku-app/tools/`（`/tmp` は Mac を再起動すると消えるので、ここに写してある）
  1. `python3 /Volumes/T7/chikaku-app/tools/chikaku-sync.py`：このリポジトリの `tama/`・`privacy/` などを `chikaku-app/ios/App/App/public` に写す（cordova.js は残す）。**写す前に、手元が `main` の最新か確かめる**
  2. `ios/App/App.xcodeproj/project.pbxproj` の `CURRENT_PROJECT_VERSION` を1つ上げる（2か所。いまは 11）
  3. `xcodebuild -project App.xcodeproj -scheme App -configuration Release -destination 'generic/platform=iOS' -archivePath /tmp/chikakuN.xcarchive -allowProvisioningUpdates archive`
  4. `xcodebuild -exportArchive -archivePath /tmp/chikakuN.xcarchive -exportOptionsPlist /Volumes/T7/chikaku-app/tools/chikaku-export.plist -exportPath /tmp/chikakuN-export -allowProvisioningUpdates`（そのまま App Store Connect に送られる）
- シミュレーターで見る時は `-configuration Debug -destination 'id=<シミュレーター>' -derivedDataPath /tmp/chikaku-sim build` → `xcrun simctl install`
- SQL を渡す前に試す時：`tools/pgt.py`（pip の `pgserver` で手元に Postgres）・`stub.sql`（Supabase のまね）・`loadall.sh`（SQL を順に入れる）・`seed.sql`（審査用の2人）
- `npx cap sync` をすると `ios/App/App/capacitor.config.json` の `packageClassList` から `"ChikakuLocationPlugin"` が消える → 足し直す
- 触らないもの：`App/public` の中を手で直さない（このリポジトリを直して写す）・`capacitor.config.json`・`config.xml`・`CapApp-SPM/Package.swift`・Info.plist の説明文／URL／暗号化・`AppDelegate.swift`・`SceneDelegate.swift`・部品の版

## 気をつけること
- Supabase の SQL Editor に貼る SQL に、**絵文字（⚠️ など）や全角の「？」を入れない**（画面が壊して、エラーになった）
- SQL Editor は最後の表しか出さないので、確かめの表はいちばん最後に置く
- T7 は Windows と共有。ほかのファイルが改行コードだけ変わって見えるが、触らない。`tama/index.html` は LF にそろえてコミット
- このMacからは GitHub に push できない（Windows の Cursor から push・マージ）

## 資料（`D:\ちかく\` の一番上）
| ファイル | 中身 |
|---|---|
| S0_ストアに出すまでの手順書.md | 全部のステップと、どこを押すか |
| S1_ストアに出す準備.md | App Store Connect に貼る文（説明文・キーワード・年齢・プライバシー・審査メモ） |
| S2_安全対策のプロンプト.md | 安全の総点検を頼んだ文 |
| S3_安全対策の結果.md | 総点検の結果・人がやること・残っていること |
| E1〜E3_*.ts | 貼りかえた Edge Function（もう貼りかえ済み） |
| スクショ_2026-11-09/ | ストア用のスクリーンショット6枚 |

## 決めてほしいこと・あとでやること
- 画面が読む `supabase-js` を CDN から版を決めずに読んでいる（`@2`）→ 版を決めて SRI を付けるか（部品の版の決まりに近いので、OK をもらってから）
- 近くの人の位置（約30mのます目）を、サーバーでも「今日すれ違った人と友達だけ」に絞るか
- 閉じている間のすれ違いの合言葉を、キーチェーンに移す（いまは UserDefaults）
- 今週のイベント：答えを変えると、前の今週の部屋に入ったまま次の部屋にも入れる
- Android（Google Play）：閉じてもすれ違いの作り直し（いまは Transistorsoft）・テスター12人で14日・CSAE のページ・データセーフティ

## 未解決
- すれ違いの記録を残す期間・アプリの一言の文言・課金の中身（要件定義書 v0.1：https://claude.ai/artifact/4uoRQLb8JFLPJ121xpw7Hj ）
- `道具_画面を撮る/t_safety.js` が今の SQL では cron の所で止まる（前から。急がない）
