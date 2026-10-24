-- 📱 アプリver：つながり方と居場所の見せ方（2026-10-24 要件定義書 v0.1 の A1〜A3）
-- Supabase の SQL Editor で、全部をそのまま1回実行してください。何度実行しても同じ結果になります。
-- 実行しなくてもアプリは今まで通り動きます（アプリverの人だけ、下の3つが使えない）。
-- 多摩キャンverの人は今まで通り「友達全員に居場所を見せる」のまま（share_mode = 'all'）。
--
--   A1 いいね → 友達の2段：おたがいにいいねしたら、その場で友達にする関数（tama_friend_from_like）
--   A2 居場所を見せる相手を、友達ごとに選ぶ：見せる相手の表（tama_loc_shares）と、いまどこ（tama_presence）の読める人の決まり
--   A3 会って3分間だけ使えるコード：友達のコードを3分に。コードで友達になった2人は、おたがいに「見せる」がオン

-- ---------------------------------------------------------------------------
-- A2-1. 居場所を見せる相手（1行＝「owner が friend に見せる」）
-- ---------------------------------------------------------------------------
create table if not exists public.tama_loc_shares (
  owner_id   uuid        not null,
  friend_id  uuid        not null,
  created_at timestamptz not null default now(),
  primary key (owner_id, friend_id)
);
alter table public.tama_loc_shares enable row level security;

drop policy if exists "read own loc shares" on public.tama_loc_shares;
create policy "read own loc shares" on public.tama_loc_shares for select to authenticated
  using (auth.uid() = owner_id or auth.uid() = friend_id);

-- 見せる相手を足せるのは本人だけ。相手は承認済みの友達に限る
drop policy if exists "insert own loc shares" on public.tama_loc_shares;
create policy "insert own loc shares" on public.tama_loc_shares for insert to authenticated
  with check (
    auth.uid() = owner_id
    and exists (select 1 from public.tama_friends f
                where f.status = 'accepted'
                  and ((f.from_id = owner_id and f.to_id = friend_id) or (f.to_id = owner_id and f.from_id = friend_id)))
  );

drop policy if exists "delete own loc shares" on public.tama_loc_shares;
create policy "delete own loc shares" on public.tama_loc_shares for delete to authenticated
  using (auth.uid() = owner_id);

-- ---------------------------------------------------------------------------
-- A2-2. いまどこ（建物・教室・ひとこと）を読める人
-- ---------------------------------------------------------------------------
-- share_mode：'all' ＝友達全員に見せる（今まで通り・多摩キャンver）／ 'chosen' ＝選んだ友達だけ（アプリver）
alter table public.tama_presence add column if not exists share_mode text not null default 'all';
alter table public.tama_presence drop constraint if exists tama_presence_share_mode_check;
alter table public.tama_presence add constraint tama_presence_share_mode_check check (share_mode in ('all', 'chosen'));

drop policy if exists "read presence self or friends" on public.tama_presence;
create policy "read presence self or friends" on public.tama_presence for select
  using (
    auth.uid() = id
    or (visibility <> 'hidden'
        and exists (
          select 1 from public.tama_friends f
          where f.status = 'accepted'
            and ((f.from_id = auth.uid() and f.to_id = tama_presence.id)
              or (f.to_id = auth.uid() and f.from_id = tama_presence.id)))
        and (share_mode = 'all'
             or exists (select 1 from public.tama_loc_shares s where s.owner_id = tama_presence.id and s.friend_id = auth.uid())))
  );

-- ---------------------------------------------------------------------------
-- A1. おたがいにいいねしたら、その場で友達にする
-- ---------------------------------------------------------------------------
-- status：'ok'（友達になった・もう友達）／ 'not_mutual'（まだ片方だけ）／ 'blocked'（どちらかがブロック）
create or replace function public.tama_friend_from_like(p_other uuid)
returns text
language plpgsql volatile security definer set search_path = public
as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'not signed in'; end if;
  if p_other is null or p_other = me then return 'not_mutual'; end if;
  if not exists (select 1 from public.tama_likes l where l.from_id::text = me::text and l.to_id::text = p_other::text)
     or not exists (select 1 from public.tama_likes l where l.from_id::text = p_other::text and l.to_id::text = me::text) then
    return 'not_mutual';
  end if;
  if exists (select 1 from public.tama_blocks b
             where (b.blocker_id::text = me::text and b.blocked_id::text = p_other::text)
                or (b.blocker_id::text = p_other::text and b.blocked_id::text = me::text)) then
    return 'blocked';
  end if;
  update public.tama_friends fr set status = 'accepted', responded_at = now()
   where (fr.from_id = me and fr.to_id = p_other) or (fr.from_id = p_other and fr.to_id = me);
  if not found then
    insert into public.tama_friends (from_id, to_id, status, responded_at) values (me, p_other, 'accepted', now());
  end if;
  return 'ok';
