# プロジェクト概要

**「ちかく」** — 位置情報ベースの「すれ違い」機能に特化した、恋愛に縛られないマッチングアプリ。

- 現状は `index.html` 1ファイルで完結したプロトタイプ（HTML/CSS/JS、ビルド不要）
- バックエンドは Supabase（匿名認証でユーザーIDを発行、URL/anonキーはコード内に直書き）
- 主な機能: オンボーディング（絵文字アバター・タグ・興味関心選択）、現在地取得と近くのユーザー一覧・地図表示、NGワードフィルタによる不適切投稿の簡易ブロック
- リポジトリ: https://github.com/yamamoto0728/-

## チーム構成

- **yamamoto0728** — リポジトリオーナー
- **あお（blue.aochan03@gmail.com）** — 開発メンバー（Claude Codeと一緒に作業）

# 引継ぎノート（最新セッションの状態）

新しいセッションでこのリポジトリを開いたら、まずこのセクションを読む。過去の詳細な履歴は下の「進捗ログ」を参照。

## 今回やったこと（2026-08-02）— プッシュ通知RLSエラー解消の実機確認 ＋ いいね通知の追加

前回特定した根本原因（`push_subscriptions`にSELECTポリシーが無いため、supabase-jsの`.upsert()`がRLSで403になる）について、あおが本番のSupabase SQL Editorで以下を実行:
```sql
create policy "select own subscription"
  on public.push_subscriptions for select
  using (auth.uid() = id);
```
その後アプリで通知トグルをONにしたところ**エラーなく成功**。これでプッシュ通知登録のRLS問題は解決確認済み。

また、mainが山本さんの作業（マッチ24h無効化・地図縮小・コミュ情報表示、コミットは`13f6cce`まで）で進んでいたため、まず`main`を取り込んでから新規ブランチ`feature/like-push-notify`を作成して以下を実装:

1. `supabase/push_subscriptions.sql`にSELECTポリシーを追記（本番Supabaseには適用済みだが、リポジトリ側の記録・再現用として反映）。「upsertにはSELECTポリシーが必須」とコメントも残した
2. デバッグ用の`alert('🔧 通知デバッグ: ...')`表示を撤去。`notifyMatchPush(uid)`を汎用の`notifyPush(uid,title,body)`に置き換え、失敗時は`console.error`のみに変更（毎回alertが出ると次のいいね通知機能でうるさすぎるため）
3. **新機能: いいねされた側にもプッシュ通知**。`doLike()`で相手からの片想いいいね（マッチ未成立）の場合に`notifyPush(uid,'いいねが届きました💌','気になる人があなたにいいねしました。プロフィールを確認してみて！')`を呼ぶようにした。**誰からのいいねかは通知本文に出さない設計**（送った側の名前を伏せる。UI上も「誰かに好かれている」以上の情報は今まで表示していなかったため、その情報量に合わせた）
4. マッチ時の通知（`createMatch`内）は`notifyPush(uid,'マッチしました！',myName+'さんと両想いになりました')`として維持（こちらは相互いいね成立後なので名前を出す）

## ブロッカー・待ち状態

- 現在ブロッカーなし。`feature/like-push-notify`ブランチでの実装が完了し、あおの動作確認・「マージして」指示を待っている状態

## 次回やること

### あお（ユーザー）がやること
1. 実機で「いいね」を送って、相手側の端末（またはテストアカウント）に「いいねが届きました💌」の通知が来るか確認
2. 問題なければClaudeに「マージして」と伝える

### Claudeがやること
1. あおの動作確認OK後、`feature/like-push-notify`をcommit→push→PR作成
2. 最終確認として、実際にマッチ発生時にスマホへ通知が届くか（Edge Function `send-match-push`まで通るか）のエンドツーエンド動作確認は依然未実施なので、機会があれば進める

## 未解決の疑問点

- いいね通知で送信者名を伏せる設計にしたが、あおが「誰からのいいねか分かった方がいい」という意図だった場合は要調整（未確認、あおの好みを聞く必要あり）
- `push_subscriptions`に行が入った状態で実際にマッチさせ、Edge Function経由で通知が届くところまでは依然未確認
- 前回・今回とも、あおの「マージして」指示のもとClaudeがpush/PR作成まで実施（実マージはあおが手動）。`gh` CLIがこの環境に無いため、PR作成だけは毎回あおが手動リンクから行う運用で確定

