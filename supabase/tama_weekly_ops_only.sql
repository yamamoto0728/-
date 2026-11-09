-- Supabase の SQL Editor でこのファイルの内容をそのまま実行してください（2026-11-10）。
-- 今週のイベントを「運営が出すテーマだけ」にする（みんなの提案・票をやめる）。何度実行しても壊れません。
-- 中身は supabase/tama_weekly.sql の 3 と 4 の一部と同じ（tama_weekly.sql は直してあるので、あとで丸ごと実行しても同じになる）。
-- 前の提案・票の記録は消さない（表に残るだけで、画面には出ない）

create or replace function public.tama_wk_state()
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  w  date := public.tama_wk_week();
  r  jsonb;
begin
  if me is null then return null; end if;
  select jsonb_build_object(
    'week', w,
    'need', 5,
    'themes', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', t.id, 'title', t.title, 'kind', t.kind, 'source', t.source,
               'mine', (select a.opt_id from public.tama_wk_answers a where a.theme_id = t.id and a.user_id = me),
               'opts', coalesce((
                 select jsonb_agg(jsonb_build_object(
                          'id', o.id, 'label', o.label, 'own', o.created_by = me, 'user', o.created_by is not null,
                          'n', (select count(*) from public.tama_wk_answers a where a.opt_id = o.id),
                          'room', (select wr.room_id from public.tama_wk_rooms wr where wr.opt_id = o.id))
                        order by (select count(*) from public.tama_wk_answers a where a.opt_id = o.id) desc, o.id)
                   from public.tama_wk_opts o where o.theme_id = t.id and not o.hidden), '[]'::jsonb))
             order by t.source, t.id)
        from public.tama_wk_themes t where t.week = w and t.status = 'active' and t.source = 'ops'), '[]'::jsonb),
    'next', '[]'::jsonb   -- 来週のテーマの提案・票はやめた（2026-11-10）
  ) into r;
  return r;
end $$;

-- 来週のテーマの提案・票（2026-11-10 にやめた。前の版のアプリから呼ばれても、何も入れずに 'closed' を返す）
create or replace function public.tama_wk_propose(p_title text)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('status', 'closed')
$$;
create or replace function public.tama_wk_vote(p_theme bigint)
returns boolean language sql stable security definer set search_path = public as $$
  select false
$$;

revoke all on function public.tama_wk_state(), public.tama_wk_propose(text), public.tama_wk_vote(bigint) from public, anon;
grant execute on function public.tama_wk_state(), public.tama_wk_propose(text), public.tama_wk_vote(bigint) to authenticated;

-- 確かめ：運営のテーマだけが出る（ログインしていないので、ここでは null が正しい）
select public.tama_wk_state() as state_without_login, public.tama_wk_propose('test') as propose;
