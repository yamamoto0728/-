-- Supabase の SQL Editor でこのファイルの内容をそのまま実行してください。
-- 多摩キャン版の「4桁のコードで友達になる」と「友達どうしのメッセージ」に必要なものを作ります。
-- 何度実行しても同じ結果になるように書いてあります（再実行しても壊れません）。
-- ⚠️ 先に supabase/tama_friends.sql を実行済みであること（2026-09-15 に実行済み）。

-- ---------------------------------------------------------------------------
-- 1. 友達コード（表示してから5分だけ使える4桁の数字）
-- ---------------------------------------------------------------------------
-- ポリシーを作らない＝アプリから直接は読めも書けもしない（下の関数だけが使う）。
-- 読めると、いま有効なコードを全部見て、知らない人と勝手に友達になれてしまうため
create table if not exists public.tama_friend_codes (
  code       text        primary key,
  owner_id   uuid        not null,
  expires_at timestamptz not null
);
alter table public.tama_friend_codes enable row level security;

-- コードを入れた記録（総当たり対策で、1人10分に10回までに制限するため）
create table if not exists public.tama_friend_code_tries (
  id         bigint      generated always as identity primary key,
  user_id    uuid        not null,
  created_at timestamptz not null default now()
);
create index if not exists tama_friend_code_tries_user_idx on public.tama_friend_code_tries (user_id, created_at desc);
alter table public.tama_friend_code_tries enable row level security;

-- 自分のコードを出す。前に出したコードは消し、いま使われていない4桁を選ぶ
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
  insert into public.tama_friend_codes (code, owner_id, expires_at) values (c, auth.uid(), now() + interval '5 minutes');
  return query select c, now() + interval '5 minutes';
end $$;

-- 相手のコードを入れて友達になる（承認なし。目の前でコードを見せている時点で同意しているとみなす）。
-- status: 'ok' / 'not_found'（無い・期限切れ・ブロック関係）/ 'self'（自分のコード）/ 'too_many'（入力しすぎ）
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
  -- どちらかがブロックしている相手とは友達にしない（ブロックされていることは相手に知らせない）
  if exists (select 1 from public.tama_blocks b
             where (b.blocker_id::text = me::text and b.blocked_id::text = other::text)
                or (b.blocker_id::text = other::text and b.blocked_id::text = me::text)) then
    return query select null::uuid, 'not_found'; return;
  end if;

  -- すでに申請の行があれば友達にし、無ければ友達の行を作る
  update public.tama_friends fr set status = 'accepted', responded_at = now()
   where (fr.from_id = me and fr.to_id = other) or (fr.from_id = other and fr.to_id = me);
  if not found then
    insert into public.tama_friends (from_id, to_id, status, responded_at) values (me, other, 'accepted', now());
  end if;
  return query select other, 'ok';
end $$;

revoke all on function public.tama_issue_friend_code() from public, anon;
revoke all on function public.tama_add_friend_by_code(text) from public, anon;
grant execute on function public.tama_issue_friend_code() to authenticated;
grant execute on function public.tama_add_friend_by_code(text) to authenticated;

-- ---------------------------------------------------------------------------
-- 2. 友達どうしのメッセージ
-- ---------------------------------------------------------------------------
-- メッセージはマッチと同じ tama_messages（match_key = 2人のIDを並べて '__' でつないだもの）。
-- 今あるポリシーはそのまま残し、「承認済みの友達どうしなら読める・送れる」を足す（ポリシーは OR で効くので、今の動きは変わらない）
drop policy if exists "friends read messages" on public.tama_messages;
create policy "friends read messages" on public.tama_messages for select to authenticated
  using (
    auth.uid()::text = any (string_to_array(match_key, '__'))
    and exists (select 1 from public.tama_friends f
                where f.status = 'accepted'
                  and ((f.from_id = auth.uid() and f.to_id::text = any (string_to_array(match_key, '__')))
                    or (f.to_id = auth.uid() and f.from_id::text = any (string_to_array(match_key, '__')))))
  );

drop policy if exists "friends send messages" on public.tama_messages;
create policy "friends send messages" on public.tama_messages for insert to authenticated
  with check (
    from_id::text = auth.uid()::text
    and auth.uid()::text = any (string_to_array(match_key, '__'))
    and exists (select 1 from public.tama_friends f
                where f.status = 'accepted'
                  and ((f.from_id = auth.uid() and f.to_id::text = any (string_to_array(match_key, '__')))
                    or (f.to_id = auth.uid() and f.from_id::text = any (string_to_array(match_key, '__')))))
  );

notify pgrst, 'reload schema';

-- 確認: 関数が2行、tama_messages のポリシーに friends read messages / friends send messages が出ればOK
select proname from pg_proc where proname in ('tama_issue_friend_code', 'tama_add_friend_by_code');
select policyname, cmd from pg_policies where schemaname = 'public' and tablename = 'tama_messages' order by policyname;

-- ---------------------------------------------------------------------------
-- 実験が終わったあと（実行するときだけコメントを外す）
-- ---------------------------------------------------------------------------
-- truncate public.tama_friend_codes, public.tama_friend_code_tries;
