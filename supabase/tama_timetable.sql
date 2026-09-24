-- Supabase の SQL Editor でこのファイルの内容をそのまま実行してください。
-- 多摩キャン版（/tama/）の「時間割（履修）」のテーブルと、「同じ授業の人」を返す関数を作ります。ほかのテーブルには触りません。
-- 何度実行しても同じ結果になるように書いてあります（再実行しても壊れません）。

-- ---------------------------------------------------------------------------
-- 1. 時間割（1人1行）
-- ---------------------------------------------------------------------------
-- slots の例: {"1-2": "マーケティング論", "3-1": ""}
--   キー = 曜日(1=月〜5=金) - 時限(1〜5)、値 = 授業名（任意。空なら名前なし）
-- 使い道: ①授業のある時限の始まりにだけ「いまどこ？」の通知を送る（Edge Function tama-remind）
--         ②同じ曜日・時限に同じ授業名を入れた人を「同じ授業」として共通点に出す
create table if not exists public.tama_timetable (
  id         uuid        primary key,
  slots      jsonb       not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);

alter table public.tama_timetable enable row level security;

-- 「毎週いつどこにいるか」が分かる情報なので、読めるのも書けるのも本人だけ
-- （⚠️ SELECTポリシーが無いと upsert が403になる）
drop policy if exists "read own timetable" on public.tama_timetable;
create policy "read own timetable" on public.tama_timetable for select
  using (auth.uid() = id);

drop policy if exists "insert own timetable" on public.tama_timetable;
create policy "insert own timetable" on public.tama_timetable for insert to authenticated
  with check (auth.uid() = id);

drop policy if exists "update own timetable" on public.tama_timetable;
create policy "update own timetable" on public.tama_timetable for update to authenticated
  using (auth.uid() = id) with check (auth.uid() = id);

drop policy if exists "delete own timetable" on public.tama_timetable;
create policy "delete own timetable" on public.tama_timetable for delete to authenticated
  using (auth.uid() = id);

-- ---------------------------------------------------------------------------
-- 2. 同じ授業の人
-- ---------------------------------------------------------------------------
-- 自分と「同じ曜日・同じ時限に、同じ授業名」を入れている人だけを返す。
-- 他の人の時間割そのものは返さない（RLS で読めない表を、この関数だけが必要な分だけ見る）。
-- 授業名は全角・半角、大文字・小文字、空白の違いをそろえてから比べる（アプリの normCourse と同じ）。
create or replace function public.tama_same_course_peers()
returns table (other_id uuid, slot text, course text)
language sql stable security definer set search_path = public
as $$
  with mine as (
    select s.key as slot, s.value as course,
           lower(regexp_replace(normalize(s.value, NFKC), '\s+', '', 'g')) as n
    from public.tama_timetable t, jsonb_each_text(t.slots) s
    where t.id = auth.uid()
  )
  select o.id, m.slot, m.course
  from public.tama_timetable o, jsonb_each_text(o.slots) s, mine m
  where o.id <> auth.uid()
    and m.n <> ''
    and s.key = m.slot
    and lower(regexp_replace(normalize(s.value, NFKC), '\s+', '', 'g')) = m.n
$$;

revoke all on function public.tama_same_course_peers() from public, anon;
grant execute on function public.tama_same_course_peers() to authenticated;

notify pgrst, 'reload schema';

-- 確認: ポリシー数が 4、関数が 1 行出ればOK
select tablename, count(*) as ポリシー数 from pg_policies
where schemaname = 'public' and tablename = 'tama_timetable' group by tablename;
select proname from pg_proc where proname = 'tama_same_course_peers';

-- ---------------------------------------------------------------------------
-- 実験が終わったあと（実行するときだけコメントを外す）
-- ---------------------------------------------------------------------------
-- ⚠️ 元に戻せません。必ず集計用にデータを書き出してから実行すること。
-- truncate public.tama_timetable;
