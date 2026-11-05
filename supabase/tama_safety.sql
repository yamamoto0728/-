-- Supabase の SQL Editor でこのファイルの内容をそのまま実行してください（2026-11-05）。
-- 何度実行しても同じ結果になるように書いてあります（再実行しても壊れません）。
-- ⚠️ 先に、この SQL と同じ PR（feat/safety-1105）のアプリが本番に出ていること（Vercel のデプロイが終わってから実行する）。
--    古いアプリのまま実行しても壊れはしないが、閉じている人への「近くにいます」の通知が止まる。
--
-- あおの依頼「まだ入れてないものは入れて」（2026-11-05）の、安全の残り。
-- 11/05 に読む決まりの一覧を見て見つけた3つの穴と、審査の報告書（D:\ちかく\reports\ちかく アプリ審査と安全対策.md）の A2・A8・A9 を直す。
--   1. tama_profiles に位置を残さない（前は約100mに丸めた位置が、ログインすればだれでも全員分読めた）。
--      位置は tama_locs（アプリから読めない）にだけ置き、近くの人は tama_nearby() から受け取る（2026-11-02 から画面はそうなっている）
--   2. 通知の記録 tama_push_log を、だれも読めないようにする（前は「だれが・いつ近くの人の通知を受けたか」が読めた）。
--      「この人に最近送ったか」は、関数 tama_push_claim() が確かめて、送ってよい時だけ記録する
--   3. 招待制のコミュニティ（名前・集まる約束）は、入っている人と作った人にだけ見える
--   4. 通報：同じ相手への通報は30日に1回・1人1日10件まで（通報の悪用を防ぐ）。
--      3人から通報された人は、自動で近くの人・地図・すれ違いから一時的に隠す（運営が確かめて戻す・止める）
--   5. 回数の上限：いいね（1日100）・トーク（10分に120）・コミュニティの投稿（10分に60）
--   6. 通報が来たら運営にメールで知らせる：仕事の列 tama_jobs に積み、1分ごとに Edge Function "tama-worker" が送る
--      （メールを送るには tama-worker のデプロイと、Secrets の RESEND_API_KEY・OPS_EMAIL が要る。手順は PR）

-- ---------------------------------------------------------------------------
-- 1. tama_profiles に位置を残さない
--    tama_location_guard.sql のトリガーを置きかえる：届いた位置は tama_locs に移し（キャンパスの中だけ・3秒に1回・秒速15mまで）、
--    表の lat・lng はいつも空にする
-- ---------------------------------------------------------------------------
create or replace function public.tama_profiles_guard_loc()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  raw  boolean;
  prev record;
begin
  raw := new.lat is not null and new.lng is not null;   -- 表には位置を残さないので、届いた位置はいつも新しい位置

  if new.sharing is not true then
    delete from public.tama_locs where id = new.id::text;
  elsif raw then
    if public.tama_in_campus(new.lat, new.lng) then
      select l.lat, l.lng, l.at into prev from public.tama_locs l where l.id = new.id::text;
      if prev.at is null
         or (prev.at < now() - interval '3 seconds'
             and (prev.at < now() - interval '10 minutes'
                  or public.tama_dist_m(prev.lat, prev.lng, new.lat, new.lng)
                     <= 15 * extract(epoch from (now() - prev.at)))) then
        insert into public.tama_locs (id, lat, lng, coarse, at)
        values (new.id::text, new.lat, new.lng, coalesce(new.coarse, false), now())
        on conflict (id) do update set lat = excluded.lat, lng = excluded.lng, coarse = excluded.coarse, at = now();
      end if;
    else
      delete from public.tama_locs where id = new.id::text;
      new.sharing := false;
    end if;
  end if;

  new.lat := null;
  new.lng := null;
  return new;
end $$;
revoke all on function public.tama_profiles_guard_loc() from public, anon, authenticated;

-- 今ある丸めた位置も消す
update public.tama_profiles set lat = null, lng = null where lat is not null or lng is not null;

-- ---------------------------------------------------------------------------
-- 2. 自動で一時的に隠す人（3人から通報された人）。アプリからは読めない
--    戻す：select tama_unhide('ここに id');　止める：select tama_ban('ここに id', '理由');
-- ---------------------------------------------------------------------------
create table if not exists public.tama_hidden (
  user_id    uuid primary key,
  reason     text,
  created_at timestamptz not null default now()
);
alter table public.tama_hidden enable row level security;
revoke all on public.tama_hidden from anon, authenticated;