end $$;
revoke all on function public.tama_friend_from_like(uuid) from public, anon;
grant execute on function public.tama_friend_from_like(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- A3. 友達のコードを3分に。コードで友達になった2人は、おたがいに居場所を見せる
-- ---------------------------------------------------------------------------
create or replace function public.tama_issue_friend_code()
returns table (code text, expires_at timestamptz)
language plpgsql volatile security definer set search_path = public
as $$
#variable_conflict use_column
declare
  c text;
  i int := 0;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  delete from public.tama_friend_codes f where f.expires_at < now() or f.owner_id = auth.uid();
  loop
    c := lpad((floor(random() * 10000))::int::text, 4, '0');
    exit when not exists (select 1 from public.tama_friend_codes f where f.code = c);
    i := i + 1;
    if i > 200 then raise exception 'no free code'; end if;
  end loop;
  insert into public.tama_friend_codes (code, owner_id, expires_at) values (c, auth.uid(), now() + interval '3 minutes');
  return query select c, now() + interval '3 minutes';
end $$;

create or replace function public.tama_add_friend_by_code(p_code text)
returns table (friend_id uuid, status text)
language plpgsql volatile security definer set search_path = public
as $$
#variable_conflict use_column
declare
  me uuid := auth.uid();
  other uuid;
  tries int;
begin
  if me is null then raise exception 'not signed in'; end if;
  insert into public.tama_friend_code_tries (user_id) values (me);
  select count(*) into tries from public.tama_friend_code_tries t where t.user_id = me and t.created_at > now() - interval '10 minutes';
  if tries > 10 then return query select null::uuid, 'too_many'; return; end if;

  select f.owner_id into other from public.tama_friend_codes f where f.code = p_code and f.expires_at > now();
  if other is null then return query select null::uuid, 'not_found'; return; end if;
  if other = me then return query select null::uuid, 'self'; return; end if;
  if exists (select 1 from public.tama_blocks b
             where (b.blocker_id::text = me::text and b.blocked_id::text = other::text)
                or (b.blocker_id::text = other::text and b.blocked_id::text = me::text)) then
    return query select null::uuid, 'not_found'; return;
  end if;

  update public.tama_friends fr set status = 'accepted', responded_at = now()
   where (fr.from_id = me and fr.to_id = other) or (fr.from_id = other and fr.to_id = me);
  if not found then
    insert into public.tama_friends (from_id, to_id, status, responded_at) values (me, other, 'accepted', now());
  end if;
  -- 会ってコードを交換した2人は、おたがいに居場所を見せる（アプリverの「選んだ友達だけ」の人にも見えるように）
  insert into public.tama_loc_shares (owner_id, friend_id) values (me, other), (other, me) on conflict do nothing;
  return query select other, 'ok';
end $$;

revoke all on function public.tama_issue_friend_code() from public, anon;
revoke all on function public.tama_add_friend_by_code(text) from public, anon;
grant execute on function public.tama_issue_friend_code() to authenticated;
grant execute on function public.tama_add_friend_by_code(text) to authenticated;

notify pgrst, 'reload schema';

-- 確認：表と列と関数ができたか（3行とも「ある」なら成功）
select 'tama_loc_shares' as もの, case when to_regclass('public.tama_loc_shares') is not null then 'ある' else 'ない' end as 結果
union all select 'tama_presence.share_mode', case when exists (select 1 from information_schema.columns where table_name = 'tama_presence' and column_name = 'share_mode') then 'ある' else 'ない' end
union all select 'tama_friend_from_like', case when exists (select 1 from pg_proc where proname = 'tama_friend_from_like') then 'ある' else 'ない' end;
