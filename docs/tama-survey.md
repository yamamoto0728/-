# アンケートに答えると特典（多摩キャン版）の準備

2026-10-05 に決めたこと:

- アンケート（Googleフォーム）に答えるまで、**自分から送るいいねは1日3回まで**（`FES.likeLimitFree`）。届いたいいねに返す・24時間が過ぎたトークを始め直すのは数えない（相手を待たせないため）
- 答えると、いいねの上限がなくなり、**限定アイコン10種**（`EMO_SP`）と**バッジ「🎖 ちかく協力隊」**がもらえる。バッジはほかの人のプロフィール・一覧にも出る
- 答えたかどうかは、フォームの **Apps Script が自動で** Supabase に知らせる
- 多摩キャン版（`/tama/`）だけ。学園祭版には入れていない
- **アンケートは10/5から出している**（限定アイコン・バッジは答えたらすぐもらえる）。**いいねの上限だけ10/14（水）0時から**（`FES.likeLimitStart`）。それまではマイページに「10/14から、答えていない人は1日3回まで」と予告を出す
- 下の手順1〜4は 2026-10-05 にあおと実施済み（SQL実行・フォーム作成・事前入力URL・Apps Script の setup と test で `200 true`）
- **フォームのURLが空の間と、下の手順1のSQLを実行する前は、10/14を過ぎても上限はかからない**（答えようがないため）。始まらなかった時はまずここを疑う

## 手順

### 1. Supabase で SQL を実行する

`supabase/tama_survey.sql` の中身をそのまま SQL Editor に貼って実行する。最後に出る **`secret`（合言葉）を控える**（ほかの人に見せない）。

### 2. フォームに「参加者番号」の質問を作る

- 記述式（短文）で、タイトルを **`参加者番号`** にする（Apps Script がこのタイトルで探す。違う名前にしたら下の `QUESTION` も直す）
- 説明に「変更しないでください（アプリから自動で入ります）」と書いておく
- 「回答を1回に制限する」はオフのまま（Googleへのログインが必要になり、答える人が減る）
- 送信後のメッセージ: 「回答ありがとうございます！アプリに戻ると特典が使えるようになります」

### 3. 事前入力のURLを作って、アプリに入れる

1. フォームの編集画面の︙ ▶「事前入力したURLを取得」
2. 参加者番号の欄に `XXXX` と入れて「リンクを取得」→ コピー
3. URLの中の `XXXX` を `{id}` に置き換える
4. `tama/index.html` の `FES.surveyUrl` に入れる（アプリが `{id}` を参加者番号に置き換えて開く）

### 4. フォームに Apps Script を付ける

フォームの編集画面の︙ ▶「スクリプト エディタ」を開き、中身を全部消して下を貼る。`SECRET` に手順1の合言葉を入れる。

```js
// フォームが送信されたら、参加者番号を「ちかく」に知らせる（多摩キャン版のアンケートの特典）
const SUPABASE_URL = 'https://rosgvnxqcuyenlipakck.supabase.co';
const ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InJvc2d2bnhxY3V5ZW5saXBha2NrIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODMyNTQ5MDEsImV4cCI6MjA5ODgzMDkwMX0.SrEjGpoZUe6yfOMnQ-g6Cb-cBUg4L8AIElJ5e8UFXyg';
const SECRET = 'ここに合言葉';
const QUESTION = '参加者番号';

function onSubmit(e) {
  const item = e.response.getItemResponses().find(r => r.getItem().getTitle().trim() === QUESTION);
  if (!item) { console.warn('「' + QUESTION + '」の質問が見つかりません'); return; }
  send(String(item.getResponse() || ''));
}

function send(no) {
  const res = UrlFetchApp.fetch(SUPABASE_URL + '/rest/v1/rpc/tama_survey_mark', {
    method: 'post', contentType: 'application/json', muteHttpExceptions: true,
    headers: { apikey: ANON_KEY, Authorization: 'Bearer ' + ANON_KEY },
    payload: JSON.stringify({ p_no: no.trim(), p_secret: SECRET }),
  });
  console.log(no, res.getResponseCode(), res.getContentText());   // true なら記録できた
}

// 最初に1回だけ実行する（送信のたびに onSubmit が動くようにする）
function setup() {
  ScriptApp.getProjectTriggers().forEach(t => ScriptApp.deleteTrigger(t));
  ScriptApp.newTrigger('onSubmit').forForm(FormApp.getActiveForm()).onFormSubmit().create();
}

// 動作確認用：実行ログに「200 true」と出ればOK（試しの番号 00000000 が記録される）
function test() { send('00000000'); }
```

1. 上の関数の選択で **`setup`** を選んで ▶ 実行 → Googleの許可画面で「許可」（「安全ではないページ」と出たら「詳細」▶「（プロジェクト名）に移動」）
2. **`test`** を実行して、実行ログに `200 true` と出るのを確かめる（`false` なら合言葉の貼り間違い）
3. 自分のスマホでアプリのマイページ ▶「📝 アンケートに答える」から実際に回答 → アプリに戻ると「🎉 アンケートありがとうございます！」が出る

⚠️ スクリプトは**フォームの持ち主（か編集者）のGoogleアカウント**で動く。フォームを別のアカウントにコピーし直したら、手順4をやり直す。

## うまくいかない時

- アプリに戻っても変わらない → マイページの「答えたのに変わらない時 ›」を押す。それでもだめなら、スクリプトエディタの「実行数」で `onSubmit` のログを見る
- 参加者番号の欄が空・書き換えられた → その人は自動では解放されない。番号はマイページの一番下に出ているので、`select public.tama_survey_mark('番号', '合言葉');` を SQL Editor で実行すれば手で解放できる
- 上限を変える・やめる → `FES.likeLimitFree`（0で上限なし）

## 研究データとして

- いいねの行（`tama_likes.matched`）に、自分から送ったものは `init: true` が付く（10/5から）
- 回答した人数・番号は `tama_survey_done`。フォームの回答とは参加者番号で突き合わせられる
- 上限があるので、**アンケートに答えた人と答えていない人で、いいねの数を比べる時は注意**（答えていない人は1日3回で頭打ち）
