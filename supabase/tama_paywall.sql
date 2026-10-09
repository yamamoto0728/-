-- Supabase の SQL Editor でこのファイルの内容をそのまま実行してください（2026-10-09）。
-- 多摩キャン版の「本来は有料の予定です」の聞き取り（フェイクドアテスト）の答えを記録する表を作ります。ほかの表には触りません。
-- 何度実行しても同じ結果になるように書いてあります。
-- 実行しなくてもアプリは動く（聞き取りの画面が出ず、機能がそのまま使えるだけ）。
--
-- しくみ（あおの決定 2026-10-09）
--   ・「前の日にすれ違った人を見る」「コミュニティを作る」を初めて使う時に1回だけ、
--     「本来は月◯円の予定です（いまは無料・あとで請求されません）」と出し、[月◯円でも使いたい] [無料なら使う] を選んでもらう
--   ・どちらを選んでも機能は使える（押すのに損得が無いので、正直な答えになりやすい）
--   ・金額は人ごとに 100・300・500円のどれか（ユーザーIDから決めるので、同じ人にはいつも同じ金額）
--     → 2026-10-09 あおの指示で 500円に固定した。それより前に記録した行は price に 100・300 も残っている
--   ・利用規約の第4条に記載。プロフィールを消すと、この記録も消える
create table if not exists public.tama_paywall (
  user_id    uuid        not null default auth.uid(),
  feature    text        not null check (feature in ('cross_past', 'room_create')),
  price      int         not null check (price in (100, 300, 500)),
  choice     text        not null check (choice in ('pay', 'free')),   -- pay＝月◯円でも使いたい / free＝無料なら使う
  ver        text,
  created_at timestamptz not null default now(),
  primary key (user_id, feature)
);
alter table public.tama_paywall enable row level security;

drop policy if exists "read own paywall" on public.tama_paywall;
create policy "read own paywall" on public.tama_paywall for select to authenticated using (auth.uid() = user_id);
drop policy if exists "write own paywall" on public.tama_paywall;
create policy "write own paywall" on public.tama_paywall for insert to authenticated with check (auth.uid() = user_id);
drop policy if exists "delete own paywall" on public.tama_paywall;
create policy "delete own paywall" on public.tama_paywall for delete to authenticated using (auth.uid() = user_id);

notify pgrst, 'reload schema';

-- 確認：ポリシーが3つ出ればOK
select policyname from pg_policies where schemaname = 'public' and tablename = 'tama_paywall' order by policyname;

-- ---------------------------------------------------------------------------
-- 集計（読むだけ。見たい時にここだけ選んで実行する）
-- 機能・金額ごとに、答えた人数と「◯円でも使いたい」を選んだ割合
-- ---------------------------------------------------------------------------
-- select feature as 機能, price as 金額,
--        count(*) as 答えた人,
--        count(*) filter (where choice = 'pay') as 払ってでも使いたい,
--        round(100.0 * count(*) filter (where choice = 'pay') / nullif(count(*), 0), 1) as 割合
--   from public.tama_paywall
--  group by feature, price
--  order by feature, price;
