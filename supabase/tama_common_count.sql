-- Supabase の SQL Editor でこのファイルの内容をそのまま実行してください（2026-10-09）。
-- ⚠️ 先に supabase/tama_community.sql（tama_norm）を実行済みであること（2026-10-08 に実行済み）。
-- 何度実行しても同じ結果になるように書いてあります（再実行しても壊れません）。
-- 実行しなくてもアプリは今まで通り動く（「あなたと共通点がある人 ◯人」が出ないだけ）。
--
-- あおの依頼「アプリを入れた人が、何をするアプリで、どんな良さがあるかが分かるように」。
-- 近くにだれもいない時でも良さが伝わるよう、ちかくに登録している人のうち、自分と共通点がある人の「数だけ」を返す。
-- だれなのか（名前・id・位置）は返さない。
--   cls：時間割の授業名（どの曜日・時限でも）か「これだけは落としたくない授業」が同じ
--   art：よく聴くアーティストが同じ
--   aru：あるあるが1つでも同じ
--   total：上のどれかが同じ人（重ならないように数える）
create or replace function public.tama_common_count()
returns jsonb language sql stable security definer set search_path = public as $$
  with me as (
    select coalesce(p.fes_attrs, '{}'::jsonb) as fa from public.tama_profiles p where p.id::text = auth.uid()::text
  ), my_cls as (
    select public.tama_norm(s.value) as k from public.tama_timetable t
      cross join lateral jsonb_each_text(case when jsonb_typeof(t.slots) = 'object' then t.slots else '{}'::jsonb end) s
     where t.id::text = auth.uid()::text and public.tama_norm(s.value) <> ''
    union select public.tama_norm(fa->>'course') from me where public.tama_norm(fa->>'course') <> ''
  ), other_cls as (
    select t.id::text as id, public.tama_norm(s.value) as k from public.tama_timetable t
      cross join lateral jsonb_each_text(case when jsonb_typeof(t.slots) = 'object' then t.slots else '{}'::jsonb end) s
    union all
    select p.id::text, public.tama_norm(p.fes_attrs->>'course') from public.tama_profiles p
  ), o as (
    select p.id::text as id,
           exists (select 1 from other_cls c where c.id = p.id::text and c.k <> '' and c.k in (select k from my_cls)) as cls,
           (public.tama_norm(p.fes_attrs->>'artist') <> '' and public.tama_norm(p.fes_attrs->>'artist') = (select public.tama_norm(fa->>'artist') from me)) as art,
           exists (select 1 from jsonb_array_elements_text(case when jsonb_typeof(p.fes_attrs->'aruaru') = 'array' then p.fes_attrs->'aruaru' else '[]'::jsonb end) a
                    where (select coalesce(fa->'aruaru', '[]'::jsonb) from me) ? a) as aru
      from public.tama_profiles p
     where p.id::text <> coalesce(auth.uid()::text, '')
  )
  select jsonb_build_object(
    'cls',   (select count(*) from o where cls),
    'art',   (select count(*) from o where coalesce(art, false)),
    'aru',   (select count(*) from o where aru),
    'total', (select count(*) from o where cls or coalesce(art, false) or aru)
  );
$$;

revoke all on function public.tama_common_count() from public, anon;
grant execute on function public.tama_common_count() to authenticated;

notify pgrst, 'reload schema';

-- 確認：関数が1行出ればOK
select proname from pg_proc where proname = 'tama_common_count';
