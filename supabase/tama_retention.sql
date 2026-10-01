-- Supabase の SQL Editor でこのファイルの内容をそのまま実行してください。
-- 多摩キャン版の「入れたい・続けたい」の改善（2026-10-01）に必要なものを作ります。ほかのテーブルの中身には触りません。
-- 何度実行しても同じ結果になるように書いてあります（再実行しても壊れません）。
-- ⚠️ 先に supabase/tama_tables.sql を実行済みであること（2026-09-15 に実行済み）。
-- 実行しなくてもアプリは今まで通り動く（お題の「みんなの答え」・ホーム画面追加の案内の人数が出ず、開いた日の記録がされないだけ）。
--
-- 作るもの
--   1. tama_daily_stats(...)  今日のお題の「みんなの答え」（人数と割合）を返す
--   2. tama_public_count()    ホーム画面に追加する前の案内に出す「登録した人数・今日使った人数」を返す（ログイン前でも呼べる）
--   3. tama_visits            開いた日の記録（1人1日1行。位置は記録しない）と、それを書く関数 tama_log_visit(...)

-- ---------------------------------------------------------------------------
-- 1. 今日のお題の「みんなの答え」
-- ---------------------------------------------------------------------------
-- 答えはプロフィール（tama_profiles.fes_attrs）の daily = {d:日付, q:お題の番号, a:答え, n:そろえた答え} に入っている。
-- 次の日に答えると、前の日の答えは daily_prev に移る（アプリ側）ので、「昨日の結果」も数えられる。
-- 人数が少ないと割合から誰が何と答えたか分かってしまうので（あおの決定、2026-10-01）:
--   ・回答が5人未満の間は人数（total）だけを返す
--   ・自由記述（p_free）は、3人以上が同じ答えのものだけ・多い順に3つまで返す
create or replace function public.tama_daily_stats(p_d text, p_q int, p_free boolean default false)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  v_total  int;
  v_groups jsonb;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  with ans as (
    select coalesce(nullif(x->>'n', ''), lower(x->>'a')) as k, x->>'a' as a
      from public.tama_profiles p
      cross join lateral (values (p.fes_attrs->'daily'), (p.fes_attrs->'daily_prev')) v(x)
     where x is not null
       and x->>'d' = p_d
       and x->>'q' = p_q::text
       and coalesce(x->>'a', '') <> ''
  ), g as (
    select k, min(a) as a, count(*)::int as c from ans group by k
  )
  select (select count(*)::int from ans),
         coalesce((select jsonb_agg(jsonb_build_object('a', s.a, 'c', s.c) order by s.c desc, s.a)
                     from (select * from g
                            where not p_free or g.c >= 3
                            order by g.c desc, g.a
                            limit case when p_free then 3 else 10 end) s), '[]'::jsonb)
    into v_total, v_groups;
  if v_total < 5 then return jsonb_build_object('total', v_total); end if;
  return jsonb_build_object('total', v_total, 'groups', v_groups);
end $$;

revoke all on function public.tama_daily_stats(text, int, boolean) from public, anon;
grant execute on function public.tama_daily_stats(text, int, boolean) to authenticated;

-- ---------------------------------------------------------------------------
-- 2. ホーム画面に追加する前の案内に出す人数
-- ---------------------------------------------------------------------------
-- スマホのブラウザで開いた人は、ホーム画面に追加するまでログインしない（Safari とアプリで別人になるのを防ぐため）。
-- そのためログイン前（anon）でも呼べるようにし、数だけを返す（名前・位置などは返さない）。
-- 少ない数をそのまま見せると逆効果なので、10人未満の時はアプリ側で出さない
create or replace function public.tama_public_count()
returns jsonb
language sql stable security definer set search_path = public
as $$
  select jsonb_build_object(
    'total', (select count(*) from public.tama_profiles),
    'today', (select count(*) from public.tama_profiles
               where updated_at::timestamptz >= (date_trunc('day', now() at time zone 'Asia/Tokyo') at time zone 'Asia/Tokyo'))
  )
$$;

