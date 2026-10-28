-- 📱 アプリver：お題の案を送る（2026-10-29 ブレストの「お題をみんなで作る」）
-- Supabase の SQL Editor で、全部をそのまま1回実行してください。何度実行しても同じ結果になります。
-- 実行しなくてもアプリは動きます（「お題の案を送る」を押すと「いまは送れません（準備中）」と出るだけ）。
--
--   ・アプリverの人が、今日のお題・ちかくタイムに使えそうな質問を送れる
--   ・送った人は自分の案だけ読める。ほかの人の案は読めない（匿名の書き込みの場にしない）
--   ・1人1日5件まで。質問は40文字、答えは4つまで
--   ・チームが採用したら adopted_at を入れる（下の「採用のしかた」）。本人にだけ、アプリを開いた時に1回知らせる。採用の回数はどこにも出さない

create table if not exists public.tama_daily_ideas (
  id          bigint generated always as identity primary key,
  user_id     uuid        not null default auth.uid(),
  q           text        not null check (char_length(q) between 4 and 40),
  opts        jsonb,
  created_at  timestamptz not null default now(),
  adopted_at  timestamptz
);
alter table public.tama_daily_ideas enable row level security;

drop policy if exists "read own ideas" on public.tama_daily_ideas;
create policy "read own ideas" on public.tama_daily_ideas for select to authenticated
  using (auth.uid() = user_id);

drop policy if exists "insert own ideas" on public.tama_daily_ideas;
create policy "insert own ideas" on public.tama_daily_ideas for insert to authenticated
  with check (
    auth.uid() = user_id
    and adopted_at is null
    and (opts is null or (jsonb_typeof(opts) = 'array' and jsonb_array_length(opts) between 2 and 4))
    and (select count(*) from public.tama_daily_ideas d
         where d.user_id = auth.uid() and d.created_at > now() - interval '1 day') < 5
  );
-- 書きかえ・消すのはアプリからはできない（チームが SQL Editor で行う）

notify pgrst, 'reload schema';

-- 確認：表ができたか（「ある」なら成功）
select case when to_regclass('public.tama_daily_ideas') is not null then 'ある' else 'ない' end as tama_daily_ideas;

-- ---------------------------------------------------------------------------
-- 使い方（必要な時に、1つずつ選んで実行）
-- ---------------------------------------------------------------------------
-- 届いた案を見る（新しい順）
-- select id, q, opts, created_at, adopted_at from public.tama_daily_ideas order by created_at desc limit 50;
--
-- 採用する（daily-qs.js の末尾か、ちかくタイムの表に足したあとで）
-- update public.tama_daily_ideas set adopted_at = now() where id = ここに番号;
