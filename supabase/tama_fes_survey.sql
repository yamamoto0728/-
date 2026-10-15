-- 多摩祭アンケート（アプリの中・1分）と、行動の分析用の書き出し（2026-10-16 あおの依頼）
-- Supabase の SQL Editor でこのファイルの「1」と「2」をそのまま実行してください。何度実行しても同じ結果になります。
-- 実行しなくてもアプリは動く（アンケートのボタンを押すと「準備中」と出るだけ）。
--
-- ねらい：ビジコンの発表で、そのまま使える数を取る（どれも1タップ。自由記述だけ任意）。
--   Q1 ふだん、授業・サークル以外で新しい人と知り合うきっかけは？（課題がある＝市場がある）
--   Q2 多摩祭で、ちかくを使って新しい人と知り合うきっかけは増えた？（課題が少しでも変わったか）
--   Q3 多摩祭で、ちかくをきっかけに新しく出会った人は？（いちばん進んだもの：いいね／トーク／会って話した／友達）
--   Q4 きっかけになったもの（いくつでも）＝どの機能が効いたか
--   Q5 友達にすすめたい？（0〜10。NPS）
--   Q6 多摩祭のあとも使いたい？（続ける気持ち）
--   Q7 学期（半年）パスなら、いくらまで払う？（収益モデルの根拠。ちかくプラスのアンケートと同じ値段の区切り）
--   Q8 ひとこと（任意）
-- 孤独感をそのまま聞く質問はしない（運営の方針）。Q1 は「きっかけ」の多さで聞く。
--
-- 答えは本人だけが読める。みんなの答え（tama_fes_survey_stats）は、答えた人だけが見られ、5人そろうまで人数だけ。ひとことは返さない。

-- ---------------------------------------------------------------------------
-- 1. 答えの表
-- ---------------------------------------------------------------------------
create table if not exists public.tama_fes_survey (
  user_id    uuid primary key,
  day        date not null default ((now() at time zone 'Asia/Tokyo')::date),   -- 答えた日
  chance     text check (chance in ('often', 'sometimes', 'rarely', 'hardly')),
  change     text check (change in ('much', 'little', 'same', 'unknown')),
  met        text check (met in ('none', 'like', 'talk', 'meet', 'friend')),
  via        text[] not null default '{}',
  nps        int  check (nps between 0 and 10),
  keep       text check (keep in ('yes', 'maybe', 'unknown', 'no')),
  price      int  check (price in (0, 100, 300, 500, 1000)),
  comment    text check (comment is null or length(comment) <= 300),
  tester     boolean not null default false,   -- 運営の試し（数字から外す）
  ver        text,
  created_at timestamptz not null default now()
);
alter table public.tama_fes_survey enable row level security;
drop policy if exists "own fes survey insert" on public.tama_fes_survey;
create policy "own fes survey insert" on public.tama_fes_survey for insert to authenticated with check (user_id = auth.uid());
drop policy if exists "own fes survey read" on public.tama_fes_survey;
create policy "own fes survey read" on public.tama_fes_survey for select to authenticated using (user_id = auth.uid());

