-- 🔔 多摩祭の通知をマッチングに生かす（2026-10-16 あおの決定）
-- Supabase の SQL Editor で、全部をそのまま1回実行してください。何度実行しても同じ結果になります。
-- 先に Edge Function「tama-remind」を、このリポジトリの supabase/functions/tama-remind/index.ts で更新（Deploy）しておくこと。
-- （更新する前に時刻が来ても、「bad kind」で何も送られないだけ）
--
--   👀 ステージの10分前   … 「見に行く」を押した人だけ。5分ごとに、始まる5〜10分前のステージを探す（17・18日 11:00〜18:55）
--   👋 返事待ちのいいね   … 17・18日 16:00。今日届いたいいねを、まだ返していない人だけ
--   🌅 2日目の朝         … 18日 11:45。1日目にキャンパスで開いた人だけ
--   1日目の夜を1通に     … 17日 18:00 のアンケートの通知をやめ、18:30 の「今日のすれ違い」にアンケートの一言を入れる（Edge Function 側）
-- 時刻は世界標準時（日本時間から9時間引く）
do $$
declare
  j record;
  -- Authorization の値は tama/index.html にも書かれている公開用の anon キー（秘密の鍵ではない。tama_tamasai.sql と同じ）
  anon text := 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InJvc2d2bnhxY3V5ZW5saXBha2NrIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODMyNTQ5MDEsImV4cCI6MjA5ODgzMDkwMX0.SrEjGpoZUe6yfOMnQ-g6Cb-cBUg4L8AIElJ5e8UFXyg';
begin
  for j in select * from (values
    ('tama-fes-stage',   '*/5 2-9 17,18 10 *', '{"kind":"stage"}'),                                          -- 17・18日 11:00〜18:55 に5分ごと
    ('tama-fes-likes',   '0 7 17,18 10 *',     '{"kind":"likes"}'),                                          -- 17・18日 16:00
    ('tama-fes-morning', '45 2 18 10 *',       '{"kind":"morning","day":"2026-10-18","prev":"2026-10-17"}')  -- 18日 11:45
  ) as v(name, sched, body)
  loop
    if exists (select 1 from cron.job where jobname = j.name) then perform cron.unschedule(j.name); end if;
    perform cron.schedule(j.name, j.sched, format(
      $cmd$select net.http_post(
        url     := 'https://rosgvnxqcuyenlipakck.supabase.co/functions/v1/tama-remind',
        headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer %s'),
        body    := %L::jsonb
      )$cmd$, anon, j.body));
  end loop;
  -- 1日目の夜を1通に：17日 18:00 のアンケートの通知をやめる（18:30 の通知にアンケートの一言が入る）
  if exists (select 1 from cron.job where jobname = 'tama-fes-survey-0') then perform cron.unschedule('tama-fes-survey-0'); end if;
end $$;

-- 確認：多摩祭の通知の予定（11行。tama-fes-survey-0 が無く、stage・likes・morning がある）
select jobname, schedule, active from cron.job where jobname like 'tama-fes-%' order by jobname;

-- 多摩祭が終わったら（10/20 以降）、ほかの多摩祭の通知と一緒に止める（名前が tama-fes- で始まるので同じ1行で止まる）
--   select cron.unschedule(jobname) from cron.job where jobname like 'tama-fes-%';
