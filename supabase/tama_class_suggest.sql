-- Supabase の SQL Editor でこのファイルの内容をそのまま実行してください（2026-10-08）。
-- ⚠️ 先に supabase/tama_community.sql を実行済みであること（2026-10-08 に実行済み）。
-- 何度実行しても同じ結果になるように書いてあります（再実行しても壊れません）。
-- 実行しなくてもアプリは今まで通り動く（授業で絞った部屋に入れない・入力の候補が出ないだけ）。
--
-- 1. コミュニティの「共通点のある人だけ」に、時間割の授業（同じ曜日・時限に同じ授業名）を条件として足す
--    条件の形：{k:'cls', v:'マーケティング論', slot:'2-2', label:'同じ授業「火2 マーケティング論」'}
-- 2. アーティスト・取りたい科目・時間割の授業名の入力に出す候補（だれかが一度でも入れたもの。多い順）

-- ---------------------------------------------------------------------------
-- 1. 授業の条件
-- ---------------------------------------------------------------------------
-- 自分のプロフィールの属性に、時間割（_tt）を足して返す
create or replace function public.tama_my_fa()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce((select p.fes_attrs from public.tama_profiles p where p.id::text = auth.uid()::text), '{}'::jsonb)
      || jsonb_build_object('_tt', coalesce((select t.slots from public.tama_timetable t where t.id::text = auth.uid()::text), '{}'::jsonb));
$$;

create or replace function public.tama_room_fits(p_cond jsonb, p_fa jsonb)
returns boolean language sql immutable as $$
  select coalesce(jsonb_array_length(p_cond), 0) = 0 or exists (
    select 1 from jsonb_array_elements(p_cond) c
     where (c->>'k' = 'aru'   and coalesce(p_fa->'aruaru',   '[]'::jsonb) ? (c->>'v'))
        or (c->>'k' = 'pur'   and coalesce(p_fa->'purposes', '[]'::jsonb) ? (c->>'v'))
        or (c->>'k' = 'goal'  and coalesce(p_fa->'goals',    '[]'::jsonb) ? (c->>'v'))
        or (c->>'k' = 'fac'   and p_fa->>'faculty' = c->>'v')
        or (c->>'k' = 'grade' and p_fa->>'grade'   = c->>'v')
        or (c->>'k' = 'art'   and public.tama_norm(p_fa->>'artist') <> '' and public.tama_norm(p_fa->>'artist') = public.tama_norm(c->>'v'))
        or (c->>'k' = 'cls'   and exists (
              select 1 from jsonb_each_text(case when jsonb_typeof(p_fa->'_tt') = 'object' then p_fa->'_tt' else '{}'::jsonb end) s
               where s.key = c->>'slot' and public.tama_norm(s.value) <> '' and public.tama_norm(s.value) = public.tama_norm(c->>'v')))
  );
$$;

-- ---------------------------------------------------------------------------
-- 2. 入力の候補
-- ---------------------------------------------------------------------------
-- {artist:[...], course:[...]}。course は「取りたい科目」と時間割の授業名を合わせたもの。
-- 書き方のゆれ（空白・全角半角・大文字小文字）はまとめて、いちばん多い書き方を出す。名前だけで、だれが入れたかは返さない
create or replace function public.tama_suggest()
returns jsonb language sql stable security definer set search_path = public as $$
  with a as (
    select 'artist' as kind, trim(p.fes_attrs->>'artist') as v from public.tama_profiles p
    union all
    select 'course', trim(p.fes_attrs->>'course') from public.tama_profiles p
    union all
    select 'course', trim(s.value) from public.tama_timetable t
      cross join lateral jsonb_each_text(case when jsonb_typeof(t.slots) = 'object' then t.slots else '{}'::jsonb end) s
  ), g as (
    select kind, public.tama_norm(v) as k, mode() within group (order by v) as v, count(*) as n
      from a
     where coalesce(v, '') <> '' and length(v) <= 40 and public.tama_norm(v) <> ''
     group by kind, public.tama_norm(v)
  )
  select jsonb_build_object(
    'artist', coalesce((select jsonb_agg(x.v order by x.n desc, x.v) from (select v, n from g where kind = 'artist' order by n desc, v limit 300) x), '[]'::jsonb),
    'course', coalesce((select jsonb_agg(x.v order by x.n desc, x.v) from (select v, n from g where kind = 'course' order by n desc, v limit 400) x), '[]'::jsonb)
  );
$$;

revoke all on function public.tama_suggest() from public, anon;
grant execute on function public.tama_suggest() to authenticated;

notify pgrst, 'reload schema';

-- 確認：artist と course の候補の数が出ればOK（まだだれも入れていなければ 0）
select jsonb_array_length(s->'artist') as アーティストの候補, jsonb_array_length(s->'course') as 授業の候補
  from (select public.tama_suggest() as s) x;
