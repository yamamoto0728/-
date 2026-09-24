-- Supabase の SQL Editor でこのファイルの内容をそのまま実行してください。
-- 多摩キャン版の「いまどこ？を入れよう」の通知を、平日の決まった時刻に自動で送る設定を作ります。
-- 何度実行しても同じ結果になるように書いてあります（再実行しても壊れません）。
--
-- ⚠️ 先に次の2つを済ませてから実行すること
--    1. supabase/tama_timetable.sql の実行
--    2. Edge Function "tama-remind"（supabase/functions/tama-remind/index.ts）のデプロイ
--
-- 送る時刻（日本時間・月〜金。多摩キャンパスの時間割に合わせる。cron は世界標準時なので 9時間引いて書いている）
--   1限 9:20 開始 → 9:25    時間割で1限に授業がある人だけ
--   2限 11:10 開始 → 11:15  〃
--   昼休み        → 12:55   参加者全員（時間割を登録していない人にはこの1回だけ）
--   3限 13:40 開始 → 13:45  時間割で3限に授業がある人だけ
--   4限 15:30 開始 → 15:35  〃
--   5限 17:20 開始 → 17:25  〃
--   10分休みには送らない（短くて見られないため）。6・7限は多摩キャンパスに無い

create extension if not exists pg_cron;
create extension if not exists pg_net;

do $$
declare
  j record;
  -- Authorization の値は tama/index.html にも書かれている公開用の anon キー（秘密の鍵ではない）
  anon text := 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InJvc2d2bnhxY3V5ZW5saXBha2NrIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODMyNTQ5MDEsImV4cCI6MjA5ODgzMDkwMX0.SrEjGpoZUe6yfOMnQ-g6Cb-cBUg4L8AIElJ5e8UFXyg';
begin
  for j in select * from (values
    ('tama-remind-1',     '25 0 * * 1-5', '{"kind":"period","period":1}'),
    ('tama-remind-2',     '15 2 * * 1-5', '{"kind":"period","period":2}'),
    ('tama-remind-lunch', '55 3 * * 1-5', '{"kind":"lunch"}'),
    ('tama-remind-3',     '45 4 * * 1-5', '{"kind":"period","period":3}'),
    ('tama-remind-4',     '35 6 * * 1-5', '{"kind":"period","period":4}'),
    ('tama-remind-5',     '25 8 * * 1-5', '{"kind":"period","period":5}')
  ) as v(name, sched, body)
  loop
    if exists (select 1 from cron.job where jobname = j.name) then
      perform cron.unschedule(j.name);
    end if;
    perform cron.schedule(j.name, j.sched, format(
      $cmd$select net.http_post(
        url     := 'https://rosgvnxqcuyenlipakck.supabase.co/functions/v1/tama-remind',
        headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer %s'),
        body    := %L::jsonb
      )$cmd$, anon, j.body));
  end loop;
end $$;

-- 確認: tama-remind- で始まる6行が active = true で出ればOK
select jobname, schedule, active from cron.job where jobname like 'tama-remind-%' order by jobname;

-- ---------------------------------------------------------------------------
-- 止める・再開する（実行するときだけコメントを外す）
-- ---------------------------------------------------------------------------
-- 休講日・長期休みの間だけ止める:
--   select cron.alter_job(jobid, active := false) from cron.job where jobname like 'tama-remind-%';
-- 再開する:
--   select cron.alter_job(jobid, active := true)  from cron.job where jobname like 'tama-remind-%';
-- 実験が終わったら消す:
--   select cron.unschedule(jobname) from cron.job where jobname like 'tama-remind-%';
