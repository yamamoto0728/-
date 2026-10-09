-- Supabase の SQL Editor でこのファイルの内容をそのまま実行してください（2026-10-10）。
-- 何度実行しても同じ結果になるように書いてあります（再実行しても壊れません）。
-- あおの依頼「50人ちかく使っている。セキュリティを強化しよう」。2026-10-10 に本番の RLS を読み出して見つけたものを直す。
--
-- 1. プロフィール（tama_profiles）を、ログインしていない人（anon）からは読めないようにする
--    前は「だれでも読める（public・true）」で、ページに入っている公開キーだけで、全員の名前・年齢・最後にいた位置が取れた
-- 2. 年齢をほかの人から読めないようにする：年齢は tama_private（本人だけが読める）に移し、tama_profiles.age は空にする。
--    古い版のアプリが age を書いても、トリガーで tama_private に移して空にする
-- 3. トーク（tama_messages）を書ける条件をしぼる：前は「送る人が自分」だけで、マッチしていない人・ほかの2人の会話にも書けた。
--    → 自分がその会話の2人のうちの1人で、相手とおたがいにいいねしている（マッチ）か、友達（承認ずみ。これは前からある決まり）の時だけ
-- 4. 通知の記録（tama_push_log）・古いマッチの記録（tama_match_unlocks）も、ログインしていない人からは読めないように
-- 5. 長すぎる文字を入れられないように（名前30・自己紹介300・アイコン16・メッセージ1000文字。今ある行は確かめない NOT VALID）

-- 1. プロフィールを読めるのはログインした人だけ
do $$
declare p record;
begin
  for p in select policyname from pg_policies where schemaname = 'public' and tablename = 'tama_profiles' and cmd = 'SELECT' loop
    execute format('drop policy %I on public.tama_profiles', p.policyname);
  end loop;
end $$;
create policy "signed in users read profiles" on public.tama_profiles for select to authenticated using (true);

-- 2. 年齢を本人だけが読める表へ
create table if not exists public.tama_private (
  id  uuid primary key,
  age int
);
alter table public.tama_private enable row level security;
drop policy if exists "own private read" on public.tama_private;
create policy "own private read" on public.tama_private for select to authenticated using (auth.uid() = id);

create or replace function public.tama_profiles_keep_age_private()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.age is not null then
    insert into public.tama_private (id, age) values (new.id, new.age)
    on conflict (id) do update set age = excluded.age;
    new.age := null;
  end if;
  return new;
end $$;
drop trigger if exists tama_profiles_keep_age_private on public.tama_profiles;
create trigger tama_profiles_keep_age_private before insert or update on public.tama_profiles
  for each row execute function public.tama_profiles_keep_age_private();
-- ãã­ãã£ã¼ã«ãæ¶ãããå¹´é½¢ãæ¶ã
create or replace function public.tama_profiles_drop_private()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  delete from public.tama_private where id = old.id;
  return old;
end $$;
drop trigger if exists tama_profiles_drop_private on public.tama_profiles;
create trigger tama_profiles_drop_private after delete on public.tama_profiles
  for each row execute function public.tama_profiles_drop_private();
-- 今ある年齢を移して、プロフィールからは消す
insert into public.tama_private (id, age)
select id, age from public.tama_profiles where age is not null
on conflict (id) do update set age = excluded.age;
update public.tama_profiles set age = null where age is not null;

-- 3. トークを書けるのは、会話の2人のうちの1人で、相手とマッチしている時（友達の時は前からある決まりで書ける）
do $$
declare p record;
begin
  for p in select policyname from pg_policies
            where schemaname = 'public' and tablename = 'tama_messages' and cmd = 'INSERT' and roles = '{public}' loop
    execute format('drop policy %I on public.tama_messages', p.policyname);
  end loop;
end $$;
drop policy if exists "match send messages" on public.tama_messages;
create policy "match send messages" on public.tama_messages for insert to authenticated
with check (
  from_id::text = auth.uid()::text
  and auth.uid()::text = any (string_to_array(match_key, '__'))
  and exists (
    select 1 from public.tama_likes a join public.tama_likes b on b.from_id = a.to_id and b.to_id = a.from_id
     where a.from_id = auth.uid() and a.to_id <> auth.uid()
       and a.to_id::text = any (string_to_array(match_key, '__')))
);

-- 4. 通知の記録・古いマッチの記録は、ログインした人だけ
do $$
declare p record;
begin
  for p in select tablename, policyname from pg_policies
            where schemaname = 'public' and tablename in ('tama_push_log', 'tama_match_unlocks') and cmd = 'SELECT' and roles = '{public}' loop
    execute format('drop policy %I on public.%I', p.policyname, p.tablename);
  end loop;
end $$;
drop policy if exists "signed in users read push log" on public.tama_push_log;
create policy "signed in users read push log" on public.tama_push_log for select to authenticated using (true);
drop policy if exists "signed in users read unlocks" on public.tama_match_unlocks;
create policy "signed in users read unlocks" on public.tama_match_unlocks for select to authenticated using (true);

-- 5. 長さの上限（今ある行は確かめない）
alter table public.tama_profiles drop constraint if exists tama_profiles_len;
alter table public.tama_profiles add constraint tama_profiles_len
  check (char_length(coalesce(name, '')) <= 30 and char_length(coalesce(bio, '')) <= 300 and char_length(coalesce(emoji, '')) <= 16) not valid;
alter table public.tama_messages drop constraint if exists tama_messages_len;
alter table public.tama_messages add constraint tama_messages_len check (char_length(coalesce(text, '')) <= 1000) not valid;

notify pgrst, 'reload schema';

-- 確認：下の4行が出ればOK（プロフィールの読む決まりが authenticated、トークの書く決まりに match send messages、年齢が空になった数）
select 'プロフィールを読める人' as 項目, string_agg(array_to_string(roles, ','), ' / ') as 結果 from pg_policies where tablename = 'tama_profiles' and cmd = 'SELECT'
union all
select 'トークを書ける決まり', string_agg(policyname || '(' || array_to_string(roles, ',') || ')', ' / ') from pg_policies where tablename = 'tama_messages' and cmd = 'INSERT'
union all
select '年齢が残っているプロフィール', count(*)::text from public.tama_profiles where age is not null
union all
select '年齢を移した数', count(*)::text from public.tama_private;
