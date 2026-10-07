-- 多摩キャン版の研究用の集計（2026-10-07、提案②「孤独感が減ったかを測る」）。
-- ⚠️ 読むだけのSQL（データは変えない）。Supabase の SQL Editor で、見たい所（A〜E のどれか1つ）だけを選んで実行する。
-- 先に supabase/tama_meet.sql を実行済みであること。
--
-- 測り方（使う人の心理的ハードルにならないように、2026-10-07 あおと決めた）
--   ・孤独感：「ひとこと」（tama_checkins）。UCLA孤独感尺度 第3版の前向きな言い方の3項目を、今日のお題の後に1日1問・任意で聞く。
--            14日ごとにくり返す。孤独感の得点 = (5 - value) を3問ぶん足したもの（3〜12、高いほど孤独）
--   ・会えた割合：本人には聞かない。行動から推定する
--       トーク後にすれ違った … おたがいにいいねした後に、2人が50m以内にいた（2人ともアプリを開いていた時だけ記録される）
--       コードで友達         … 目の前で4桁のコードを交換した（申請と承認が同時）
--       ふたりのお題をその場で … 同じお題に2人が10分以内に答えた
--   ・続いたつながり：友達になった・トーク後に2回以上すれ違った
-- 参加者番号はユーザーIDの先頭8文字（アプリのマイページの一番下・Googleフォームの事前入力と同じ）。
-- ID の型の違い（uuid / text）で失敗しないよう、くらべる所はすべて ::text にそろえている。

-- ---------------------------------------------------------------------------
-- A. 人・回ごとの「ひとこと」（3問そろった回だけ得点が出る）
-- ---------------------------------------------------------------------------
select left(user_id::text, 8)                               as 参加者番号,
       wave                                                 as 回,
       min(created_at)                                      as 答え始めた日時,
       count(value)                                         as 答えた数,
       count(*) - count(value)                              as とばした数,
       case when count(value) = 3 then sum(5 - value) end   as 孤独感の得点
  from public.tama_checkins
 group by user_id, wave
 order by 1, 2;

-- ---------------------------------------------------------------------------
-- B. 使い始め（3問そろった最初の回）と、いちばん新しい回の差（マイナス＝孤独感が減った）
-- ---------------------------------------------------------------------------
with s as (
  select user_id, wave, sum(5 - value) as score
    from public.tama_checkins
   group by user_id, wave
  having count(value) = 3
), f as (
  select distinct on (user_id) user_id, wave, score from s order by user_id, wave
), l as (
  select distinct on (user_id) user_id, wave, score from s order by user_id, wave desc
)
select left(f.user_id::text, 8) as 参加者番号,
       f.wave as 最初の回, f.score as 最初の得点,
       l.wave as 最新の回, l.score as 最新の得点,
       l.score - f.score as 差
  from f join l using (user_id)
 where l.wave > f.wave
 order by 差;

-- ---------------------------------------------------------------------------
-- C. おたがいにいいねした組ごとに、会えたと推定できるか
-- ---------------------------------------------------------------------------
with m as (     -- 1組1行。トークの始まり＝2人のいいねの遅いほう（アプリと同じ）
  select a.from_id::text as a, a.to_id::text as b, greatest(a.created_at, b.created_at) as matched_at
    from public.tama_likes a
    join public.tama_likes b on b.from_id::text = a.to_id::text and b.to_id::text = a.from_id::text
   where a.from_id::text < a.to_id::text
), e as (       -- すれ違い1回ずつ（どちらが記録したかを問わない）
  select owner_id::text as x, other_id::text as y, at from public.tama_encounter_log
), f as (       -- 友達。申請と承認が1秒以内なら、目の前で4桁のコードを交換した
  select from_id::text as x, to_id::text as y,
         responded_at is not null and responded_at - created_at < interval '1 second' as by_code
    from public.tama_friends where status = 'accepted'
), d as (       -- ふたりのお題を、2人が10分以内に答えた
  select distinct p.match_key
    from public.tama_messages p
    join public.tama_messages q
      on q.match_key = p.match_key and q.from_id::text <> p.from_id::text
     and substring(q.text from '#duo:(\d+):\d+$') = substring(p.text from '#duo:(\d+):\d+$')
     and q.created_at between p.created_at and p.created_at + interval '10 minutes'
   where p.text ~ '#duo:\d+:\d+$'
)
select left(m.a, 8) as 参加者番号1, left(m.b, 8) as 参加者番号2, m.matched_at as トーク開始,
       (select min(e.at) from e where ((e.x = m.a and e.y = m.b) or (e.x = m.b and e.y = m.a)) and e.at > m.matched_at)
                                                                                     as トーク後に初めてすれ違った,
       (select count(distinct (e.at at time zone 'Asia/Tokyo')::date) from e
         where ((e.x = m.a and e.y = m.b) or (e.x = m.b and e.y = m.a)) and e.at > m.matched_at)
                                                                                     as トーク後にすれ違った日数,
       exists (select 1 from f where (f.x = m.a and f.y = m.b) or (f.x = m.b and f.y = m.a))                as 友達になった,
       exists (select 1 from f where ((f.x = m.a and f.y = m.b) or (f.x = m.b and f.y = m.a)) and f.by_code) as コードで友達,
       exists (select 1 from d where d.match_key in (m.a || '__' || m.b, m.b || '__' || m.a))              as ふたりのお題をその場で
  from m
 order by m.matched_at;

