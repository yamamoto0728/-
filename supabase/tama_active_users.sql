-- 多摩キャン版：登録している人数と、続けて使っている人数・割合（2026-10-09 あおの依頼）。
-- ⚠️ 読むだけのSQL（データは変えない）。Supabase の SQL Editor に貼って Run すれば、いつでも今の数が出る。
-- 前提：supabase/tama_retention.sql を実行済み（開いた日の記録 tama_visits。1人1日1行。2026-10-01 から記録している）。
--
-- 「続けて使っている」は決め方で数が変わるので、3通り出す（割合は、いま登録している人数で割ったもの）
--   ・直近14日のうち3日以上開いた人
--   ・今週（直近7日）と先週（その前の7日）の両方で開いた人＝2週続けて
--   ・直近7日に1回でも開いた人（参考）
-- 注意
--   ・数えるのは、いまプロフィールが残っている人だけ（プロフィールを消した人は、開いた日の記録も消える）
--   ・運営が URL に #debug を付けて開いた分は記録されない。メンバーがふつうに使った分は入っている
--   ・2026-10-01 より前に使っていた分は記録が無い
with today as (
  select (now() at time zone 'Asia/Tokyo')::date as d
), reg as (
  select id::text as id from public.tama_profiles
), per as (
  select v.user_id::text as id,
         count(*) filter (where v.day > (select d from today) - 7)  as d7,
         count(*) filter (where v.day > (select d from today) - 14) as d14,
         bool_or(v.day > (select d from today) - 7)                                              as this_week,
         bool_or(v.day <= (select d from today) - 7 and v.day > (select d from today) - 14)      as last_week
    from public.tama_visits v
   where v.user_id::text in (select id from reg)
   group by v.user_id
)
select
  (select count(*) from reg)                                                                            as 登録している人,
  count(*) filter (where d14 >= 3)                                                                       as 続けて使っている人_14日で3日以上,
  round(100.0 * count(*) filter (where d14 >= 3) / nullif((select count(*) from reg), 0), 1)            as 割合_14日で3日以上,
  count(*) filter (where this_week and last_week)                                                        as 続けて使っている人_2週続けて,
  round(100.0 * count(*) filter (where this_week and last_week) / nullif((select count(*) from reg), 0), 1) as 割合_2週続けて,
  count(*) filter (where d7 >= 1)                                                                        as 直近7日に開いた人,
  round(100.0 * count(*) filter (where d7 >= 1) / nullif((select count(*) from reg), 0), 1)             as 割合_直近7日
from per;