# リポジトリの扱い方

このフォルダ（`yamamoto0728-original/`）は GitHub 上の原本と `.git` でつながった実クローン。**`main` ブランチを直接編集しない**。作業は必ずブランチを切って行う。

```
git checkout -b feature/○○
```

複数メンバーが同時に作業しても、ブランチを分けていればお互いの変更を壊さない。他メンバーが先に `main` を更新していた場合は作業ブランチ側で追従する:

```
git fetch origin
git rebase origin/main   # 衝突した場合だけ手動で解消
```

# 「マージして」と指示されたときのClaudeの役割

ユーザーから「マージして」と指示されたら、Claudeは以下を行う（**PR作成まで**。実際のmainへの取り込みはユーザー/チームが手動で行う）:

1. `git add` → `git commit`（変更内容を記録、メッセージは変更内容から作成）
2. `git push origin <作業ブランチ名>`
3. `gh pr create --base main`（Pull Requestを自動作成）
4. 作成したPRのURLを報告して完了

**Claudeはここで止まる。mainへの自動マージ・強制的な衝突解決は行わない。**

## そのあとユーザーがやること

1. 提示されたPRのURLを開き、差分を確認する
2. 必要ならチームメンバーにレビューを依頼する
3. 問題なければGitHub上で「Merge pull request」を押す（これでようやく`main`＝原本に反映される）
4. コンフリクトが出ていたら、その内容をClaudeに伝えて一緒に解消する

## 前提条件

PR作成には `gh` CLI のログインが必要（`gh auth login`）。未認証の場合、Claudeはcommit/pushまでしかできない。

# 「今日はここまで」と指示されたときのClaudeの役割

ユーザーが「今日はここまで」「一旦ここで終わり」など作業終了の合図を出したら、Claudeはこのファイル冒頭の「引継ぎノート」セクションを**上書き**して、次回セッションが読むだけで迷わず再開できる状態にする。

引継ぎノートに書く内容:

1. 今回のセッションでやったこと（要約でよい、詳細は進捗ログ参照でOK）
2. 今ブロックされていること・誰の返事/操作待ちか（例: 「山本さんのSupabase招待待ち」のように、待っている相手と対象を具体的に）
3. 次回再開したらまず何をするか
4. 未解決の疑問点・判断が必要なこと

進捗ログ（下のセクション）とは違い、引継ぎノートは追記ではなく**常に最新状態だけを残す**。これにより、次のセッションが長い進捗ログを遡って推測する必要がなくなる（今回、「山本さんに権限をもらう」がどのサイトの話か特定できず聞き直しになったのが再発防止のきっかけ）。

# 進捗ログ

ユーザーが指示するたびに、日付＋一言ログをこの下に追記していく（履歴として残す。上書きしない）。

