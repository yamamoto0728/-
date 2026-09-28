-- Supabase の SQL Editor でこのファイルの内容をそのまま実行してください。
-- 多摩キャン版（/tama/）の時間割に「教室名」を足し、「時間割を友達に見せる」機能の表とルールを作ります（2026-09-28）。
-- ⚠️ 先に tama_timetable.sql・tama_friends.sql が実行済みであること。
-- 何度実行しても同じ結果になるように書いてあります（再実行しても壊れません）。

-- ---------------------------------------------------------------------------
-- 1. 時間割に教室名の列を足す
-- ---------------------------------------------------------------------------
-- rooms の例: {"4-2": "A棟401"}（キーは slots と同じ「曜日-時限」。任意）
-- 授業のある時限に「いまの自分」を開くと、この教室名が候補のボタンとして出る
alter table public.tama_timetable add column if not exists rooms jsonb not null default '{}'::jsonb;

-- ---------------------------------------------------------------------------
-- 2. 時間割を見せる相手（本人が友達ごとに選ぶ）
-- ---------------------------------------------------------------------------
-- 1行 =「owner_id の人が friend_id の人に、自分の時間割（授業名・教室）を見せている」
create table if not exists public.tama_timetable_shares (
  owner_id   uuid        not null,
  friend_id  uuid        not null,
  created_at timestamptz not null default now(),
  primary key (owner_id, friend_id)
);

alter table public.tama_timetable_shares enable row level security;

-- 読めるのは、見せている本人と、見せてもらっている相手だけ
drop policy if exists "read own shares" on public.tama_timetable_shares;
create policy "read own shares" on public.tama_timetable_shares for select to authenticated
  using (auth.uid() = owner_id or auth.uid() = friend_id);

-- 見せる相手を足せるのは本人だけ。相手は承認済みの友達に限る
drop policy if exists "insert own shares" on public.tama_timetable_shares;
create policy "insert own shares" on public.tama_timetable_shares for insert to authenticated
  with check (
    auth.uid() = owner_id
    and exists (select 1 from public.tama_friends f
                where f.status = 'accepted'
                  and ((f.from_id = owner_id and f.to_id = friend_id) or (f.to_id = owner_id and f.from_id = friend_id)))
  );

-- やめられるのも本人だけ
drop policy if exists "delete own shares" on public.tama_timetable_shares;
create policy "delete own shares" on public.tama_timetable_shares for delete to authenticated
  using (auth.uid() = owner_id);

-- ---------------------------------------------------------------------------
-- 3. 見せてもらっている友達の時間割を読めるようにする
-- ---------------------------------------------------------------------------
-- いまの「本人だけ読める」ルールはそのまま残し、「見せてもらっていて、いまも友達なら読める」を足す（ポリシーは OR で効く）。
-- 友達をやめると、見せる設定の行が残っていても読めなくなる
drop policy if exists "friends read shared timetable" on public.tama_timetable;
create policy "friends read shared timetable" on public.tama_timetable for select to authenticated
  using (
    exists (select 1 from public.tama_timetable_shares s
            where s.owner_id = tama_timetable.id and s.friend_id = auth.uid())
    and exists (select 1 from public.tama_friends f
                where f.status = 'accepted'
                  and ((f.from_id = tama_timetable.id and f.to_id = auth.uid()) or (f.to_id = tama_timetable.id and f.from_id = auth.uid())))
  );

notify pgrst, 'reload schema';

-- 確認: rooms 列が1行、tama_timetable のポリシーに friends read shared timetable、tama_timetable_shares のポリシーが3つ出ればOK
select column_name from information_schema.columns where table_schema = 'public' and table_name = 'tama_timetable' and column_name = 'rooms';
select tablename, policyname from pg_policies where schemaname = 'public' and tablename in ('tama_timetable', 'tama_timetable_shares') order by tablename, policyname;

-- ---------------------------------------------------------------------------
-- 実験が終わったあと（実行するときだけコメントを外す）
-- ---------------------------------------------------------------------------
-- ⚠️ 元に戻せません。必ず集計用にデータを書き出してから実行すること。
-- truncate public.tama_timetable_shares;
