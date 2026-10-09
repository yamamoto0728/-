-- Supabase の SQL Editor でこのファイルの内容をそのまま実行してください（2026-10-09）。
-- 何度実行しても同じ結果になるように書いてあります（再実行しても壊れません）。
-- ⚠️ pg_cron を使う（supabase/tama_remind.sql で使っているので、本番では使える）。
--
-- あおの決定「終わった24時間トークは、終わって7日で自動で消す（友達とのトークは残す）。規約にも書く」。
-- 24時間トークは、マッチ（または始め直し）から24時間で終わるので、送ってから8日たったメッセージは、どれも「終わって7日以上」になる。
-- そこで、毎日1回、友達どうしでない2人のトークのうち、送ってから8日たったメッセージを消す。
--   残すもの：友達どうし（承認ずみ）のトーク／通報に付けた写し（tama_reports.evidence）
--   消えるもの：友達でない2人のトークの、8日より前のメッセージ（あとで友達をやめた2人の古いトークも、ここで消える）

create or replace function public.tama_talk_cleanup()
returns int language plpgsql volatile security definer set search_path = public as $$
declare n int;
begin
  delete from public.tama_messages m
   where m.created_at < now() - interval '8 days'
     and not exists (
       select 1 from public.tama_friends f
        where f.status = 'accepted'
          and ((f.from_id::text = split_part(m.match_key, '__', 1) and f.to_id::text = split_part(m.match_key, '__', 2))
            or (f.from_id::text = split_part(m.match_key, '__', 2) and f.to_id::text = split_part(m.match_key, '__', 1))));
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function public.tama_talk_cleanup() from public, anon, authenticated;

-- 毎日 日本時間 4:20（UTC 19:20）に動かす
do $$
begin
  if exists (select 1 from cron.job where jobname = 'tama-talk-cleanup') then
    perform cron.unschedule('tama-talk-cleanup');
  end if;
  perform cron.schedule('tama-talk-cleanup', '20 19 * * *', 'select public.tama_talk_cleanup()');
end $$;

-- 確認：tama-talk-cleanup が active = true で1行出ればOK
select jobname, schedule, active from cron.job where jobname = 'tama-talk-cleanup';

-- すぐ一度消したい時（消した件数が出る。元に戻せない）は、下の行の先頭の「-- 」を消して実行
-- select public.tama_talk_cleanup();