-- ---------------------------------------------------------------------------
-- 2. みんなの答え（答えた人だけ。5人そろうまでは人数だけ。運営の試しは数えない）
-- ---------------------------------------------------------------------------
create or replace function public.tama_fes_survey_stats()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_total int;
begin
  if auth.uid() is null or not exists (select 1 from public.tama_fes_survey where user_id = auth.uid()) then
    return jsonb_build_object('total', 0);
  end if;
  select count(*)::int into v_total from public.tama_fes_survey where not tester;
  if v_total < 5 then return jsonb_build_object('total', v_total); end if;
  return jsonb_build_object(
    'total',  v_total,
    'chance', coalesce((select jsonb_object_agg(chance, c) from (select chance, count(*)::int c from public.tama_fes_survey where not tester and chance is not null group by chance) x), '{}'::jsonb),
    'change', coalesce((select jsonb_object_agg(change, c) from (select change, count(*)::int c from public.tama_fes_survey where not tester and change is not null group by change) x), '{}'::jsonb),
    'met',    coalesce((select jsonb_object_agg(met, c)    from (select met, count(*)::int c    from public.tama_fes_survey where not tester and met is not null group by met) x), '{}'::jsonb),
    'via',    coalesce((select jsonb_object_agg(v, c)      from (select v, count(*)::int c from public.tama_fes_survey, unnest(via) v where not tester group by v) x), '{}'::jsonb),
    'price',  coalesce((select jsonb_object_agg(price::text, c) from (select price, count(*)::int c from public.tama_fes_survey where not tester and price is not null group by price) x), '{}'::jsonb),
    'nps',    (select round(100.0 * (count(*) filter (where nps >= 9) - count(*) filter (where nps <= 6)) / nullif(count(*), 0))::int
                 from public.tama_fes_survey where not tester and nps is not null));
end $$;
revoke all on function public.tama_fes_survey_stats() from public, anon;
grant execute on function public.tama_fes_survey_stats() to authenticated;

notify pgrst, 'reload schema';

-- 確認：0 から始まる
select count(*) as 多摩祭アンケートの回答 from public.tama_fes_survey;


-- ===========================================================================
-- 3. ビジコン用に見る数（多摩祭のあとに、1つずつ実行）
-- ===========================================================================
-- 3-1. 課題と変化：「きっかけが少ない」人のうち、多摩祭で「増えた」人の割合（いちばん使いやすい1枚）
-- select
--   count(*) filter (where chance in ('rarely','hardly'))                                           as きっかけが少ない,
--   round(100.0 * count(*) filter (where chance in ('rarely','hardly')) / count(*), 1)               as その割合,
--   count(*) filter (where chance in ('rarely','hardly') and change in ('much','little'))           as そのうち増えた,
--   round(100.0 * count(*) filter (where chance in ('rarely','hardly') and change in ('much','little'))
--         / nullif(count(*) filter (where chance in ('rarely','hardly')), 0), 1)                    as 増えた割合
-- from tama_fes_survey where not tester;
--
-- 3-2. 出会いの段階（いいね → トーク → 会って話した → 友達）
-- select met, count(*), round(100.0 * count(*) / sum(count(*)) over (), 1) as 割合 from tama_fes_survey where not tester group by met order by 1;
--
-- 3-3. NPS（9〜10 の割合 − 0〜6 の割合）と、続けて使いたい割合
-- select round(100.0 * (count(*) filter (where nps >= 9) - count(*) filter (where nps <= 6)) / count(*)) as nps,
--        round(100.0 * count(*) filter (where keep in ('yes','maybe')) / count(*), 1) as 続けたい
-- from tama_fes_survey where not tester and nps is not null;
--
-- 3-4. 払ってもいい値段（学期パス）と、300円以上の割合・平均
-- select price, count(*) from tama_fes_survey where not tester group by 1 order by 1;
-- select round(avg(price)) as 平均, round(100.0 * count(*) filter (where price >= 300) / count(*), 1) as 三百円以上 from tama_fes_survey where not tester and price is not null;
--
-- 3-5. 効いた機能
-- select v as きっかけ, count(*) from tama_fes_survey, unnest(via) v where not tester group by 1 order by 2 desc;
--
-- 3-6. ひとこと（発表の「生の声」に。個人が分からない形で引用する）
-- select created_at at time zone 'Asia/Tokyo', comment from tama_fes_survey where comment is not null and not tester order by 1 desc;


