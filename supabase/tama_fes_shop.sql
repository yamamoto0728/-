-- 🏮 出店者向けの通知 と QR の画面の人数（2026-10-16 あおの依頼）
-- Supabase の SQL Editor で、全部をそのまま1回実行してください。何度実行しても同じ結果になります。
-- 先に Edge Function「tama-remind」を、このリポジトリの supabase/functions/tama-remind/index.ts で更新（Deploy）しておくこと。
-- （更新する前に通知の時刻が来ても、「bad kind」で何も送られないだけ）

-- ---------------------------------------------------------------------------
-- 1. QR から入った時の画面の人数を、多摩祭のカードの目標と同じ数にする
-- ---------------------------------------------------------------------------
-- 前は QR の画面（ログイン前）が多摩キャン版の登録者だけ、目標のバーが「ちかく」のユーザー（多摩キャン版＋通常版）で、数が合っていなかった。
-- ログイン前でも「ちかく」のユーザー数を読めるようにする（返すのは数だけ。名前・位置などは返さない）
grant execute on function public.tama_chikaku_users() to anon;
notify pgrst, 'reload schema';

-- ---------------------------------------------------------------------------
-- 2. 出店・出演している人へ「アプリで無料で宣伝しませんか？」（1日目 10/17 の 14:00 と 16:30）
-- ---------------------------------------------------------------------------
-- 送るのは「出店・出演中」をまだ選んでいない人全員（だれが出店者かはアプリから分からないので、文で呼びかける）。
-- 押すと、アプリで自分の店を選ぶ画面が開く。時刻は世界標準時（日本時間から9時間引く）
do $$
declare
  j record;
  -- Authorization の値は tama/index.html にも書かれている公開用の anon キー（秘密の鍵ではない。tama_tamasai.sql と同じ）
  anon text := 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InJvc2d2bnhxY3V5ZW5saXBha2NrIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODMyNTQ5MDEsImV4cCI6MjA5ODgzMDkwMX0.SrEjGpoZUe6yfOMnQ-g6Cb-cBUg4L8AIElJ5e8UFXyg';
begin
  for j in select * from (values
    ('tama-fes-shop-1400', '0 5 17 10 *',  '{"kind":"shop","day":"2026-10-17","slot":"1400"}'),   -- 17日 14:00（1日目の中ごろ）
    ('tama-fes-shop-1630', '30 7 17 10 *', '{"kind":"shop","day":"2026-10-17","slot":"1630"}')    -- 17日 16:30（1日目の終わりごろ）
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
end $$;

-- 確認：多摩祭の通知の予定（前からの7行＋この2行で9行）
select jobname, schedule, active from cron.job where jobname like 'tama-fes-%' order by jobname;

-- 多摩祭が終わったら（10/20 以降）、ほかの多摩祭の通知と一緒に止める（名前が tama-fes- で始まるので同じ1行で止まる）
--   select cron.unschedule(jobname) from cron.job where jobname like 'tama-fes-%';