create or replace function public.tama_unhide(p_user uuid)
returns text language sql security definer set search_path = public as $$
  delete from public.tama_hidden where user_id = p_user returning '戻しました'
$$;
revoke all on function public.tama_unhide(uuid) from public, anon, authenticated;

-- 近くの人（tama_location_guard.sql の tama_nearby を置きかえる）：隠している人は返さない。隠されている本人にも、まわりの人を返さない
create or replace function public.tama_nearby()
returns table (uid text, glat double precision, glng double precision, near boolean)
language plpgsql stable security definer set search_path = public as $$
declare
  me text := auth.uid()::text;
  m  record;
begin
  if me is null then return; end if;
  if exists (select 1 from public.tama_bans b where b.user_id::text = me) then return; end if;
  if exists (select 1 from public.tama_hidden h where h.user_id::text = me) then return; end if;
  select l.lat, l.lng into m from public.tama_locs l where l.id = me and l.at > now() - interval '10 minutes';
  if not found then return; end if;
  return query
    select l.id,
           case when l.coarse then round(l.lat::numeric, 3)::double precision else round(l.lat / 0.00027) * 0.00027 end,
           case when l.coarse then round(l.lng::numeric, 3)::double precision else round(l.lng / 0.00033) * 0.00033 end,
           public.tama_dist_m(m.lat, m.lng, l.lat, l.lng) <= 50
      from public.tama_locs l
      join public.tama_profiles p on p.id::text = l.id and p.sharing is true
     where l.id <> me
       and l.at > now() - interval '2 hours'
       and not exists (select 1 from public.tama_blocks k
                        where (k.blocker_id::text = me and k.blocked_id::text = l.id)
                           or (k.blocker_id::text = l.id and k.blocked_id::text = me))
       and not exists (select 1 from public.tama_bans b where b.user_id::text = l.id)
       and not exists (select 1 from public.tama_hidden h where h.user_id::text = l.id);
end $$;
revoke all on function public.tama_nearby() from public, anon;
grant execute on function public.tama_nearby() to authenticated;

-- ---------------------------------------------------------------------------
-- 3. 仕事の列（通報のメール・これから作る閉じている間のすれ違いの通知）。アプリからは読めない
-- ---------------------------------------------------------------------------
create table if not exists public.tama_jobs (
  id         bigserial primary key,
  kind       text not null check (kind in ('report', 'push')),
  payload    jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  done_at    timestamptz,
  tries      int not null default 0,
  err        text
);
create index if not exists tama_jobs_todo on public.tama_jobs (created_at) where done_at is null;
alter table public.tama_jobs enable row level security;
revoke all on public.tama_jobs from anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. 通報：重複と回数の上限・3人から通報されたら隠す・運営に知らせる
--    「運営への連絡」（コミュニティの画面から送る連絡）は、通報の数に入れない
-- ---------------------------------------------------------------------------
create or replace function public.tama_reports_guard()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.reporter_id is null then return new; end if;
  if (select count(*) from public.tama_reports r
       where r.reporter_id::text = new.reporter_id::text and r.created_at > now() - interval '1 day') >= 10 then
    return null;   -- 1人1日10件まで（それより多い分は黙って受け取らない）
  end if;
  if new.target_id is not null and coalesce(new.reason, '') not like '運営への連絡%'
     and exists (select 1 from public.tama_reports r
                  where r.reporter_id::text = new.reporter_id::text and r.target_id::text = new.target_id::text
                    and coalesce(r.reason, '') not like '運営への連絡%' and r.created_at > now() - interval '30 days') then
    return null;   -- 同じ相手への通報は30日に1回
  end if;
  return new;
end $$;
drop trigger if exists tama_reports_guard on public.tama_reports;
create trigger tama_reports_guard before insert on public.tama_reports
  for each row execute function public.tama_reports_guard();

create or replace function public.tama_reports_after()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  n int := 0;
  hid boolean := false;
  contact boolean := coalesce(new.reason, '') like '運営への連絡%';
