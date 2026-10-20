-- ⏰ ちかくタイムを「毎週 月・水・木の13:00（昼休み）」に固定する（2026-10-20 あおの決定「平日の人を増やす：毎日同じ時間の学食タイム」）
-- Supabase の SQL Editor で、全部をそのまま1回実行してください。何度実行しても同じ結果になります。
-- 先に Edge Function「tama-remind」を、このリポジトリの supabase/functions/tama-remind/index.ts で更新（Deploy）しておくこと
-- （ちかくタイムの日は、12:55 の「今日のお題」の通知を送らず、13:00 のちかくタイムの通知1通にまとめるため）。
--
-- 前は「週に2〜3日・5つの候補の時刻からランダム」（いつ来るか分からない）だった。
-- 決まった曜日・時刻にすると「月水木の13:00は学食で開く」が習慣になり、同じ時間に人が集まる（多摩祭で、時刻が決まったちかくタイムに人が集まった）。

-- ---------------------------------------------------------------------------
-- 1. 予定の作り方を変える（その週の月・水・木の13:00。もう過ぎた日は作らない）
-- ---------------------------------------------------------------------------
create or replace function public.tama_ct_plan()
returns int language plpgsql security definer set search_path = public as $$
declare
  v_today date := (now() at time zone 'Asia/Tokyo')::date;
  v_mon   date := date_trunc('week', (now() at time zone 'Asia/Tokyo'))::date;
  v_made  int := 0;
  d       date;
  v_at    timestamptz;
  qq      record;
begin
  -- 月（+0）・水（+2）・木（+3）
  foreach d in array array[v_mon, v_mon + 2, v_mon + 3] loop
    continue when d < v_today;
    v_at := (d + time '13:00')::timestamp at time zone 'Asia/Tokyo';
    continue when v_at <= now() + interval '5 minutes';
    continue when exists (select 1 from public.tama_ct_slots where starts_at = v_at);
    select * into qq from public.tama_ct_questions order by used_at nulls first, random() limit 1;
    continue when qq is null;
    insert into public.tama_ct_slots (starts_at, q, o1, o2) values (v_at, qq.q, qq.o1, qq.o2) on conflict (starts_at) do nothing;
    update public.tama_ct_questions set used_at = now() where id = qq.id;
    v_made := v_made + 1;
  end loop;
  return v_made;
end $$;
revoke all on function public.tama_ct_plan() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. 今週の、まだ送っていないランダムの予定を消して、作り直す
-- ---------------------------------------------------------------------------
-- 消すのは「これから先で、まだ送っていない」平日の分だけ（多摩祭の分・送った分の記録は残す）
delete from public.tama_ct_slots
 where sent_at is null and starts_at > now()
   and extract(isodow from starts_at at time zone 'Asia/Tokyo') between 1 and 5
   and (starts_at at time zone 'Asia/Tokyo')::time <> time '13:00';
select public.tama_ct_plan() as 今週作ったちかくタイム;

-- ---------------------------------------------------------------------------
-- 3. 通知を呼ぶ時刻（cron）：前の5つ（11:00・13:10・13:25・15:20・17:10）をやめて、月・水・木の13:00 だけに
-- ---------------------------------------------------------------------------
do $$
declare
  n text;
  anon text := 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InJvc2d2bnhxY3V5ZW5saXBha2NrIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODMyNTQ5MDEsImV4cCI6MjA5ODgzMDkwMX0.SrEjGpoZUe6yfOMnQ-g6Cb-cBUg4L8AIElJ5e8UFXyg';
begin
  foreach n in array array['tama-ct-1100','tama-ct-1310','tama-ct-1325','tama-ct-1520','tama-ct-1710','tama-ct-1300'] loop
    if exists (select 1 from cron.job where jobname = n) then perform cron.unschedule(n); end if;
  end loop;
  perform cron.schedule('tama-ct-1300', '0 4 * * 1,3,4', format(   -- 世界標準時 4:00 ＝ 日本時間 13:00（月・水・木）
    $cmd$select net.http_post(
      url     := 'https://rosgvnxqcuyenlipakck.supabase.co/functions/v1/tama-remind',
      headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer %s'),
      body    := '{"kind":"ct"}'::jsonb
    )$cmd$, anon));
end $$;

-- 確認：これからのちかくタイム（今週の水・木の13:00 が出れば成功）と、通知の時刻
select starts_at at time zone 'Asia/Tokyo' as 日本時間, q as お題 from public.tama_ct_slots where starts_at > now() order by starts_at;
select jobname, schedule from cron.job where jobname like 'tama-ct-%' order by jobname;
