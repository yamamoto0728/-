-- Supabase の SQL Editor でこのファイルの内容をそのまま実行してください。
-- 多摩キャン版（/tama/）の提案②「孤独感が減ったかを測る」と③「会った最初の1分に困らない」（2026-10-07）に必要な
-- 2つのテーブルを作ります。ほかのテーブルの中身には触りません。
-- 何度実行しても同じ結果になるように書いてあります（再実行しても壊れません）。
-- ⚠️ 先に supabase/tama_tables.sql を実行済みであること（2026-09-15 に実行済み）。
-- 実行しなくてもアプリは今まで通り動く（「ひとこと」が出ず、すれ違いの「◯曜の昼休みに、よく近くにいます」が出ないだけ）。
--
-- 作るもの
--   1. tama_encounter_log  すれ違いを1回ずつ（だれと・いつ・どの建物のあたりで）。読めるのは記録した本人だけ
--   2. tama_checkins       「ひとこと」（人とのつながりの感じ方。今日のお題の後に1日1問・任意）の回答。読めるのは本人だけ
-- 研究用の集計（孤独感の変化・会えたと推定できる組・人ごとのまとめ）は supabase/tama_meet_analysis.sql。

-- ---------------------------------------------------------------------------
-- 1. すれ違いを1回ずつ
-- ---------------------------------------------------------------------------
-- tama_encounters は「回数・初回・最終」の1行だけなので、曜日や時間帯の重なり（「毎週木曜の昼休み」）が分からなかった。
-- アプリは、tama_encounters を数え直す時（同じ人は30分に1回まで）に、ここにも1行足す。
-- place は自分のいた建物（建物の判定が取れない時は「多摩キャンパス」）。座標は入れない。
create table if not exists public.tama_encounter_log (
  id        bigint      generated always as identity primary key,
  owner_id  uuid        not null default auth.uid(),   -- 記録した人（アプリを開いていた人）
  other_id  uuid        not null,                      -- すれ違った相手
  at        timestamptz not null default now(),
  place     text
);
create index if not exists tama_encounter_log_owner_idx on public.tama_encounter_log (owner_id, at);
create index if not exists tama_encounter_log_pair_idx  on public.tama_encounter_log (owner_id, other_id, at);

alter table public.tama_encounter_log enable row level security;

-- 自分の記録だけ読める・書ける（⚠️ SELECTポリシーが無いと書き込みが403になることがある）
drop policy if exists "read own encounter log" on public.tama_encounter_log;
create policy "read own encounter log" on public.tama_encounter_log for select to authenticated
  using (auth.uid() = owner_id);

drop policy if exists "write own encounter log" on public.tama_encounter_log;
create policy "write own encounter log" on public.tama_encounter_log for insert to authenticated
  with check (auth.uid() = owner_id);

-- ---------------------------------------------------------------------------
-- 2. ひとこと（つながりの感じ方）
-- ---------------------------------------------------------------------------
-- UCLA孤独感尺度 第3版（Russell, 1996）の前向きな言い方の3項目（逆転項目）を、1日1問ずつ聞く。
--   item: 'talk'（話せる人がいる。原版の項目19）/ 'company'（過ごしたい時に相手が見つかる。項目15）/ 'close'（まわりの人を身近に感じる。項目10）
--   value: 1=ない 2=あまりない 3=ときどきある 4=よくある。null＝とばした
--   wave: 何回目か。最初に答えた日を1回目の始まりとして、14日（アプリの FES.checkinEveryDays）ごとに1つ増える
-- 孤独感の得点は (5 - value) を3問ぶん足したもの（3〜12、高いほど孤独）。
create table if not exists public.tama_checkins (
  id         bigint      generated always as identity primary key,
  user_id    uuid        not null default auth.uid(),
  wave       int         not null check (wave >= 1),
  item       text        not null check (item in ('talk', 'company', 'close')),
  value      smallint    check (value between 1 and 4),
  ver        text,                                       -- アプリの版（APP_VER）
  created_at timestamptz not null default now(),
  unique (user_id, wave, item)
);

alter table public.tama_checkins enable row level security;

drop policy if exists "read own checkins" on public.tama_checkins;
create policy "read own checkins" on public.tama_checkins for select to authenticated
  using (auth.uid() = user_id);

drop policy if exists "write own checkins" on public.tama_checkins;
create policy "write own checkins" on public.tama_checkins for insert to authenticated
  with check (auth.uid() = user_id);

-- 「プロフィールを消す」で本人が消せる（利用規約 第10条）
drop policy if exists "delete own checkins" on public.tama_checkins;
create policy "delete own checkins" on public.tama_checkins for delete to authenticated
  using (auth.uid() = user_id);

notify pgrst, 'reload schema';

-- 確認: 2行出て、ポリシー数が tama_checkins = 3、tama_encounter_log = 2 ならOK
select tablename, count(*) as ポリシー数
  from pg_policies
 where schemaname = 'public' and tablename in ('tama_encounter_log', 'tama_checkins')
 group by tablename order by tablename;

-- ---------------------------------------------------------------------------
-- 実験が終わったあと（データを書き出してから、実行するときだけコメントを外す）
-- ---------------------------------------------------------------------------
-- drop table if exists public.tama_encounter_log;
-- drop table if exists public.tama_checkins;
