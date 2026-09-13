-- Supabase の SQL Editor でこのファイルの内容をそのまま実行してください。
-- 学園祭版の「閉じている間の通知」に必要なテーブルと、1分ごとの自動実行を作ります。通常版のテーブルには一切触りません。
-- 何度実行しても同じ結果になるように書いてあります（再実行しても壊れません）。
--
-- ⚠️ 先に Edge Function "fes-broadcast"（supabase/functions/fes-broadcast/index.ts）をデプロイしてから実行すること。
--    （先に実行しても壊れはしないが、デプロイされるまで1分ごとの呼び出しが失敗し続ける）

-- ---------------------------------------------------------------------------
-- 1. 「近くに共通点のある人がいます」通知の送信記録
-- ---------------------------------------------------------------------------
-- 閉じた人への通知は、アプリを開いている複数の端末から送られうる。
-- 同じ人に何度も届かないよう、ここに記録して「30分に1回まで」を全端末で共有する。
-- 送った人（sender）は記録しない。誰が誰の近くにいたかが読めてしまうため。
create table if not exists public.fes_push_log (
  id           bigint generated always as identity primary key,
  recipient_id uuid        not null,
  kind         text        not null default 'nearby',
  created_at   timestamptz not null default now()
);
create index if not exists fes_push_log_recipient_idx on public.fes_push_log (recipient_id, created_at desc);

alter table public.fes_push_log enable row level security;

-- ⚠️ SELECTポリシーは必須（直近に送ったかどうかをアプリが確認するため）
drop policy if exists "read push log" on public.fes_push_log;
create policy "read push log"
  on public.fes_push_log for select
  using (true);

drop policy if exists "insert push log" on public.fes_push_log;
create policy "insert push log"
  on public.fes_push_log for insert
  to authenticated
  with check (true);

-- ---------------------------------------------------------------------------
-- 2. 時間で全員に送る通知
-- ---------------------------------------------------------------------------
-- 運営が SQL Editor で登録する。ポリシーを作らない＝アプリからは読めも書けもしない
-- （Edge Function が service role で読んで送る）。
create table if not exists public.fes_scheduled_pushes (
  id         bigint generated always as identity primary key,
  send_at    timestamptz not null,               -- 送る時刻
  title      text        not null,               -- 通知のタイトル
  body       text        not null,               -- 通知の本文
  url        text        not null default '/fes/',
  sent_at    timestamptz,                        -- 送った時刻（Edge Function が入れる）
  sent_count integer,                            -- 実際に届けた端末数
  created_at timestamptz not null default now()
);

alter table public.fes_scheduled_pushes enable row level security;

-- ---------------------------------------------------------------------------
-- 3. 1分ごとに Edge Function "fes-broadcast" を呼ぶ
-- ---------------------------------------------------------------------------
create extension if not exists pg_cron;
create extension if not exists pg_net;

do $$
begin
  if exists (select 1 from cron.job where jobname = 'fes-broadcast') then
    perform cron.unschedule('fes-broadcast');
  end if;
end $$;

-- Authorization の値は index.html にも書かれている公開用の anon キー（秘密の鍵ではない）
select cron.schedule(
  'fes-broadcast',
  '* * * * *',
  $cron$
  select net.http_post(
    url     := 'https://rosgvnxqcuyenlipakck.supabase.co/functions/v1/fes-broadcast',
    headers := jsonb_build_object(
      'Content-Type',  'application/json',
      'Authorization', 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InJvc2d2bnhxY3V5ZW5saXBha2NrIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODMyNTQ5MDEsImV4cCI6MjA5ODgzMDkwMX0.SrEjGpoZUe6yfOMnQ-g6Cb-cBUg4L8AIElJ5e8UFXyg'
    ),
    body    := '{}'::jsonb
  )
  $cron$
);

notify pgrst, 'reload schema';

-- 確認: fes-broadcast が active = true で1行出ればOK
select jobname, schedule, active from cron.job where jobname = 'fes-broadcast';

-- ---------------------------------------------------------------------------
-- 通知の登録のしかた（登録するときだけコメントを外して実行）
-- ---------------------------------------------------------------------------
-- 時刻は末尾に +09 を付けて日本時間で書く。送る時刻を過ぎると1分以内に送られる。
--
-- insert into public.fes_scheduled_pushes (send_at, title, body) values
--   ('2026-10-31 13:00:00+09', '14:00からステージで○○',           'メインステージに集まろう！'),
--   ('2026-10-31 16:30:00+09', 'まもなく終了です',                   'あと30分で終了です。アンケートにご協力ください');
--
-- 登録を確認する（sent_at が入っていれば送信済み）:
--   select id, send_at, title, sent_at, sent_count from public.fes_scheduled_pushes order by send_at;
-- 送る前の通知を取り消す:
--   delete from public.fes_scheduled_pushes where id = 1 and sent_at is null;
-- 学園祭が終わったら自動実行を止める:
--   select cron.unschedule('fes-broadcast');
