-- Supabase の SQL Editor でこのファイルの内容をそのまま実行してください（2026-10-11）。
-- 何度実行しても同じ結果になるように書いてあります（再実行しても壊れません）。
-- ⚠️ 先に supabase/tama_retention.sql（開いた日の記録 tama_visits）を実行済みであること（2026-09-26 に実行済み）。
-- 実行しなくてもアプリは動く（多摩祭のカードに人数が出ず、目標だけ出る。🎉バッジが付かない）。
--
-- 多摩祭（2026-10-17・18）の参加人数＝その日にキャンパスでアプリを開いた人（2日の合計・同じ人は1回）。
-- アプリの「🎪 多摩祭 参加◯人／目標100人」と、目標に届いた時の🎉バッジに使う。
-- 日付はアプリ（tama/index.html の FES.tamasai.days）にも書いてある。変える時は両方。
-- 返すのは人数だけ（だれが来たかは返さない）。

create or replace function public.tama_tamasai_count()
returns int language sql stable security definer set search_path = public as $$
  select count(distinct user_id)::int from public.tama_visits
   where day in (date '2026-10-17', date '2026-10-18') and on_campus;
$$;
revoke all on function public.tama_tamasai_count() from public, anon;
grant execute on function public.tama_tamasai_count() to authenticated;

notify pgrst, 'reload schema';

-- 確認：いまの参加人数（多摩祭の前は 0）
select public.tama_tamasai_count() as 多摩祭の参加人数;

-- ---------------------------------------------------------------------------
-- 多摩祭のあとに見る数字（実行するときだけコメントを外す）
-- ---------------------------------------------------------------------------
-- 日ごとの参加人数・そのうち初めて使った人（それより前に開いた日が無い人）:
--   select v.day, count(*) as 参加,
--          count(*) filter (where not exists (select 1 from tama_visits w where w.user_id = v.user_id and w.day < v.day)) as 初めての人
--     from tama_visits v where v.day in ('2026-10-17', '2026-10-18') and v.on_campus group by v.day order by v.day;
-- 多摩祭のバッジを持っている人数:
--   select b as バッジ, count(*) from tama_profiles, jsonb_array_elements_text(coalesce(fes_attrs->'badges', '[]'::jsonb)) b
--    where b in ('fes26', 'fes26x', 'fesgoal') group by b;