begin
  if new.target_id is not null and not contact then
    select count(distinct r.reporter_id) into n from public.tama_reports r
     where r.target_id::text = new.target_id::text and coalesce(r.reason, '') not like '運営への連絡%'
       and r.created_at > now() - interval '30 days';
    if n >= 3 then
      insert into public.tama_hidden (user_id, reason) values (new.target_id::uuid, '30日のうちに' || n || '人から通報')
      on conflict (user_id) do nothing;
      hid := true;
    end if;
  end if;
  -- 運営へのメール（中身のやりとりの写しは入れない。運営は SQL Editor の tama_admin.sql の一覧で見る）
  insert into public.tama_jobs (kind, payload) values ('report', jsonb_build_object(
    'contact', contact, 'reason', left(coalesce(new.reason, ''), 200), 'detail', left(coalesce(new.detail, ''), 500),
    'target', left(coalesce(new.target_id::text, ''), 8), 'reporter', left(coalesce(new.reporter_id::text, ''), 8),
    'count', n, 'hidden', hid));
  return null;
end $$;
drop trigger if exists tama_reports_after on public.tama_reports;
create trigger tama_reports_after after insert on public.tama_reports
  for each row execute function public.tama_reports_after();
revoke all on function public.tama_reports_guard() from public, anon, authenticated;
revoke all on function public.tama_reports_after() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 5. 回数の上限（それより多いと「too_many」で断る。ふつうに使う人には届かない数）
-- ---------------------------------------------------------------------------
create or replace function public.tama_rate_guard()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  who text; n int;
begin
  if tg_table_name = 'tama_likes' then
    who := new.from_id::text;
    select count(*) into n from public.tama_likes x where x.from_id::text = who and x.created_at > now() - interval '1 day';
    if n >= 100 then raise exception 'too_many' using hint = 'いいねは1日100回まで'; end if;
  elsif tg_table_name = 'tama_messages' then
    who := new.from_id::text;
    select count(*) into n from public.tama_messages x where x.from_id::text = who and x.created_at > now() - interval '10 minutes';
    if n >= 120 then raise exception 'too_many' using hint = 'トークは10分に120件まで'; end if;
  elsif tg_table_name = 'tama_room_messages' then
    who := new.from_id::text;
    select count(*) into n from public.tama_room_messages x where x.from_id::text = who and x.created_at > now() - interval '10 minutes';
    if n >= 60 then raise exception 'too_many' using hint = 'コミュニティの投稿は10分に60件まで'; end if;
  end if;
  return new;
end $$;
revoke all on function public.tama_rate_guard() from public, anon, authenticated;
do $$
declare t text;
begin
  foreach t in array array['tama_likes', 'tama_messages', 'tama_room_messages'] loop
    if to_regclass('public.' || t) is not null
       and exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = t and column_name = 'created_at')
       and exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = t and column_name = 'from_id') then
      execute format('drop trigger if exists tama_rate_guard on public.%I', t);
      execute format('create trigger tama_rate_guard before insert on public.%I for each row execute function public.tama_rate_guard()', t);
    end if;
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- 6. 通知の記録 tama_push_log はだれも読めないようにして、「送ってよいか」は関数で確かめる
--    返り値：true＝送ってよい（記録した）／false＝最近送った・送りすぎ・止められている
-- ---------------------------------------------------------------------------
alter table public.tama_push_log add column if not exists sender_id uuid;
create or replace function public.tama_push_claim(p_to uuid, p_kind text, p_min int default 30)
returns boolean language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  gap int := case when p_min between 1 and 1440 then p_min else 30 end;
begin
  if me is null or p_to is null or p_to = me then return false; end if;
  if p_kind is distinct from 'nearby' then return false; end if;
  if exists (select 1 from public.tama_bans b where b.user_id = me) then return false; end if;
  if exists (select 1 from public.tama_hidden h where h.user_id = me) then return false; end if;
  if exists (select 1 from public.tama_blocks k where (k.blocker_id = p_to and k.blocked_id = me) or (k.blocker_id = me and k.blocked_id = p_to)) then return false; end if;
  if exists (select 1 from public.tama_push_log l where l.recipient_id = p_to and l.kind = p_kind and l.created_at > now() - make_interval(mins => gap)) then return false; end if;
  if (select count(*) from public.tama_push_log l where l.sender_id = me and l.created_at > now() - interval '1 hour') >= 20 then return false; end if;
  insert into public.tama_push_log (recipient_id, kind, sender_id) values (p_to, p_kind, me);
  return true;
