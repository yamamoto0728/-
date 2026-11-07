# 引継ぎノート（いまの状況だけ）

新しいセッションで作業を始める時に、1回だけ読む。「今日はここまで」と言われたら、このファイルを**上書き**して最新にする（履歴は `docs/progress-log.md` に追記）。

最終更新：2026-11-07

## いまの状況
- **iPhone アプリを App Store に出す途中**。名義はしゅうすけさんの個人（チーム `W55PPUR8L3`、Bundle ID `jp.chikaku.tama`）。Android は後日
- TestFlight には **1.0.0 (5)** まで上がっている。ビルドは Mac の Xcode でしかできない（あおが「ビルドして」と言うまでしない）
- アプリの入れ物 `chikaku-app` は **git の外**（T7 の一番上の `chikaku-app`。Windows では `D:\chikaku-app`）。画面は、ビルドの時にこのリポジトリの `tama/` をコピーして中に入れる。なので `main` にマージしても、iPhone のアプリはビルドし直すまで変わらない
- 閉じてもすれ違い：iPhone は Apple の位置の仕組み（`ChikakuLocation.swift`／画面側 `tama/bgloc-native.js`）。Android はまだ Transistorsoft（`tama/bgloc.js`、ストアの版はライセンスが要る）
- `npx cap sync` をすると `ios/App/App/capacitor.config.json` の `packageClassList` から `"ChikakuLocationPlugin"` が消える → 足し直す
- PR は #120 までマージ済み。開いている PR はない

## 待っていること
1. **あお**：Supabase で `supabase/tama_xitems.sql` を実行（中身を貼って渡す）
2. **あお（Mac）**：ビルド 6 を作る → 実機で、閉じた状態のすれ違いと「友達が来た」通知を学内で試す
3. **あお**：運営へのメール（Resend）が届くかの確認。届いたら試しの行を消す：`delete from public.tama_reports where reason = '運営への連絡：メールのテスト';`
4. **あお**：審査用アカウントを Supabase で作る → `supabase/tama_demo.sql` を実行（外部テスト・審査で必要）
5. **チーム**：公開の日を決める → `tama/index.html` の `APP_LAUNCH` に日付と App Store の URL を入れる

## 次にやること
- Web 版の「ちかくがアプリになりました！」の案内（App Store のボタン・QR・引き継ぎのコードを同じ画面でコピー）。今の `openAppIntro()` を直す。日付は空のまま作る
- ストアのページの文・プライバシーの答え・審査へのメモ（`D:\ちかく\reports\ちかく アプリ審査と安全対策.md` の A）
- Android の「閉じてもすれ違い」の作り直し

## 未解決
- すれ違いの記録を残す期間・アプリの一言の文言・課金の中身（要件定義書 v0.1 の未決）
