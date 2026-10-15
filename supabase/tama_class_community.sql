-- Supabase の SQL Editor でこのファイルの内容をそのまま実行してください（2026-10-15）。
-- ⚠️ 先に supabase/tama_community.sql を実行済みであること（2026-10-08 に実行済み）。
-- 何度実行しても同じ結果になるように書いてあります（再実行しても壊れません）。
-- 実行しなくてもアプリは動く（授業のコミュニティに入れない・運営の操作が出ないだけ）。
--
-- 2026-10-15 あおの決定「コミュニティをもっと強みに」：授業のコミュニティを、オーナーのいない・いつも開いている部屋にする。
--   ・同じ授業名なら、曜日・時限が違っても1つの部屋（書き方のゆれは tama_norm でそろえる）
--   ・入れるのは、時間割にその授業を入れている人（申請・招待なしで1タップ）。部屋がまだ無ければ、最初に入る人の時に作る
--   ・オーナーはいない。運営（tama_admins に入れた人＝あお・しゅうすけさん。「影のオーナー」）が、
--     投稿を消す・退出してもらう・お知らせを出す・部屋の説明を変えることができる。ほかの人には普通の参加者に見える
--   ※ 2026-10-09 に「授業の部屋を勝手に作らない」として tama_class_rooms_undo.sql で外した仕組みを、今回の決定で戻すもの
--
--   1. 部屋の条件に「時間割のどこかに同じ授業名」（cname）
--   2. 運営の名簿（tama_admins）と、運営かどうか（tama_is_admin）
--   3. 授業のコミュニティの一覧（tama_class_rooms）と、入る（tama_class_room_join）
--   4. お知らせ（tama_rooms.notice）・説明の変更（tama_room_set_info）
--   5. 投稿を消す・退出してもらうを、運営もできるように（tama_room_delete_msg・tama_room_kick を作り直す）

-- ---------------------------------------------------------------------------
-- 1. 部屋の条件
-- ---------------------------------------------------------------------------
alter table public.tama_rooms alter column owner_id drop not null;   -- オーナーのいない部屋を作れるように

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

-- ---------------------------------------------------------------------------
-- 2. 運営の名簿（影のオーナー）
-- ---------------------------------------------------------------------------
-- 入れ方は、このファイルのいちばん下。アプリからは読めない（だれが運営かは分からない）
create table if not exists public.tama_admins (
  user_id uuid primary key,
  note    text,
  created_at timestamptz not null default now()
);
alter table public.tama_admins enable row level security;   -- ポリシーを作らない＝アプリからは読めない・書けない

-- 自分が運営かどうか（自分の分だけ分かる）
create or replace function public.tama_is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.tama_admins a where a.user_id = auth.uid());
$$;
revoke all on function public.tama_is_admin() from public, anon;
grant execute on function public.tama_is_admin() to authenticated;

-- その部屋を管理できるか（オーナーか運営）
create or replace function public.tama_room_can_mod(p_room text)
returns boolean language sql stable security definer set search_path = public as $$
  select public.tama_room_is_owner(p_room) or public.tama_is_admin();
$$;

-- ---------------------------------------------------------------------------
-- 3. 授業のコミュニティ
-- ---------------------------------------------------------------------------
-- 自分の時間割の授業ごとに：授業のコミュニティ（あれば）・部屋の人数・同じ授業を時間割に入れている人数・入っているか・新しい投稿の数
drop function if exists public.tama_class_rooms();
create or replace function public.tama_class_rooms()
returns table (name text, room_id text, members int, takers int, joined boolean, unread int, last_at timestamptz)
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
         mm.user_id is not null,
         case when mm.user_id is null then 0 else
           (select count(*)::int from public.tama_room_messages x
             where x.room_id::text = rm.id and x.from_id::text <> auth.uid()::text and x.created_at > mm.last_read_at) end,
         (select max(x.created_at) from public.tama_room_messages x where x.room_id::text = rm.id)
    from mine m
    left join lateral (select cr.id from cr where cr.k = m.k limit 1) rm on true
    left join public.tama_room_members mm on mm.room_id::text = rm.id and mm.user_id = auth.uid()
   order by m.name;
$$;

-- 授業のコミュニティに入る（無ければ作る）。返り値 {status, room}。status：'ok' / 'unfit'（時間割にその授業が無い）/ 'banned'
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
  if v_room is not null and exists (select 1 from public.tama_room_bans b where b.room_id = v_room and b.user_id = me) then
    return jsonb_build_object('status', 'banned');
  end if;
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

-- ---------------------------------------------------------------------------
-- 4. お知らせ・説明の変更
-- ---------------------------------------------------------------------------
-- お知らせは部屋のいちばん上に固定で出る（休講・テストの案内など）。空にすると消える
alter table public.tama_rooms add column if not exists notice    text;
alter table public.tama_rooms add column if not exists notice_at timestamptz;