- 2026-07-15: プロジェクトの複製・ブランチ運用・「マージして」で動く自動PR作成の仕組みを構築。CLAUDE.mdを作成し、次にこのリポジトリを開くClaudeが仕組みとプロジェクト概要を把握できるようにした。
- 2026-07-15: `feature/matching-tweak`ブランチでCLAUDE.mdをcommit→push→PR化（PR #1, https://github.com/yamamoto0728/-/pull/1 ）。ユーザーはこのリポジトリにwrite権限あり、マージボタンは押せることを確認済み。PRはまだ未マージ。
- 2026-07-15: `.claude/settings.json`を新規作成。開発系操作（ファイル編集・npm/pipインストール・lint/test・gitの読み取り系とadd/commit・ghの読み取り系）は自動承認、削除・push・PR作成/マージ・DB破壊系操作は`ask`のまま残す方針で設定。「アプリを起動してブラウザで確認する」操作（runスキル、ローカルサーバー起動）も自動承認に追加。ただし「Bashコマンド全体を無条件で自動承認」は、削除・push・DB操作などのask設定を素通りしてしまうリスクがあるため見送った。設定変更後もセッション内でプロンプトが出続けたため、IDE（Cursor）再起動で設定を読み直す必要がある可能性が高い。
- 2026-07-15: 「リンクに入った人の情報を記憶する」機能を実装。既存の匿名認証（supabase-jsのデフォルトlocalStorage永続化）自体は同一ブラウザなら`myId`を再利用できていたが、`profiles`テーブルから過去のプロフィールを読み戻す処理がなく、毎回オンボーディング画面が出ていたのが原因。`tryResumeSession()`を追加し、boot時に`myId`で`profiles`を検索、既存プロフィールがあればオンボーディングをスキップして`near`画面に直行するようにした（index.html）。制約として、匿名認証はブラウザのlocalStorageに紐づくため「同一端末・同一ブラウザ」でのみ記憶が有効（別端末では非対応、ユーザー確認済みでこの範囲でOKとの合意）。この環境にNode/Python/ブラウザ自動化ツールが無く実機でのブラウザ動作確認はできておらず、コードレビューのみで実装。ユーザー側での手動確認待ち。
- 2026-07-15: マッチ時にスマホへプッシュ通知を送る機能を追加（PWA化）。Web Push API + manifest.json/sw.jsでPWA化し、マッチ確定時にSupabase Edge Function `send-match-push` を呼んで購読済み端末に通知する仕組み（`supabase/functions/send-match-push/index.ts`, `supabase/push_subscriptions.sql`）。Supabase側（テーブル・Edge Function・VAPID鍵）は山本さんがダッシュボードで設定済み。その後、通知が実際に届いているか怪しかったため、`notifyMatchPush`の呼び出し結果をtoast/alertで可視化するデバッグ表示を追加（原因調査中、未解決）。
- 2026-07-16: プッシュ通知が届かない原因調査を進めるには、あお自身がSupabaseダッシュボード（プロジェクト参照: `rosgvnxqcuyenlipakck`）でEdge Functionsのログやsecretsを見られる権限が必要と判明。山本さんにSupabase組織のメンバー招待（Developerロール、blue.aochan03@gmail.com宛）を依頼することにした。招待待ち、権限が付与され次第デバッグ再開。
- 2026-07-16: 招待が通り、あおが初めてSupabase SQL Editor/Edge Functionsを操作。Edge Function `send-match-push`とVAPID Secretsが実際には未設定だったことが判明し、両方セットアップし直した（PR #3, https://github.com/yamamoto0728/-/pull/3 、マージ済み）。それでも通知が届かず調査を継続、`push_subscriptions`へのinsertがRLSポリシー違反で失敗していることが判明（PR #4, #5, https://github.com/yamamoto0728/-/pull/4 , https://github.com/yamamoto0728/-/pull/5 、マージ済み）。`myId`と`auth.uid()`は一致・ポリシー定義自体も正しいことを確認済みだが、根本原因は未特定のまま時間切れ。詳細は上の「引継ぎノート」参照。
- 2026-07-24: RLSエラーの根本原因を特定。SQL Editorでの検証（ポリシー同一・トリガー無し・なりすまし`auth.uid()`でのINSERT成功）でDB側は正常と確認し、アプリ側にデバッグ追加（`feature/push-debug3`、マージ済み）。結果`sub==myId? true`・`profiles書込テスト=OK`なのにpushだけ403 → **push_subscriptionsにSELECTポリシーが無く、PostgREST経由の`.upsert()`がRLSで弾かれていた**のが原因と判明。修正はSELECTポリシー追加（`create policy ... for select using (auth.uid()=id)`）。あおの実機テストでの最終確認待ちで中断。詳細は上の「引継ぎノート」参照。
- 2026-08-02: あおがSupabase SQL EditorでSELECTポリシーを追加し、通知トグルONが成功することを実機確認（RLS問題は解決確定）。mainが山本さんの新機能（マッチ24h無効化・地図縮小・コミュ情報表示）で進んでいたため取り込んだ上で、`feature/like-push-notify`ブランチを作成。`supabase/push_subscriptions.sql`にSELECTポリシーを記録として追記、デバッグ用alert表示を撤去して`notifyMatchPush`を汎用の`notifyPush(uid,title,body)`に整理、**片想いいいね時にも相手へプッシュ通知を送る新機能**を追加（送信者名は伏せる設計）。あおの実機確認・マージ指示待ち。