-- ---------------------------------------------------------------------------
-- D. 人ごとのまとめ（孤独感の差と、会えた・続いたつながりを並べる。スプレッドシートに書き出して分析する）
--    ⚠️ 1回ずつのすれ違い（tama_encounter_log）は 2026-10-07 から。それより前のトークは、
--       tama_encounters の「最後にすれ違った時刻」がトークの後かどうかで補っている
-- ---------------------------------------------------------------------------
with s as (
  select user_id::text as u, wave, sum(5 - value) as score
    from public.tama_checkins group by user_id, wave having count(value) = 3
), f0 as (
  select distinct on (u) u, wave, score from s order by u, wave
), l0 as (
  select distinct on (u) u, wave, score from s order by u, wave desc
), m as (       -- 両方向（u から見た相手 p）
  select a.from_id::text as u, a.to_id::text as p, greatest(a.created_at, b.created_at) as matched_at
    from public.tama_likes a
    join public.tama_likes b on b.from_id::text = a.to_id::text and b.to_id::text = a.from_id::text
), met as (
  select distinct m.u, m.p from m
   where exists (select 1 from public.tama_encounter_log e
                  where ((e.owner_id::text = m.u and e.other_id::text = m.p) or (e.owner_id::text = m.p and e.other_id::text = m.u))
                    and e.at > m.matched_at)
      or exists (select 1 from public.tama_encounters x
                  where ((x.owner_id::text = m.u and x.other_id::text = m.p) or (x.owner_id::text = m.p and x.other_id::text = m.u))
                    and x.last_at::timestamptz > m.matched_at)
), fr as (
  select from_id::text as u, to_id::text as p, responded_at - created_at < interval '1 second' as by_code
    from public.tama_friends where status = 'accepted'
  union all
  select to_id::text, from_id::text, responded_at - created_at < interval '1 second'
    from public.tama_friends where status = 'accepted'
), people as (
  select u from s group by u
)
select left(pp.u, 8)                                                   as 参加者番号,
       f0.score                                                        as 最初の得点,
       case when l0.wave > f0.wave then l0.score end                   as 最新の得点,
       case when l0.wave > f0.wave then l0.score - f0.score end        as 差,
       (select count(*) from m   where m.u = pp.u)                     as トークした人数,
       (select count(*) from met where met.u = pp.u)                   as トーク後に会えた推定,
       (select count(*) from fr  where fr.u = pp.u)                    as 友達,
       (select count(*) from fr  where fr.u = pp.u and fr.by_code)     as コードで友達,
       (select count(distinct e.other_id) from public.tama_encounter_log e where e.owner_id::text = pp.u) as すれ違った人数,
       (select count(distinct (v.day)) from public.tama_visits v where v.user_id::text = pp.u)            as 開いた日数
  from people pp
  join f0 on f0.u = pp.u
  join l0 on l0.u = pp.u
 order by 差 nulls last;

-- ---------------------------------------------------------------------------
-- E. 「トーク後に会えた人がいる人ほど、孤独感が減ったか」（2回以上そろった人だけ）
-- ---------------------------------------------------------------------------
with s as (
  select user_id::text as u, wave, sum(5 - value) as score
    from public.tama_checkins group by user_id, wave having count(value) = 3
), f0 as (
  select distinct on (u) u, wave, score from s order by u, wave
), l0 as (
  select distinct on (u) u, wave, score from s order by u, wave desc
), chg as (
  select f0.u, l0.score - f0.score as diff from f0 join l0 using (u) where l0.wave > f0.wave
), m as (
  select a.from_id::text as u, a.to_id::text as p, greatest(a.created_at, b.created_at) as matched_at
    from public.tama_likes a
    join public.tama_likes b on b.from_id::text = a.to_id::text and b.to_id::text = a.from_id::text
), met as (
  select distinct m.u from m
   where exists (select 1 from public.tama_encounter_log e
                  where ((e.owner_id::text = m.u and e.other_id::text = m.p) or (e.owner_id::text = m.p and e.other_id::text = m.u))
                    and e.at > m.matched_at)
      or exists (select 1 from public.tama_encounters x
                  where ((x.owner_id::text = m.u and x.other_id::text = m.p) or (x.owner_id::text = m.p and x.other_id::text = m.u))
                    and x.last_at::timestamptz > m.matched_at)
)
select case when met.u is not null then 'トーク後に会えた人がいる' else 'いない' end as グループ,
       count(*)                as 人数,
       round(avg(chg.diff), 2) as 孤独感の差の平均,
       min(chg.diff)           as 最小,
       max(chg.diff)           as 最大
  from chg left join met on met.u = chg.u
 group by 1
 order by 1;
