-- Supabase の SQL Editor でこのファイルの内容をそのまま実行してください（2026-11-06）。
-- ⚠️ 先に supabase/tama_safety.sql（tama_jobs）・tama_location_guard.sql（tama_locs）・tama_appv_friends.sql（tama_loc_shares）を実行済みであること。
-- 何度実行しても同じ結果になるように書いてあります（再実行しても壊れません）。
-- 実行しなくてもアプリは動く（友達の「学内に来たら知らせる」が出ないだけ）。
--
-- 2026-11-06 あおの依頼「指定した友達がキャンパス内に入ったら通知がくる機能（あいつ今日学校いるんだ・キタキタ）」
--   ・知らせてほしい友達を、自分で選ぶ（友達のプロフィールの「学内に来たら知らせる」）。表 tama_arrive_watch
--   ・知らせるのは、その友達が「学内での居場所を見せる」を自分にオンにしている時だけ（tama_loc_shares）。
--     居場所を見せていない相手に「来た」とだけ伝わるのを防ぐ。相手がオフにすれば、知らせも止まる
--   ・その友達の位置が、その日はじめて学内に入った時（または3時間以上あいてから、また入った時）に1回だけ。1日1人1回まで（tama_arrive_sent）
--   ・ブロックしている・されている・利用停止の人には送らない。通知の種類は 'arrive'（受け取る人は「通知」の設定で切れる）
--   ・通知は tama_jobs に積み、tama-worker が send-match-push で送る（閉じている間のすれ違いの通知と同じ道）

-- 1. だれが、どの友達の「来た」を知りたいか（自分の分だけ読める・足せる・消せる）
create table if not exists public.tama_arrive_watch (
  watcher_id uuid not null,
  target_id  uuid not null,
  created_at timestamptz not null default now(),
  primary key (watcher_id, target_id),
  check (watcher_id <> target_id)
);
alter table public.tama_arrive_watch enable row level security;
revoke all on public.tama_arrive_watch from anon;
grant select, insert, delete on public.tama_arrive_watch to authenticated;

drop policy if exists tama_arrive_watch_select on public.tama_arrive_watch;
create policy tama_arrive_watch_select on public.tama_arrive_watch for select to authenticated
  using (watcher_id = auth.uid());
drop policy if exists tama_arrive_watch_insert on public.tama_arrive_watch;
create policy tama_arrive_watch_insert on public.tama_arrive_watch for insert to authenticated
  with check (watcher_id = auth.uid() and exists (
    select 1 from public.tama_friends f
     where f.status = 'accepted'
       and ((f.from_id = auth.uid() and f.to_id = target_id) or (f.to_id = auth.uid() and f.from_id = target_id))));
drop policy if exists tama_arrive_watch_delete on public.tama_arrive_watch;
create policy tama_arrive_watch_delete on public.tama_arrive_watch for delete to authenticated
  using (watcher_id = auth.uid());

-- 2. 送った記録（1日1人1回まで。アプリからは読めない）
create table if not exists public.tama_arrive_sent (
  watcher_id uuid not null,
  target_id  uuid not null,
  day        date not null,
  primary key (watcher_id, target_id, day)
);
alter table public.tama_arrive_sent enable row level security;
revoke all on public.tama_arrive_sent from anon, authenticated;

-- 3. 位置が学内に入った時に、知らせる仕事を積む
create or replace function public.tama_arrive_notify()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  t   uuid;
  nm  text;
  d   date := (now() at time zone 'Asia/Tokyo')::date;
  w   record;
begin
  -- その日はじめて（行が無かった）か、前の位置から3時間以上あいた時だけ
  if tg_op = 'UPDATE' and old.at > now() - interval '3 hours' then return new; end if;
  if not public.tama_in_campus(new.lat, new.lng) then return new; end if;
  begin t := new.id::uuid; exception when others then return new; end;
  if exists (select 1 from public.tama_bans b where b.user_id = t) then return new; end if;
  select coalesce(nullif(trim(p.name), ''), '友達') into nm from public.tama_profiles p where p.id::text = new.id;
  if nm is null then return new; end if;
  for w in
    select a.watcher_id from public.tama_arrive_watch a
     where a.target_id = t
       -- 相手（来た人）が、知りたい人に「学内での居場所を見せる」をオンにしている
       and exists (select 1 from public.tama_loc_shares s where s.owner_id = t and s.friend_id = a.watcher_id)
       -- いまも友達
       and exists (select 1 from public.tama_friends f where f.status = 'accepted'
                    and ((f.from_id = t and f.to_id = a.watcher_id) or (f.to_id = t and f.from_id = a.watcher_id)))
       -- どちらからもブロックしていない・知りたい人が止められていない
       and not exists (select 1 from public.tama_blocks b where (b.blocker_id = t and b.blocked_id = a.watcher_id) or (b.blocker_id = a.watcher_id and b.blocked_id = t))
       and not exists (select 1 from public.tama_bans b where b.user_id = a.watcher_id)
       and not exists (select 1 from public.tama_arrive_sent x where x.watcher_id = a.watcher_id and x.target_id = t and x.day = d)
  loop
    insert into public.tama_arrive_sent (watcher_id, target_id, day) values (w.watcher_id, t, d) on conflict do nothing;
    insert into public.tama_jobs (kind, payload) values ('push', jsonb_build_object(
      'to', w.watcher_id::text, 'kind', 'arrive', 'tag', 'arrive-' || t::text,
      'title', nm || 'さんが学内に来ました',
      'body', '今日はキャンパスにいます。会えるかも',
      'url', '/tama/?go=friends&n=arrive'));
  end loop;
  return new;
exception when others then
  return new;   -- 知らせを積めなくても、位置の保存は止めない
end $$;

drop trigger if exists tama_arrive_notify on public.tama_locs;
create trigger tama_arrive_notify after insert or update of lat, lng, at on public.tama_locs
  for each row execute function public.tama_arrive_notify();

-- 4. アカウントを消した人の分も消す（tama-delete-account から呼ばれなくても、友達をやめた相手には送らない作りなので必須ではない）
-- delete from public.tama_arrive_watch where watcher_id = '<id>' or target_id = '<id>';
