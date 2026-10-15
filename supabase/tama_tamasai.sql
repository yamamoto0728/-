-- Supabase の SQL Editor でこのファイルの内容をそのまま実行してください（2026-10-11、10-14 に追加）。
-- 何度実行しても同じ結果になるように書いてあります（再実行しても壊れません）。
-- ⚠️ 先に supabase/tama_notify.sql を実行してあること（ちかくタイムの表 tama_ct_slots を使うため。無ければ、その部分だけ飛ばす）。
-- ⚠️ 実行したあと、Edge Function tama-remind を貼り直してデプロイすること（多摩祭の通知の種類 recap・fsurvey と、土日のちかくタイムに対応したもの）。
-- 実行しなくてもアプリは動く（多摩祭のカードに人数が出ない・🎉バッジが付かない・クーポンが出ない・祭りのちかくタイムと通知が無いだけ）。
--
-- 多摩祭（2026-10-17・18）。日付はアプリ（tama/tamasai.js）にも書いてある。変える時は両方。
--   1. 参加人数（tama_tamasai_count）＝その日にキャンパスでアプリを開いた人（2日の合計・同じ人は1回）
--   2. 出店とクーポン（tama_booths・tama_coupon_uses）
--   3. 昼と夕方のちかくタイム（祭りのお題）
--   4. 多摩祭の通知（自動）：12:30・15:30 のちかくタイム、1日目 18:30「今日のすれ違い」、2日目 17:45 花火のちかくタイム・19:00 と翌日 18:00 のアンケート（URL がある時だけ）
--      → 1日目は3通、2日目は花火の分で4通（あおの決定。花火の前のお知らせはちかくタイムの通知に1つにまとめた）

-- ---------------------------------------------------------------------------
-- 1. 参加人数
-- ---------------------------------------------------------------------------
create or replace function public.tama_tamasai_count()
returns int language sql stable security definer set search_path = public as $$
  select count(distinct user_id)::int from public.tama_visits
   where day in (date '2026-10-17', date '2026-10-18') and on_campus;
$$;
revoke all on function public.tama_tamasai_count() from public, anon;
grant execute on function public.tama_tamasai_count() to authenticated;

-- 1-2. 「ちかく」のユーザー数（2026-10-15 あおの決定：多摩祭のカードの目標は、ちかくのユーザー200人）。
--      多摩キャン版（tama_profiles）＋通常版（profiles）の登録者の合計。同じ人が両方に登録していても2人と数える（別のIDのため見分けられない）。
--      通常版の表が無い時は、多摩キャン版だけを数える
create or replace function public.tama_chikaku_users()
returns int language plpgsql stable security definer set search_path = public as $$
declare n int; m int := 0;
begin
  select count(*) into n from public.tama_profiles;
  if to_regclass('public.profiles') is not null then execute 'select count(*) from public.profiles' into m; end if;
  return n + m;
end $$;
revoke all on function public.tama_chikaku_users() from public, anon;
grant execute on function public.tama_chikaku_users() to authenticated;

-- ---------------------------------------------------------------------------
-- 2. 出店とクーポン
-- ---------------------------------------------------------------------------
-- 登録は運営が Table Editor か下の insert で行う。アプリからは読むだけ。
-- 緯度・経度は任意（入れると地図にマークが出て、近くを通った人に知らせる。入れなくてもクーポンの一覧には出る）
create table if not exists public.tama_booths (
  id          bigint generated always as identity primary key,
  name        text             not null,                 -- 出店名
  description text,                                      -- ひとこと（メニュー・値段など）
  emoji       text             not null default '🏪',    -- マーク
  lat         double precision,                          -- 緯度（任意）
  lng         double precision,                          -- 経度（任意）
  place       text,                                      -- 場所の説明（例:「中央広場」「3号館 1F」）
  indoor      boolean          not null default false,   -- 建物の中なら true
  coupon      text,                                      -- クーポンの中身（例:「トッピング1つ無料」）。空ならクーポンなし
  active      boolean          not null default true,    -- false にするとアプリに出なくなる
  created_at  timestamptz      not null default now()
);
alter table public.tama_booths add column if not exists coupon text;
alter table public.tama_booths alter column lat drop not null;
alter table public.tama_booths alter column lng drop not null;
alter table public.tama_booths enable row level security;
drop policy if exists "read active booths" on public.tama_booths;
create policy "read active booths" on public.tama_booths for select using (active);

