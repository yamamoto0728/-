-- Supabase の SQL Editor でこのファイルの内容をそのまま実行してください（2026-10-14）。
-- 何度実行しても同じ結果になるように書いてあります（再実行しても壊れません）。
-- 実行しなくてもアプリは動く（登録までの人数が数えられない・ちかくプラスのアンケートが出ないだけ）。
--
-- 多摩キャン版（いつもの版）で、登録者と、使い続ける人を増やすための数字を取る。
--   1. 登録までのどこで抜けたか（tama_funnel）：ブラウザで開いた → ホーム画面のアプリで開いた → 登録した、の人数。だれかは記録しない
--   2. ちかくプラスのアンケート（tama_wtp）：一番ほしい機能・半年いくらなら払うか・ひとこと（ビジコンの収益モデルの根拠）

-- ---------------------------------------------------------------------------
-- 1. 登録までのどこで抜けたか
-- ---------------------------------------------------------------------------
-- ev：web（スマホのブラウザで開いた。端末ごとに1日1回）／app（ホーム画面のアプリで、登録の前に開いた。端末ごとに1回）／reg（登録した）
-- src：QR の URL の ?src=（例：fes-booth・flyer-a・class-統計学）。招待のリンクは invite。iPhone は app・reg に付かないことが多い
-- ログイン前（ブラウザで開いただけ）でも書けるように、関数からだけ書く。行の数でしか見ないので、だれかは分からない
create table if not exists public.tama_funnel (
  id         bigserial primary key,
  day        date not null default ((now() at time zone 'Asia/Tokyo')::date),
  ev         text not null check (ev in ('web', 'app', 'reg')),
  src        text check (src is null or length(src) <= 32),
  created_at timestamptz not null default now()
);
create index if not exists tama_funnel_day on public.tama_funnel (day, ev);
alter table public.tama_funnel enable row level security;   -- ポリシーを作らない＝アプリからは直接読めない・書けない

create or replace function public.tama_funnel_log(p_ev text, p_src text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_ev not in ('web', 'app', 'reg') then return; end if;
  insert into public.tama_funnel (ev, src) values (p_ev, nullif(left(regexp_replace(coalesce(p_src, ''), '[^[:alnum:]_ぁ-んァ-ヶ一-龠-]', '', 'g'), 32), ''));
end $$;
revoke all on function public.tama_funnel_log(text, text) from public;
grant execute on function public.tama_funnel_log(text, text) to anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. ちかくプラスのアンケート（実際にお金は取らない。「もしあったら？」を聞く）
-- ---------------------------------------------------------------------------
create table if not exists public.tama_wtp (
  user_id    uuid primary key,
  feature    text not null check (feature in ('slots', 'comm', 'hist', 'look', 'none')),
  price      int  not null check (price in (0, 100, 300, 500, 1000)),
  comment    text check (comment is null or length(comment) <= 200),
  created_at timestamptz not null default now()
);
alter table public.tama_wtp enable row level security;
drop policy if exists "own wtp insert" on public.tama_wtp;
create policy "own wtp insert" on public.tama_wtp for insert to authenticated with check (user_id = auth.uid());
drop policy if exists "own wtp read" on public.tama_wtp;
create policy "own wtp read" on public.tama_wtp for select to authenticated using (user_id = auth.uid());

-- みんなの答え（答えた人だけが見られる。5人そろうまでは人数だけ。ひとことは返さない）
create or replace function public.tama_wtp_stats()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_total int;
begin
  if auth.uid() is null or not exists (select 1 from public.tama_wtp where user_id = auth.uid()) then
    return jsonb_build_object('total', 0);
  end if;
  select count(*)::int into v_total from public.tama_wtp;
  if v_total < 5 then return jsonb_build_object('total', v_total); end if;
  return jsonb_build_object(
    'total', v_total,
    'features', coalesce((select jsonb_object_agg(feature, c) from (select feature, count(*)::int c from public.tama_wtp group by feature) f), '{}'::jsonb),
    'prices',   coalesce((select jsonb_object_agg(price::text, c) from (select price, count(*)::int c from public.tama_wtp group by price) p), '{}'::jsonb));
end $$;
revoke all on function public.tama_wtp_stats() from public, anon;
grant execute on function public.tama_wtp_stats() to authenticated;

notify pgrst, 'reload schema';

-- 確認：どちらも 0 行から始まる
select (select count(*) from public.tama_funnel) as 登録までの記録, (select count(*) from public.tama_wtp) as アンケートの回答;

-- ---------------------------------------------------------------------------
-- 見るための SQL（実行するときだけコメントを外す）
-- ---------------------------------------------------------------------------
-- 日ごとの「ブラウザで開いた → アプリで開いた → 登録した」:
--   select day, count(*) filter (where ev = 'web') as ブラウザで開いた, count(*) filter (where ev = 'app') as アプリで開いた,
--          count(*) filter (where ev = 'reg') as 登録した
--     from tama_funnel group by day order by day desc;
-- QR ごと（src）:
--   select coalesce(src, '（なし）') as src, count(*) filter (where ev = 'web') as 開いた, count(*) filter (where ev = 'reg') as 登録
--     from tama_funnel group by 1 order by 2 desc;
-- 「ちかくをどこで知りましたか」（登録の③）:
--   select coalesce(fes_attrs->>'heard', '（答えていない）') as どこで知った, count(*) from tama_profiles group by 1 order by 2 desc;
-- ちかくプラスのアンケート（ひとこと込み）:
--   select feature as 機能, count(*) from tama_wtp group by 1 order by 2 desc;
--   select price as 半年いくら, count(*) from tama_wtp group by 1 order by 1;
--   select round(avg(price)) as 平均, round(100.0 * count(*) filter (where price >= 300) / count(*), 1) as 三百円以上の割合 from tama_wtp;
--   select created_at at time zone 'Asia/Tokyo', feature, price, comment from tama_wtp where comment is not null order by created_at desc;
