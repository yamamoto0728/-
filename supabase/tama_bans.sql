-- Supabase の SQL Editor でこのファイルの内容をそのまま実行してください（2026-11-01）。
-- ⚠️ 先に supabase/tama_class_community.sql（運営の名簿 tama_admins・tama_is_admin）を実行済みであること。
-- 何度実行しても同じ結果になるように書いてあります（再実行しても壊れません）。
-- 実行しなくてもアプリは動く（止める仕組みが働かないだけ）。
--
-- 2026-11-01 あお「止める仕組みを別に作って」：運営が、迷惑な人の利用を止められるようにする。
--   前は tama_profiles の行を消しても、その人のスマホに残っているプロフィールで、次に開いた時に同じIDで作り直されていた。
--
--   1. 止めた人の名簿（tama_bans）と、端末の印（tama_devices・tama_ban_devices）。どれもアプリからは読めない
--   2. 止めた人は、ほかの人に届く書きこみ（プロフィール・トーク・いいね・友達・コミュニティ・居場所など）ができない（トリガー）
--   3. アプリは開いた時に tama_ban_check を呼ぶ。止められていれば「利用を止めています」の画面だけを出す。
--      止めた端末から新しいアカウントで来た時は、そのアカウントも止める
--   4. 止める・戻す：運営（tama_admins）がアプリの通報の画面から、または この SQL Editor で tama_ban / tama_unban
--
--   限界：ログインが匿名なので、アプリを消して入れ直す・ブラウザのデータを消すと、端末の印も消えて別人になる。
--         確実に止めるには、Apple・Google でのログイン（要件定義書 v0.1）が要る。

-- ---------------------------------------------------------------------------
-- 1. 名簿と端末の印
-- ---------------------------------------------------------------------------
create table if not exists public.tama_bans (
  user_id    uuid primary key,
  reason     text,
  by_id      uuid,                                  -- 止めた運営（SQL Editor から止めた時は空）
  created_at timestamptz not null default now()
);
-- 端末の印：アプリが端末ごとに1回作るランダムな文字（個人の情報は入っていない）と、その端末で使われたアカウント
create table if not exists public.tama_devices (
  device    text not null,
  user_id   uuid not null,
  last_seen timestamptz not null default now(),
  primary key (device, user_id)
);
create table if not exists public.tama_ban_devices (
  device     text primary key,
  user_id    uuid,                                  -- どの人を止めた時の端末か
  created_at timestamptz not null default now()
);
-- ポリシーを作らない＝アプリからは読めない・書けない（関数の中からだけ使う）
alter table public.tama_bans        enable row level security;
alter table public.tama_devices     enable row level security;
alter table public.tama_ban_devices enable row level security;

-- ---------------------------------------------------------------------------
-- 2. 止めた人の書きこみを断る（消すのは止めない：本人が自分のデータを消せるように）
-- ---------------------------------------------------------------------------
create or replace function public.tama_ban_guard()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  -- auth.uid() が空なのは SQL Editor・定期の処理（cron）なので通す
  if auth.uid() is not null and exists (select 1 from public.tama_bans b where b.user_id = auth.uid()) then
    raise exception 'tama_banned' using errcode = '42501';
  end if;
  return new;
end $$;

do $$
declare t text;
begin
  foreach t in array array['tama_profiles','tama_messages','tama_likes','tama_friends','tama_presence','tama_loc_shares',
                           'tama_rooms','tama_room_members','tama_room_messages','tama_msg_reactions','tama_timetable_shares',
                           'tama_encounters','tama_encounter_log','tama_checkins','tama_daily_ideas','tama_friend_codes'] loop
    if to_regclass('public.' || t) is not null then
      execute format('drop trigger if exists tama_ban_guard on public.%I', t);
      execute format('create trigger tama_ban_guard before insert or update on public.%I for each row execute function public.tama_ban_guard()', t);
    end if;
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- 3. 開いた時の確認（アプリから）。返り値 {banned: true/false}
-- ---------------------------------------------------------------------------
create or replace function public.tama_ban_check(p_device text)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  d  text := left(trim(coalesce(p_device, '')), 64);
begin
  if me is null then return jsonb_build_object('banned', false); end if;
  if d <> '' then
    insert into public.tama_devices (device, user_id, last_seen) values (d, me, now())
      on conflict (device, user_id) do update set last_seen = now();
    -- 止めた端末から、新しいアカウントで来た時は、そのアカウントも止める（運営は止めない）
    if not exists (select 1 from public.tama_bans b where b.user_id = me)
       and not exists (select 1 from public.tama_admins a where a.user_id = me)
       and exists (select 1 from public.tama_ban_devices x where x.device = d) then
      insert into public.tama_bans (user_id, reason) values (me, '止めた端末からの新しいアカウント') on conflict do nothing;
    end if;
  end if;
  if not exists (select 1 from public.tama_bans b where b.user_id = me) then
    return jsonb_build_object('banned', false);
  end if;
  -- ほかの人の画面から消す（止めたあとに作り直されたプロフィールも）
  delete from public.tama_profiles where id::text = me::text;
  return jsonb_build_object('banned', true);