-- クーポンを使った記録。お店の人が、お客さんのスマホの「使いました」を押す（1つの出店につき1人1回）。金額は任意
create table if not exists public.tama_coupon_uses (
  id         bigserial primary key,
  booth_id   bigint not null,
  user_id    uuid   not null,
  amount     int    check (amount is null or (amount >= 0 and amount <= 100000)),
  created_at timestamptz not null default now(),
  unique (booth_id, user_id)
);
alter table public.tama_coupon_uses enable row level security;
drop policy if exists "own coupon insert" on public.tama_coupon_uses;
create policy "own coupon insert" on public.tama_coupon_uses for insert to authenticated with check (user_id = auth.uid());
drop policy if exists "own coupon read" on public.tama_coupon_uses;
create policy "own coupon read" on public.tama_coupon_uses for select to authenticated using (user_id = auth.uid());

-- ---------------------------------------------------------------------------
-- 3. 昼と夕方のちかくタイム（祭りのお題）。ちかくタイムの表が無ければ（tama_notify.sql の前）飛ばす
-- ---------------------------------------------------------------------------
do $$
begin
  if to_regclass('public.tama_ct_slots') is null then
    raise notice 'tama_ct_slots がありません。先に tama_notify.sql を実行してから、もう一度このファイルを実行してください';
    return;
  end if;
  -- 通知の文を変えたい回だけ使う列（空ならいつもの「⏰ ちかくタイム（10分間）」の文。2026-10-15 花火の回のため）
  alter table public.tama_ct_slots add column if not exists push_title text;
  alter table public.tama_ct_slots add column if not exists push_body  text;
  insert into public.tama_ct_slots (starts_at, q, o1, o2, push_title, push_body) values
    ('2026-10-17 12:30:00+09', '屋台で食べるなら？',         'しょっぱい系', 'あまい系',   null, null),
    ('2026-10-17 15:30:00+09', '今日いちばんよかったのは？', '食べたもの',   '見たもの',   null, null),
    ('2026-10-18 12:30:00+09', '多摩祭は何回目？',           'はじめて',     '2回目以上',  null, null),
    ('2026-10-18 15:30:00+09', '来年も多摩祭に来たい？',     '来たい',       'たぶん',     null, null),
    -- 18日 18:00 の花火（あおの決定：花火のちかくタイム＋花火の前のお知らせ。続けて2通鳴らさないよう1通にまとめた）
    ('2026-10-18 17:45:00+09', '花火、どこで見る？',         '会場で見る',   '帰りながら見る',
     '🎆 18時から花火・ちかくタイム（10分）',
     '「花火、どこで見る？」答えると同じ答えの人が分かります。開いたまま見ると、近くで見ている人とのすれ違いが記録されます')
  on conflict (starts_at) do update set push_title = excluded.push_title, push_body = excluded.push_body;
  -- 祭りの昼と夕方の回は、通知の題名を「🎪 多摩祭のちかくタイム」に（いつものちかくタイムと見分けがつくように。2026-10-15 のレビュー）
  update public.tama_ct_slots set push_title = '🎪 多摩祭のちかくタイム（10分）'
   where starts_at in ('2026-10-17 12:30:00+09', '2026-10-17 15:30:00+09', '2026-10-18 12:30:00+09', '2026-10-18 15:30:00+09');
end $$;

-- 多摩祭の通知（今日のすれ違い・アンケート）を、1日に1回だけ送るための記録（tama-remind が書く。アプリからは読めない・書けない）
create table if not exists public.tama_fes_sent (
  key        text primary key,   -- 例：recap:2026-10-17
  created_at timestamptz not null default now()
);
alter table public.tama_fes_sent enable row level security;