-- ===========================================================================
-- 4. Claude で分析する用の書き出し（1人1行。名前・IDは出さない＝ID の代わりに番号）
-- ===========================================================================
-- 多摩祭（10/17・18）に開いた人ごとに、アプリの中での行動（押したボタンの結果）とアンケートの答えを並べる。
-- 実行 → 結果の右上「Export → CSV」→ そのファイルを Claude に渡して「多摩祭の行動とアンケートを分析して」と頼む。
-- ⚠️ チームの6人と試しの人は、下の devs から外している（人数が変わったら直す）
-- with devs(p) as (values ('7e4dda65'),('cacc25fd'),('b5cac0fa'),('5267fbf2'),('1dc61a09'),('56ed5ec3')),
-- fes as (
--   select v.user_id, count(*) as 来た日数, sum(v.opens) as 開いた回数, bool_or(v.push_ok) as 通知オン, bool_or(v.standalone) as ホーム画面のアプリ,
--          max(v.nearby_max) as 近くの人数の最大
--     from tama_visits v
--    where v.day in ('2026-10-17','2026-10-18') and v.on_campus
--      and left(v.user_id::text, 8) not in (select p from devs)
--    group by v.user_id
-- )
-- select row_number() over (order by f.user_id) as 番号,
--        f.来た日数, f.開いた回数, f.通知オン, f.ホーム画面のアプリ, f.近くの人数の最大,
--        (select min(day) from tama_visits w where w.user_id = f.user_id) < '2026-10-17' as 祭りの前から使っていた,
--        (select count(distinct e.other_id) from tama_encounter_log e where e.owner_id = f.user_id and (e.at at time zone 'Asia/Tokyo')::date in ('2026-10-17','2026-10-18')) as すれ違った人数,
--        (select count(*) from tama_likes l where l.from_id = f.user_id and (l.created_at at time zone 'Asia/Tokyo')::date in ('2026-10-17','2026-10-18')) as いいねした,
--        (select count(*) from tama_likes l where l.to_id = f.user_id and (l.created_at at time zone 'Asia/Tokyo')::date in ('2026-10-17','2026-10-18')) as いいねされた,
--        (select count(*) from tama_likes a join tama_likes b on b.from_id = a.to_id and b.to_id = a.from_id
--          where a.from_id = f.user_id and (greatest(a.created_at, b.created_at) at time zone 'Asia/Tokyo')::date in ('2026-10-17','2026-10-18')) as マッチ,
--        (select count(*) from tama_messages m where m.from_id::text = f.user_id::text and (m.created_at at time zone 'Asia/Tokyo')::date in ('2026-10-17','2026-10-18')) as 送ったメッセージ,
--        (select count(*) from tama_friends r where r.status = 'accepted' and (r.from_id = f.user_id or r.to_id = f.user_id)
--          and (coalesce(r.responded_at, r.created_at) at time zone 'Asia/Tokyo')::date in ('2026-10-17','2026-10-18')) as できた友達,
--        (select count(*) from tama_room_members rm where rm.user_id = f.user_id) as 入っているコミュニティ,
--        (select count(*) from tama_push_events pe where pe.user_id = f.user_id and pe.ev = 'open' and (pe.created_at at time zone 'Asia/Tokyo')::date in ('2026-10-17','2026-10-18')) as 通知から開いた,
--        p.fes_attrs->'fes26q'->>'food' as 食べたい, p.fes_attrs->'fes26q'->>'fun' as 楽しみ,
--        p.fes_attrs->'daily'->>'a' as おすすめ, coalesce(jsonb_array_length(p.fes_attrs->'fes26go'), 0) as 見に行くステージ数,
--        p.fes_attrs->>'fes26role' is not null and p.fes_attrs->>'fes26role' <> '' as 出店出演,
--        p.fes_attrs->'faculty' as 学部, p.fes_attrs->'grade' as 学年,
--        s.chance as きっかけ, s.change as 変化, s.met as 出会い, s.via as 効いたもの, s.nps, s.keep as 続けたい, s.price as 学期いくら, s.comment as ひとこと
--   from fes f
--   left join tama_profiles p on p.id::text = f.user_id::text
--   left join tama_fes_survey s on s.user_id::text = f.user_id::text and not s.tester
--  order by 1;
