-- Supabase の SQL Editor でこのファイルの内容をそのまま実行してください。
-- 学園祭版の「出店の広告」を保存するテーブルを作ります。通常版のテーブルには一切触りません。
-- 何度実行しても同じ結果になるように書いてあります（再実行しても壊れません）。
--
-- 登録は運営（メンバー）が SQL Editor で行う。アプリからは読むだけにして、
-- 関係ない人が勝手に広告を出したり書き換えたりできないようにしている（書き込み用のポリシーを作らない）。

create table if not exists public.fes_booths (
  id          bigint generated always as identity primary key,
  name        text             not null,                 -- 出店名
  description text,                                      -- ひとこと（メニュー・値段など）
  emoji       text             not null default '🏪',    -- 地図のマーク
  lat         double precision not null,                 -- 緯度
  lng         double precision not null,                 -- 経度
  place       text,                                      -- 場所の説明（例: 「3号館 1F」「中央広場」）
  indoor      boolean          not null default false,   -- 建物の中なら true（GPSがずれるので広めの範囲で知らせる）
  active      boolean          not null default true,    -- false にするとアプリに出なくなる（削除しなくてよい）
  created_at  timestamptz      not null default now()
);

alter table public.fes_booths enable row level security;

-- ⚠️ SELECTポリシーは必須（無いとアプリから読めない）。表示中（active）の出店だけ誰でも読める
drop policy if exists "read active booths" on public.fes_booths;
create policy "read active booths"
  on public.fes_booths for select
  using (active);

notify pgrst, 'reload schema';

-- ---------------------------------------------------------------------------
-- 出店の登録のしかた（登録するときだけコメントを外して実行）
-- ---------------------------------------------------------------------------
-- 緯度・経度は、Googleマップで出店の場所を長押しすると出る「35.61xxx, 139.29xxx」をそのまま使う。
--
-- insert into public.fes_booths (name, description, emoji, lat, lng, place, indoor) values
--   ('焼きそば屋 ○○サークル', '1パック300円。大盛りあります', '🍜', 35.61560, 139.29630, '中央広場', false),
--   ('写真展 △△部',          '入場無料・11時〜16時',       '📷', 35.61600, 139.29700, '3号館 1F', true);
--
-- 表示をやめる:   update public.fes_booths set active = false where name = '焼きそば屋 ○○サークル';
-- 一覧を確認する: select id, name, place, indoor, active from public.fes_booths order by id;