-- ---------------------------------------------------------------------------
-- 4. 多摩祭の通知（pg_cron。時刻は世界標準時＝日本時間から9時間引く）
-- ---------------------------------------------------------------------------
-- ⚠️ 日付で決めているので毎年動く。Edge Function 側でも2026年の多摩祭の日だけ送るようにしているが、終わったら下の「消す」を実行する
create extension if not exists pg_cron;
create extension if not exists pg_net;
do $$
declare
  j record;
  -- Authorization の値は tama/index.html にも書かれている公開用の anon キー（秘密の鍵ではない。tama_remind.sql と同じ）
  anon text := 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InJvc2d2bnhxY3V5ZW5saXBha2NrIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODMyNTQ5MDEsImV4cCI6MjA5ODgzMDkwMX0.SrEjGpoZUe6yfOMnQ-g6Cb-cBUg4L8AIElJ5e8UFXyg';
begin
  for j in select * from (values
    ('tama-fes-ct-1230',   '30 3 17,18 10 *', '{"kind":"ct"}'),                          -- 17・18日 12:30 ちかくタイム
    ('tama-fes-ct-1530',   '30 6 17,18 10 *', '{"kind":"ct"}'),                          -- 17・18日 15:30 ちかくタイム
    ('tama-fes-ct-1745',   '45 8 18 10 *',    '{"kind":"ct"}'),                          -- 18日 17:45 花火のちかくタイム（18:00 花火）
    ('tama-fes-recap',     '30 9 17 10 *',    '{"kind":"recap","day":"2026-10-17"}'),    -- 17日 18:30 今日のすれ違い
    ('tama-fes-survey-1',  '0 10 18 10 *',    '{"kind":"fsurvey"}'),                     -- 18日 19:00 アンケート（花火のあと）
    ('tama-fes-survey-2',  '0 9 19 10 *',     '{"kind":"fsurvey"}')                      -- 19日 18:00 アンケート（翌日のリマインド）
  ) as v(name, sched, body)
  loop
    if exists (select 1 from cron.job where jobname = j.name) then perform cron.unschedule(j.name); end if;
    perform cron.schedule(j.name, j.sched, format(
      $cmd$select net.http_post(
        url     := 'https://rosgvnxqcuyenlipakck.supabase.co/functions/v1/tama-remind',
        headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer %s'),
        body    := %L::jsonb
      )$cmd$, anon, j.body));
  end loop;
end $$;

notify pgrst, 'reload schema';

-- 確認：いまの参加人数（多摩祭の前は 0）と、多摩祭の通知の予定（6行）
select public.tama_tamasai_count() as 多摩祭の参加人数, public.tama_chikaku_users() as ちかくのユーザー数;
select jobname, schedule, active from cron.job where jobname like 'tama-fes-%' order by jobname;

-- ---------------------------------------------------------------------------
-- 出店の登録のしかた（登録するときだけコメントを外して実行。Table Editor の tama_booths に直接入れてもよい）
-- ---------------------------------------------------------------------------
-- insert into public.tama_booths (name, description, emoji, place, coupon) values
--   ('焼きそば ○○サークル', '1パック300円', '🍜', '中央広場', 'ちかくの画面を見せると、マヨネーズ増量'),
--   ('クレープ △△部',       '',             '🍓', '3号館前',  'トッピング1つ無料');
-- 地図にも出す時は lat, lng（Googleマップで場所を長押しすると出る「35.61xxx, 139.29xxx」）も入れる。
-- 表示をやめる: update public.tama_booths set active = false where name = '焼きそば ○○サークル';

-- ---------------------------------------------------------------------------
-- 多摩祭のあとに見る数字（supabase/tama_tamasai_report.sql にまとめてある）
-- 多摩祭が終わったら通知の予定を消す（実行するときだけコメントを外す）:
--   select cron.unschedule(jobname) from cron.job where jobname like 'tama-fes-%';
-- ---------------------------------------------------------------------------