end $$;

-- ---------------------------------------------------------------------------
-- 4. 止める・戻す（運営か、SQL Editor）
-- ---------------------------------------------------------------------------
create or replace function public.tama_ban(p_user uuid, p_reason text default null)
returns text language plpgsql volatile security definer set search_path = public as $$
begin
  -- アプリからは運営だけ。auth.uid() が空なのは SQL Editor から実行した時
  if auth.uid() is not null and not public.tama_is_admin() then return 'denied'; end if;
  if p_user is null then return 'none'; end if;
  if p_user = auth.uid() then return 'self'; end if;
  if exists (select 1 from public.tama_admins a where a.user_id = p_user) then return 'admin'; end if;
  insert into public.tama_bans (user_id, reason, by_id) values (p_user, left(p_reason, 200), auth.uid())
    on conflict (user_id) do update set reason = coalesce(excluded.reason, public.tama_bans.reason);
  insert into public.tama_ban_devices (device, user_id)
    select device, p_user from public.tama_devices where user_id = p_user
    on conflict do nothing;
  -- ほかの人の画面から消す：プロフィール（名前・位置）・居場所・位置の見せ合い・コミュニティの参加
  delete from public.tama_profiles where id::text = p_user::text;
  if to_regclass('public.tama_presence')     is not null then execute 'delete from public.tama_presence where id::text = $1' using p_user::text; end if;
  if to_regclass('public.tama_loc_shares')   is not null then execute 'delete from public.tama_loc_shares where owner_id::text = $1' using p_user::text; end if;
  if to_regclass('public.tama_room_members') is not null then execute 'delete from public.tama_room_members where user_id::text = $1' using p_user::text; end if;
  return 'ok';
end $$;

create or replace function public.tama_unban(p_user uuid)
returns text language plpgsql volatile security definer set search_path = public as $$
begin
  if auth.uid() is not null and not public.tama_is_admin() then return 'denied'; end if;
  delete from public.tama_bans where user_id = p_user;
  delete from public.tama_ban_devices where user_id = p_user;
  return 'ok';   -- 戻した人は、次に学内でアプリを開いた時にプロフィールが作り直される
end $$;

revoke all on function public.tama_ban_guard() from public, anon, authenticated;
revoke all on function public.tama_ban_check(text), public.tama_ban(uuid, text), public.tama_unban(uuid) from public, anon;
grant execute on function public.tama_ban_check(text), public.tama_ban(uuid, text), public.tama_unban(uuid) to authenticated;

notify pgrst, 'reload schema';

-- 確認：関数が4つ並べばOK
select proname from pg_proc where proname in ('tama_ban_guard', 'tama_ban_check', 'tama_ban', 'tama_unban') order by proname;

-- ---------------------------------------------------------------------------
-- 運営の使い方（SQL Editor。実行するときだけコメントを外す）
-- ---------------------------------------------------------------------------
-- 名前から id を探す（同じ名前の人がいないか確かめる）：
--   select id, name, fes_attrs->>'faculty' as faculty, updated_at from tama_profiles where name = 'ここに名前';
-- 通報から探す（通報された人の id）：
--   select * from admin.reports order by created_at desc limit 20;
-- 止める：
--   select tama_ban('ここに id', '理由（運営だけが見る）');
-- 止めている人の一覧：
--   select * from tama_bans order by created_at desc;
-- 戻す：
--   select tama_unban('ここに id');