end $$;
revoke all on function public.tama_push_claim(uuid, text, int) from public, anon;
grant execute on function public.tama_push_claim(uuid, text, int) to authenticated;
do $$
declare p record;
begin
  for p in select policyname from pg_policies where schemaname = 'public' and tablename = 'tama_push_log' loop
    execute format('drop policy %I on public.tama_push_log', p.policyname);
  end loop;
end $$;
revoke all on public.tama_push_log from anon, authenticated;

-- 送った記録に「だれが送らせたか」を残す（send-match-push が書く。回数の上限に使う）
alter table public.tama_push_events add column if not exists sender_id uuid;
create index if not exists tama_push_events_sender on public.tama_push_events (sender_id, created_at) where sender_id is not null;

-- ---------------------------------------------------------------------------
-- 7. 招待制のコミュニティは、入っている人と作った人にだけ見える
-- ---------------------------------------------------------------------------
drop policy if exists "read rooms" on public.tama_rooms;
create policy "read rooms" on public.tama_rooms for select to authenticated
  using (coalesce(visibility, 'all') <> 'invite' or owner_id = auth.uid() or public.tama_room_is_member(id::text));

-- ---------------------------------------------------------------------------
-- 8. 1分ごとに tama-worker を起こす（やる仕事がある時だけ。pg_cron と pg_net がある時だけ）
--    鍵は Web のページにも入っている公開の鍵（anon）。tama-worker は列を片付けるだけなので、だれが起こしても困らない
-- ---------------------------------------------------------------------------
create extension if not exists pg_net;
do $$
begin
  if exists (select 1 from pg_namespace where nspname = 'cron') and exists (select 1 from pg_extension where extname = 'pg_net') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'tama-worker';
    perform cron.schedule('tama-worker', '* * * * *', $c$
      select net.http_post(
        url := 'https://rosgvnxqcuyenlipakck.supabase.co/functions/v1/tama-worker',
        headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InJvc2d2bnhxY3V5ZW5saXBha2NrIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODMyNTQ5MDEsImV4cCI6MjA5ODgzMDkwMX0.SrEjGpoZUe6yfOMnQ-g6Cb-cBUg4L8AIElJ5e8UFXyg'),
        body := '{}'::jsonb)
      where exists (select 1 from public.tama_jobs where done_at is null and tries < 5)
    $c$);
    -- 終わった仕事は30日で消す
    perform cron.unschedule(jobid) from cron.job where jobname = 'tama-jobs-cleanup';
    perform cron.schedule('tama-jobs-cleanup', '17 4 * * *', $c$delete from public.tama_jobs where created_at < now() - interval '30 days'$c$);
  end if;
end $$;

notify pgrst, 'reload schema';

-- ---------------------------------------------------------------------------
-- 確認：下の表が出ればOK
-- ---------------------------------------------------------------------------
select '位置が残っているプロフィール（0 なら OK）' as 項目, count(*)::text as 結果 from public.tama_profiles where lat is not null or lng is not null
union all
select 'tama_push_log を読める決まり（0 なら OK）', count(*)::text from pg_policies where schemaname = 'public' and tablename = 'tama_push_log'
union all
select '招待制の部屋の読む決まり', (select qual from pg_policies where schemaname = 'public' and tablename = 'tama_rooms' and policyname = 'read rooms')
union all
select '通報のトリガー', (select string_agg(tgname, ' / ' order by tgname) from pg_trigger where tgrelid = 'public.tama_reports'::regclass and tgname like 'tama_reports_%')
union all
select '回数の上限のトリガー', (select string_agg(c.relname, ' / ' order by c.relname) from pg_trigger t join pg_class c on c.oid = t.tgrelid where t.tgname = 'tama_rate_guard')
union all
select 'tama-worker を1分ごとに起こすか', (select count(*)::text from cron.job where jobname = 'tama-worker')
union all
select 'pg_net があるか', (exists (select 1 from pg_extension where extname = 'pg_net'))::text;
