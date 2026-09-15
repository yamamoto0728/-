-- Supabase の SQL Editor でこのファイルの内容をそのまま実行してください。
-- 多摩キャン版（/tama/）の「友達」と「いまどこ（建物・教室）」のテーブルを作ります。ほかのテーブルには触りません。
-- 何度実行しても同じ結果になるように書いてあります（再実行しても壊れません）。
-- ⚠️ 先に supabase/tama_tables.sql を実行済みであること（2026-09-15 に実行済み）。

-- ---------------------------------------------------------------------------
-- 1. 友達（申請 → 承認）
-- ---------------------------------------------------------------------------
-- 1行 = 1件の申請。status が 'accepted' になった行が「友達」。
create table if not exists public.tama_friends (
  id           bigint generated always as identity primary key,
  from_id      uuid        not null,                       -- 申請した人
  to_id        uuid        not null,                       -- 申請された人
  status       text        not null default 'pending' check (status in ('pending', 'accepted')),
  created_at   timestamptz not null default now(),
  responded_at timestamptz,
  unique (from_id, to_id),
  check (from_id <> to_id)
);
create index if not exists tama_friends_to_idx on public.tama_friends (to_id);

alter table public.tama_friends enable row level security;

-- 自分が関わる申請だけ読める（⚠️ SELECTポリシーが無いと upsert が403になる）
drop policy if exists "read own friend rows" on public.tama_friends;
create policy "read own friend rows" on public.tama_friends for select
  using (auth.uid() = from_id or auth.uid() = to_id);

-- 自分から「申請中」の行だけ作れる（いきなり友達にはできない）
drop policy if exists "send friend request" on public.tama_friends;
create policy "send friend request" on public.tama_friends for insert to authenticated
  with check (auth.uid() = from_id and status = 'pending');

-- 承認できるのは申請された側だけ
drop policy if exists "accept friend request" on public.tama_friends;
create policy "accept friend request" on public.tama_friends for update to authenticated
  using (auth.uid() = to_id) with check (auth.uid() = to_id);

-- 断る・取り消す・友達をやめるは、どちらからでもできる
drop policy if exists "remove friend row" on public.tama_friends;
create policy "remove friend row" on public.tama_friends for delete to authenticated
  using (auth.uid() = from_id or auth.uid() = to_id);

-- ---------------------------------------------------------------------------
-- 2. いまどこ（建物・教室・ひとこと・友達への公開範囲）
-- ---------------------------------------------------------------------------
-- 1人1行。建物（place）は位置から自動で入り、教室（room）とひとこと（note）は本人が入れる。
-- visibility: 'map' = 地図の位置も見せる / 'building' = 建物と教室だけ / 'hidden' = 友達にも見せない
create table if not exists public.tama_presence (
  id         uuid        primary key,
  place      text,
  room       text,
  note       text,
  visibility text        not null default 'building' check (visibility in ('map', 'building', 'hidden')),
  expires_at timestamptz,                                  -- 教室・ひとことが消える時刻（入力から90分）
  updated_at timestamptz not null default now()
);

alter table public.tama_presence enable row level security;

-- 読めるのは本人と、承認済みの友達だけ。'hidden' の人は友達からも読めない。
-- （教室まで分かる情報なので、アプリの表示だけでなくデータベース側で読める人を絞る）
drop policy if exists "read presence self or friends" on public.tama_presence;
create policy "read presence self or friends" on public.tama_presence for select
  using (
    auth.uid() = id
    or (visibility <> 'hidden' and exists (
      select 1 from public.tama_friends f
      where f.status = 'accepted'
        and ((f.from_id = auth.uid() and f.to_id = tama_presence.id)
          or (f.to_id = auth.uid() and f.from_id = tama_presence.id))
    ))
  );

drop policy if exists "write own presence" on public.tama_presence;
create policy "write own presence" on public.tama_presence for insert to authenticated
  with check (auth.uid() = id);

drop policy if exists "update own presence" on public.tama_presence;
create policy "update own presence" on public.tama_presence for update to authenticated
  using (auth.uid() = id) with check (auth.uid() = id);

drop policy if exists "delete own presence" on public.tama_presence;
create policy "delete own presence" on public.tama_presence for delete to authenticated
  using (auth.uid() = id);

notify pgrst, 'reload schema';

-- 確認: 2行出て、ポリシー数が tama_friends=4 / tama_presence=4 ならOK
select tablename, count(*) as ポリシー数
from pg_policies
where schemaname = 'public' and tablename in ('tama_friends', 'tama_presence')
group by tablename;

-- ---------------------------------------------------------------------------
-- 実験が終わったあと（実行するときだけコメントを外す）
-- ---------------------------------------------------------------------------
-- ⚠️ 元に戻せません。必ず集計用にデータを書き出してから実行すること。
-- truncate public.tama_friends, public.tama_presence;
