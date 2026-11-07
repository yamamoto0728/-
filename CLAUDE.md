# プロジェクト概要

**「ちかく」** — 法政大学 多摩キャンパスの学生向けの、「すれ違い」から友達ができるアプリ（出会い系に見せない）。

- **本体は `tama/index.html`**（`/tama/`。HTML/CSS/JS の1ファイル、ビルド不要）。データは `tama_` 付きの表（`supabase/`）
  - **アプリver**：`html.appv` の時だけ効く画面（試す6人とアプリ）。**Web 版**：それ以外の人
  - トップの URL は `/tama/` に転送（`vercel.json`）。`index.html`（最初の版）と `fes/`（学園祭版）は待機中
- **iPhone アプリ**：Capacitor 8 で `tama/` を包んだもの。入れ物 `chikaku-app` は **git の外**（T7 の一番上の `chikaku-app`。Windows では `D:\chikaku-app`）で、ビルドは Mac の Xcode だけ。`main` にマージしても、アプリはビルドし直すまで変わらない
- バックエンドは Supabase（RLS・RPC・Edge Function・pg_cron）。本番の Web は Vercel：https://chikaku-hosei.vercel.app
- リポジトリ：https://github.com/yamamoto0728/-
- 見た目の決まりは `tama/DESIGN-app.md`。UI を直す時は、先に `D:\ちかく\UI改善\00_改善ファイル.md` を読む

## チーム構成

- **あお（水原）** — 開発（Claude Code と作業）。**しゅうすけさん（山本、GitHub: yamamoto0728）** — リポジトリのオーナー・PM・Apple Developer の名義
- **アイデア班** — りく・りこ・ずなさん・はなちゃん（企画・渉外・広報・データ分析）
- ⚠️「山本さん」＝しゅうすけさん、「水原さん」＝あお。古い資料では別人のように書かれていることがある

# 最初に読むもの

- **いまの状況・待っていること・次にやること**：`docs/handoff.md`（セッションの始めに1回だけ読む）
- **過去の記録**：`docs/progress-log.md`（とても長い。**全部は読まない**。日付や言葉で検索して、その前後だけ読む）
- リポジトリの外の資料（`D:\ちかく\`）：審査と安全 `reports\ちかく アプリ審査と安全対策.md`、UI の研究 `reports\ちかく アプリ UI 研究.md`。必要な時だけ開く
- 要件定義書 v0.1：https://claude.ai/artifact/4uoRQLb8JFLPJ121xpw7Hj （PDF・ロードマップ・議事録は 2026-11-07 に整理して消した）

# 作業のしかた（このプロジェクトで決まっていること）

- あおへの返事は**すべて日本語**。むずかしい言葉は使わない。仕様の確認は AskUserQuestion のボタンで聞く。孤独感を直接聞くなど、負担になる機能や測り方はしない
- **SQL やコマンドを実行してもらう時は、ファイルの場所ではなく中身をそのまま貼る**（場所の文字列が SQL Editor に貼られて `syntax error` になった実例がある）
- 流れ：ブランチを切る → 直す → 偽の Supabase で画面を撮って確かめる → コミット → push → `main` に向けて PR → 報告
- 大きく見た目を変える時は、今と並べた比較の画像を作って見せる（`D:\ちかく\UI改善\比較_日付\`）
- 画面を撮る道具（偽の Supabase＋headless Edge）：`D:\ちかく\道具_画面を撮る\`（使い方はそこの README.md）
- Windows の PowerShell の `>` は文字コードを変えるので、`git diff` などをファイルに書く時は Bash を使う。T7 は Windows で `dubious ownership` が出るので、`git -c safe.directory=<フォルダ>` を付ける
- Mac と Windows で、同時に T7 の中のファイルを書き換えない

## 大きいファイルの読み方（トークンの節約）

- **`tama/index.html` は 1.1MB**。全部を読まない。`Grep` で関数名・ID を探して、`Read` の offset/limit でその前後だけ読む。直す時も Edit で該当の所だけ
- `fes/index.html`（400KB）・`index.html`（140KB）・`docs/progress-log.md`（190KB）も同じ
- 画面の確かめは、スクショを撮って必要な所だけ見る

# リポジトリの扱い方

このフォルダ（`yamamoto0728-original/`）は GitHub の原本とつながったクローン。**`main` を直接編集しない**。作業は必ずブランチを切る。

```
git fetch origin
git switch -c feat/○○ origin/main
```

ほかの人が先に `main` を更新していたら、作業ブランチで `git rebase origin/main`（衝突した時だけ手で直す）。

## PR の base は必ず `main`（2026-08-02 の失敗から）

まだマージされていない PR の上に、別の PR を積まない。前に積んだ時、上の PR は下のブランチに入っただけで `main` に届かず、GitHub では「Merged」と出るのに本番に出ない状態になった。前の PR に頼る作業でも base は `main` のままにして、前の PR がマージされてから `git rebase origin/main` で追いつく。

## 「マージして」と言われた時

1. 変えたファイルだけを `git add`（`git add .`・`git commit -a` は使わない。T7 では改行の形だけ変わったファイルがたくさん出ることがある）→ コミット（Co-Authored-By を付ける）
2. `git push -u origin <ブランチ>` → `gh pr create --base main`
3. 差分・文法・鍵が入っていないかを確かめてから `gh pr merge <番号> --merge`
4. マージが止められた時（権限や確認の仕組み）は、無理に通さない。あおに「PR の URL を開いて、Merge pull request → Confirm merge」を押してもらう手順を伝える
5. マージのあとに SQL の実行などが要る時は、その中身を貼って伝える

`gh` は認証済み（アカウント：blueaochan03-spec）。

# 「今日はここまで」と言われた時

1. `docs/handoff.md` を**上書き**して、次のセッションが読むだけで再開できる状態にする（いまの状況／だれの何を待っているか／次にやること／未解決）
2. `docs/progress-log.md` の**いちばん下に**「- 日付: 一言」を足す（上書きしない）
3. この CLAUDE.md は、決まりが変わった時だけ直す（毎回は書きかえない。毎回すべて読み込まれるため）
