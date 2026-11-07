# 引継ぎノート（いまの状況だけ）

新しいセッションで作業を始める時に、1回だけ読む。「今日はここまで」と言われたら、このファイルを**上書き**して最新にする（履歴は `docs/progress-log.md` に追記）。

最終更新：2026-11-07（夜）

## 今日やったこと（11/07）
- Mac で「今週のイベント」（同じ答えが5人そろうと今週だけの部屋。アプリverだけ）を作った → PR #122
- PR #119（iPhone の閉じてもすれ違いを Apple の仕組みに・友達が来たら知らせる・設定の並べ直し）と PR #120（すれ違いの項目・ひとこと・地図の印・ホームの人数）を `main` にマージ
- Claude Code の環境整理：CLAUDE.md を 198KB → 約6KB に（進捗ログを `docs/progress-log.md`、状況をこのファイルへ）。PR #121（**未マージ**）
- 今週のイベントの気になる点：答えを変えると、前の今週の部屋に入ったまま次の部屋にも入れる（直すなら、答えを変えた時に前の部屋から抜ける）
- 画面を撮る道具を `D:\ちかく\道具_画面を撮る\` に置いた（README あり）
- あおの指示で、古い資料（ロードマップ・議事録・要件定義書の PDF・論点の PDF・多摩祭の当日マニュアル・中間報告・古い APK・C2〜C4 など）と手元の古いブランチ 115本を消した

## いまの状況
- **iPhone アプリを App Store に出す途中**。名義はしゅうすけさんの個人（チーム `W55PPUR8L3`、Bundle ID `jp.chikaku.tama`）。Android は後日
- TestFlight には **1.0.0 (5)** まで。ビルドは Mac の Xcode でしかできない（あおが「ビルドして」と言うまでしない）
- アプリの入れ物 `chikaku-app` は **git の外**（T7 の一番上の `chikaku-app`。Windows では `D:\chikaku-app`）。画面はビルドの時にこのリポジトリの `tama/` をコピーして入れる。`main` にマージしても、アプリはビルドし直すまで変わらない
- 閉じてもすれ違い：iPhone は Apple の位置の仕組み（`ChikakuLocation.swift`／画面側 `tama/bgloc-native.js`）。Android はまだ Transistorsoft（`tama/bgloc.js`、ストアの版はライセンスが要る）
- `npx cap sync` をすると `ios/App/App/capacitor.config.json` の `packageClassList` から `"ChikakuLocationPlugin"` が消える → 足し直す
- 手元のブランチは main と `feature/push-debug`（7月の送っていないコミットが1つ。消すなら あお が手で `git branch -D`）

## 待っていること
1. （済み）PR #121・#122 はマージ済み。しゅうすけさんに CLAUDE.md を軽くしたことを一言
2. **あお**：Supabase で `supabase/tama_weekly.sql`（今週のイベント）も実行。`supabase/tama_xitems.sql` を実行（中身を貼って渡す。確かめ：`select public.tama_simple_common('{"mbti":"INFP"}'::jsonb, '{"mbti":"INFP"}'::jsonb);` → `MBTI「INFP」`）
3. **あお**：使わないプラグイン・コネクタを止めるか決める（「data」のプラグインは外すのがおすすめ。Canva・Figma・Gmail・カレンダー・Notion・Todoist は、ちかくで使わなければ `/mcp` でこのプロジェクトだけ止める）
4. **あお（Mac）**：ビルド 6 → 実機で、閉じた状態のすれ違いと「友達が来た」通知を学内で試す
5. **あお**：運営へのメール（Resend）が届くかの確認。届いたら試しの行を消す：`delete from public.tama_reports where reason = '運営への連絡：メールのテスト';`
6. **あお**：審査用アカウントを Supabase で作る → `supabase/tama_demo.sql` を実行（外部テスト・審査で必要）
7. **チーム**：公開の日を決める → `tama/index.html` の `APP_LAUNCH` に日付と App Store の URL

## 次にやること
- `/context` で CLAUDE.md の分が減ったか確かめる
- Web 版の「ちかくがアプリになりました！」の案内（アプリでできること〈閉じてもすれ違い・授業のコミュニティ〉・App Store のボタンと QR・引き継ぎのコードを同じ画面でコピー）。今の `openAppIntro()` を直す。日付は空のまま作る。Android の人には「準備中、Web 版をそのまま使える」だけ
- ストアのページの文・プライバシーの答え・審査へのメモ（`D:\ちかく\reports\ちかく アプリ審査と安全対策.md` の A）
- Android の「閉じてもすれ違い」の作り直し

## 未解決
- すれ違いの記録を残す期間・アプリの一言の文言・課金の中身（要件定義書 v0.1：https://claude.ai/artifact/4uoRQLb8JFLPJ121xpw7Hj ）
- `道具_画面を撮る/t_safety.js` が今の SQL では cron の所で止まる（前から。急がない）