revoke all on function public.tama_public_count() from public;
grant execute on function public.tama_public_count() to anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. 開いた日の記録（続けて使われているかを測る）
-- ---------------------------------------------------------------------------
-- 1人1日（日本時間）1行。位置は記録しない（あおの決定、2026-10-01。利用規約の第4条に記載）。
--   opens      その日にアプリを開いた回数（5分以上あけて開き直したら1回と数える。数えるのはアプリ側）
--   on_campus  その日、キャンパスの中で位置が取れたか
--   nearby_max その日「いまキャンパスにいる人」に出た人数の最大
--   push_ok    通知を許可していたか
--   standalone ホーム画面のアプリから開いたか（PCのブラウザは false）
--   daily      その日のお題に答えたか
--   ver        アプリの版（変更の前後で比べるため）
-- ポリシーを作らない＝アプリから直接は読めも書けもしない（下の関数だけが書く）
create table if not exists public.tama_visits (
  user_id    uuid        not null,
  day        date        not null,
  opens      int         not null default 0,
  first_at   timestamptz not null default now(),
  last_at    timestamptz not null default now(),
  on_campus  boolean     not null default false,
  nearby_max int         not null default 0,
  push_ok    boolean     not null default false,
  standalone boolean     not null default false,
  daily      boolean     not null default false,
  ver        text,
  primary key (user_id, day)
);
alter table public.tama_visits enable row level security;

create or replace function public.tama_log_visit(
  p_open boolean, p_on_campus boolean, p_nearby int, p_push boolean, p_standalone boolean, p_daily boolean, p_ver text)
returns void
language plpgsql volatile security definer set search_path = public
as $$
declare
  me uuid := auth.uid();
  d  date := (now() at time zone 'Asia/Tokyo')::date;
begin
  if me is null then return; end if;
  insert into public.tama_visits as v (user_id, day, opens, on_campus, nearby_max, push_ok, standalone, daily, ver)
  values (me, d, case when p_open then 1 else 0 end, coalesce(p_on_campus, false),
          least(greatest(coalesce(p_nearby, 0), 0), 10000), coalesce(p_push, false),
          coalesce(p_standalone, false), coalesce(p_daily, false), left(p_ver, 20))
  on conflict (user_id, day) do update set
    opens      = v.opens + case when p_open then 1 else 0 end,
    last_at    = now(),
    on_campus  = v.on_campus or coalesce(p_on_campus, false),
    nearby_max = greatest(v.nearby_max, least(greatest(coalesce(p_nearby, 0), 0), 10000)),
    push_ok    = v.push_ok or coalesce(p_push, false),
    standalone = v.standalone or coalesce(p_standalone, false),
    daily      = v.daily or coalesce(p_daily, false),
    ver        = coalesce(left(p_ver, 20), v.ver);
end $$;

-- 「プロフィールを消す」を押した人の記録を消す（利用規約 第10条「いつでも自分の情報を削除できます」）
create or replace function public.tama_forget_visits()
returns void
language sql volatile security definer set search_path = public
as $$
  delete from public.tama_visits where user_id = auth.uid();
$$;

revoke all on function public.tama_log_visit(boolean, boolean, int, boolean, boolean, boolean, text) from public, anon;
revoke all on function public.tama_forget_visits() from public, anon;
grant execute on function public.tama_log_visit(boolean, boolean, int, boolean, boolean, boolean, text) to authenticated;
grant execute on function public.tama_forget_visits() to authenticated;

notify pgrst, 'reload schema';

-- 確認: 関数が4行、tama_visits が1行出ればOK
select proname from pg_proc where proname in ('tama_daily_stats', 'tama_public_count', 'tama_log_visit', 'tama_forget_visits') order by proname;
select tablename from pg_tables where schemaname = 'public' and tablename = 'tama_visits';

-- ---------------------------------------------------------------------------
-- 続けて使われているかを見る（実行するときだけコメントを外す）
-- ---------------------------------------------------------------------------
-- 初めて開いた日ごとに、その後の何日目に戻ってきたか（0日目＝初日）:
--   with f as (select user_id, min(day) as d0 from public.tama_visits group by user_id)
--   select f.d0, (v.day - f.d0) as nth_day, count(*) as people
--     from public.tama_visits v join f using (user_id)
--    group by 1, 2 order by 1, 2;
-- 平日5日のうち何日開いたか（週ごと）:
--   select date_trunc('week', day)::date as week, user_id, count(*) filter (where extract(isodow from day) <= 5) as weekdays
--     from public.tama_visits group by 1, 2 order by 1, 3 desc;

-- ---------------------------------------------------------------------------
-- 実験が終わったあと（データを書き出してから、実行するときだけコメントを外す）
-- ---------------------------------------------------------------------------
-- drop table if exists public.tama_visits;
-- drop function if exists public.tama_log_visit(boolean, boolean, int, boolean, boolean, boolean, text);
-- drop function if exists public.tama_forget_visits();
-- drop function if exists public.tama_daily_stats(text, int, boolean);
-- drop function if exists public.tama_public_count();
