-- Supabase の SQL Editor でこのファイルの内容をそのまま実行してください（2026-10-08）。
-- ⚠️ 先に supabase/tama_community.sql と supabase/tama_class_suggest.sql を実行済みであること。
-- 何度実行しても同じ結果になるように書いてあります（再実行しても壊れません）。
-- 実行しなくてもアプリは動く（授業の部屋が、前の「オーナーが作る部屋」のままになるだけ）。
--
-- 授業の部屋を「オーナーなし・運営が見守る・1タップで入れる」部屋にする（ユーザー役のテストで、授業の部屋を作るのに
-- 長いフォームとオーナーの責任が要るのは「課題を聞きたいだけなのに重い」と言われたため）。
--   ・同じ授業名なら、曜日・時限が違っても1つの部屋（書き方のゆれは tama_norm でそろえる）
--   ・入れるのは、時間割にその授業名を入れている人だけ（条件 {k:'cname', v:授業名}）
--   ・部屋がまだ無ければ、最初に「入る」を押した人の時に作る（owner_id は null。期限なし）
--   ・オーナーがいないので、投稿を消せるのは書いた本人だけ。困った投稿・部屋は通報（運営が SQL Editor で tama_room_purge）

-- 0. オーナーなしの部屋を作れるように（ダッシュボードで作った表で owner_id が必須になっていても外す。もともと任意なら何も変わらない）
alter table public.tama_rooms alter column owner_id drop not null;

-- 1. 条件の判定に 'cname'（時間割のどこかに、同じ授業名がある）を足す
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
        or (c->>'k' = 'cname' and exists (
              select 1 from jsonb_each_text(case when jsonb_typeof(p_fa->'_tt') = 'object' then p_fa->'_tt' else '{}'::jsonb end) s
               where public.tama_norm(s.value) <> '' and public.tama_norm(s.value) = public.tama_norm(c->>'v')))
  );
$$;

-- 2. 自分の時間割の授業ごとに：授業の部屋（あれば）・部屋の人数・同じ授業を時間割に入れている人数
drop function if exists public.tama_class_rooms();
create or replace function public.tama_class_rooms()
returns table (name text, room_id text, members int, takers int, joined boolean)
language sql stable security definer set search_path = public as $$
  with mine as (
    select distinct on (public.tama_norm(s.value)) public.tama_norm(s.value) as k, trim(s.value) as name
      from public.tama_timetable t
      cross join lateral jsonb_each_text(case when jsonb_typeof(t.slots) = 'object' then t.slots else '{}'::jsonb end) s
     where t.id::text = auth.uid()::text and public.tama_norm(s.value) <> ''
     order by public.tama_norm(s.value), s.key
  ), cr as (
    select r.id::text as id, public.tama_norm(c->>'v') as k
      from public.tama_rooms r cross join lateral jsonb_array_elements(r.conditions) c
     where c->>'k' = 'cname' and r.owner_id is null
  )
  select m.name, rm.id,
         (select count(*)::int from public.tama_room_members x where x.room_id::text = rm.id),
         (select count(distinct t.id)::int from public.tama_timetable t
            cross join lateral jsonb_each_text(case when jsonb_typeof(t.slots) = 'object' then t.slots else '{}'::jsonb end) s
           where public.tama_norm(s.value) = m.k),
         exists (select 1 from public.tama_room_members x where x.room_id::text = rm.id and x.user_id = auth.uid())
    from mine m
    left join lateral (select cr.id from cr where cr.k = m.k limit 1) rm on true
   order by m.name;
$$;

-- 3. 授業の部屋に入る（無ければ作る）。返り値 {status, room}。status：'ok' / 'unfit'（時間割にその授業が無い）
drop function if exists public.tama_class_room_join(text);
create or replace function public.tama_class_room_join(p_name text)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  me     uuid := auth.uid();
  v_k    text := public.tama_norm(p_name);
  v_room text;
begin
  if me is null then raise exception 'not signed in'; end if;
  if v_k = '' or not public.tama_room_fits(jsonb_build_array(jsonb_build_object('k', 'cname', 'v', p_name)), public.tama_my_fa()) then
    return jsonb_build_object('status', 'unfit');
  end if;
  -- 同時に2人が押しても部屋が2つにならないよう、授業名ごとにロックする
  perform pg_advisory_xact_lock(hashtext('tama_class_room:' || v_k));
  select r.id::text into v_room from public.tama_rooms r cross join lateral jsonb_array_elements(r.conditions) c
   where c->>'k' = 'cname' and r.owner_id is null and public.tama_norm(c->>'v') = v_k limit 1;
  if v_room is null then
    insert into public.tama_rooms (name, topic, rules, visibility, conditions, capacity, expires_at, meet, owner_id)
    values (left(trim(p_name), 20), '授業のこと・課題・テスト・休講の情報交換',
            E'・授業に関係ない話はほどほどに\n・課題の答えをそのまま渡さない\n・いやな言い方をしない\n・困ったことは「運営に知らせる」から',
            'common', jsonb_build_array(jsonb_build_object('k', 'cname', 'v', trim(p_name), 'label', '同じ授業「' || trim(p_name) || '」')),
            null, null, null, null)
    returning id::text into v_room;
  end if;
  insert into public.tama_room_members (room_id, user_id, last_read_at)
  select r.id, me, now() from public.tama_rooms r where r.id::text = v_room
  on conflict do nothing;
  return jsonb_build_object('status', 'ok', 'room', v_room);
end $$;

revoke all on function public.tama_class_rooms(), public.tama_class_room_join(text) from public, anon;
grant execute on function public.tama_class_rooms(), public.tama_class_room_join(text) to authenticated;

notify pgrst, 'reload schema';

-- 確認：関数が3行出ればOK
select proname from pg_proc where proname in ('tama_room_fits', 'tama_class_rooms', 'tama_class_room_join') order by proname;