create or replace function public.tama_room_set_notice(p_room text, p_text text)
returns text language plpgsql volatile security definer set search_path = public as $$
begin
  if not public.tama_room_can_mod(p_room) then return 'denied'; end if;
  update public.tama_rooms set notice = nullif(left(trim(coalesce(p_text, '')), 200), ''),
         notice_at = case when coalesce(trim(p_text), '') = '' then null else now() end
   where id::text = p_room;
  return 'ok';
end $$;

-- 部屋の説明（ひとこと・ルール）を変える。オーナーのいない部屋（授業のコミュニティ）は運営だけ。オーナーのいる部屋はオーナーの「編集」を使う
create or replace function public.tama_room_set_info(p_room text, p_topic text, p_rules text)
returns text language plpgsql volatile security definer set search_path = public as $$
begin
  if not public.tama_room_can_mod(p_room) then return 'denied'; end if;
  update public.tama_rooms set topic = left(coalesce(p_topic, ''), 40), rules = left(coalesce(p_rules, ''), 300) where id::text = p_room;
  return 'ok';
end $$;

revoke all on function public.tama_room_set_notice(text, text), public.tama_room_set_info(text, text, text), public.tama_room_can_mod(text) from public, anon;
grant execute on function public.tama_room_set_notice(text, text), public.tama_room_set_info(text, text, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 5. 投稿を消す・退出してもらう（オーナーか運営）
-- ---------------------------------------------------------------------------
create or replace function public.tama_room_kick(p_room text, p_user uuid, p_ban boolean default true)
returns text language plpgsql volatile security definer set search_path = public as $$
begin
  if not public.tama_room_can_mod(p_room) then return 'not_owner'; end if;
  if p_user = auth.uid() then return 'self'; end if;
  -- オーナーは退出させない（運営でも。オーナーだけが部屋からいなくなり、オーナーのまま残るため。2026-10-15 のレビュー）
  if exists (select 1 from public.tama_rooms r where r.id::text = p_room and r.owner_id = p_user) then return 'owner'; end if;
  delete from public.tama_room_members where room_id::text = p_room and user_id = p_user;
  delete from public.tama_room_rsvp where room_id = p_room and user_id = p_user;
  if p_ban then insert into public.tama_room_bans (room_id, user_id) values (p_room, p_user) on conflict do nothing; end if;
  return 'ok';
end $$;

create or replace function public.tama_room_delete_msg(p_msg text)
returns text language plpgsql volatile security definer set search_path = public as $$
declare v_room text; v_from text;
begin
  select x.room_id::text, x.from_id::text into v_room, v_from from public.tama_room_messages x where x.id::text = p_msg;
  if v_room is null then return 'gone'; end if;
  if v_from <> auth.uid()::text and not public.tama_room_can_mod(v_room) then return 'denied'; end if;
  delete from public.tama_room_messages where id::text = p_msg;
  return 'ok';
end $$;

-- ---------------------------------------------------------------------------
-- 5b. 部屋を投稿・参加者ごと消す関数（tama_room_purge。tama_community.sql）は、運営が SQL Editor で使うもの。
--     public・anon からは外してあったが、ログインした人（authenticated）からは外していなかったので、だれでもどの部屋でも消せる可能性があった（2026-10-15 のレビュー）。
--     アプリからは呼んでいない。期限切れの部屋を消す tama_room_cleanup（cron）はこの関数を中で呼ぶだけなので、影響しない
-- ---------------------------------------------------------------------------
revoke execute on function public.tama_room_purge(text) from authenticated;

-- ---------------------------------------------------------------------------
-- 6. 「運営に連絡」（授業のコミュニティの中から）。通報の表に、相手のいない行として入る（理由が「運営への連絡：…」）
--    運営は admin.reports で見る（「通報された人」は「（消えた人）」と出る）
-- ---------------------------------------------------------------------------
alter table public.tama_reports alter column target_id drop not null;

notify pgrst, 'reload schema';

-- 確認：関数が並べばOK
select proname from pg_proc where proname in ('tama_room_fits', 'tama_class_rooms', 'tama_class_room_join', 'tama_is_admin',
  'tama_room_set_notice', 'tama_room_set_info', 'tama_room_can_mod', 'tama_room_kick', 'tama_room_delete_msg') order by proname;

-- ---------------------------------------------------------------------------
-- 運営（影のオーナー）を入れる（あお・しゅうすけさん。実行するときだけ、名前を自分の登録名に直してコメントを外す）
-- ---------------------------------------------------------------------------
-- 同じ名前の人がほかにいないか、先に確かめる：
--   select id, name, updated_at from tama_profiles where name in ('あお', 'しゅうすけ');
-- 入れる（上で確かめた id を入れる）：
--   insert into tama_admins (user_id, note) values ('ここに id', 'あお'), ('ここに id', 'しゅうすけ') on conflict do nothing;
-- 外す：
--   delete from tama_admins where note = 'しゅうすけ';
