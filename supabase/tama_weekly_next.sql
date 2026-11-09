-- 運営が来週の「今週のイベント」のテーマを入れる時に使う（2026-11-10。テーマは運営だけが出す）。
-- 使い方：下の3か所（テーマの名前・種類・選択肢）を書きかえて、Supabase の SQL Editor で実行する。
--   ・入るのは「来週の月曜」の週。月曜になると、ホームの上のバナーとシートのカードに出る
--   ・種類（kind）：goal 目標／like 好きなもの／season 季節／campus 学内のこと／fun 遊び／worry 悩み（悩みは部屋を作らず、人数だけ）
--   ・選択肢は20文字まで・8つくらい。答える人は自分で書くこともできる
--   ・同じ週に2つ出したい時は、もう1回、名前と選択肢を変えて実行する
--   ・絵文字や全角の「？」は入れない（SQL Editor が壊すことがある）
with t as (
  insert into public.tama_wk_themes (week, title, norm, kind, source, status)
  select public.tama_wk_week() + 7, '冬休みにやりたいこと', public.tama_norm('冬休みにやりたいこと'), 'goal', 'ops', 'active'
   where not exists (select 1 from public.tama_wk_themes where week = public.tama_wk_week() + 7 and norm = public.tama_norm('冬休みにやりたいこと'))
  returning id
)
insert into public.tama_wk_opts (theme_id, label, norm)
select t.id, x, public.tama_norm(x)
  from t cross join unnest(array['旅行','帰省','バイト','免許をとる','資格の勉強','ライブ・イベント','ゆっくり休む','新しい趣味']) x
on conflict do nothing;

-- 確かめ：来週のテーマと選択肢の数
select t.week, t.title, t.kind, (select count(*) from public.tama_wk_opts o where o.theme_id = t.id) as opts
  from public.tama_wk_themes t where t.week >= public.tama_wk_week() and t.source = 'ops' order by t.week, t.id;
