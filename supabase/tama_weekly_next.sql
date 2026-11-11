-- 運営が「今週のイベント」のテーマを入れる（2026-11-11。テーマは運営だけが出す）。
-- 今週から4週分をまとめて入れる。その週の運営のテーマがもうある週は飛ばす（何度実行しても同じ）。
-- 使い方：下の表（週・テーマ・種類・選択肢）を書きかえて、Supabase の SQL Editor で実行する。
--   ・週：0＝今週、7＝来週、14＝再来週、21＝その次（月曜はじまり・日本時間）
--   ・種類：goal 目標／like 好きなもの／season 季節／campus 学内のこと／fun 遊び／worry 悩み（悩みは部屋を作らず、人数だけ）
--   ・選択肢は20文字まで・8つくらい。答える人は自分で書くこともできる
--   ・絵文字や全角の「？」は入れない（SQL Editor が壊すことがある）
-- ⚠️ テーマが入っていない週は、ホームのバナーもカードも出ない。4週ごとに、この表を次の4週に書きかえて実行する
with plan (wk, title, kind, opts) as (values
  (0,  '最近ハマっていること',       'like',   array['ゲーム','推し活','カフェめぐり','料理','筋トレ','映画・ドラマ','音楽','読書']),
  (7,  '冬休みにやりたいこと',       'goal',   array['旅行','帰省','バイト','免許をとる','資格の勉強','ライブ・イベント','ゆっくり休む','新しい趣味']),
  (14, '多摩キャンパスで好きな場所', 'campus', array['食堂A棟','食堂B棟','図書館','EGG DOME','総合棟','体育館','中庭','バス停']),
  (21, '年末年始の過ごし方',         'season', array['帰省','バイト','旅行','初詣','家でゆっくり','友達と年越し','初売り','大掃除'])
), t as (
  insert into public.tama_wk_themes (week, title, norm, kind, source, status)
  select public.tama_wk_week() + p.wk, p.title, public.tama_norm(p.title), p.kind, 'ops', 'active'
    from plan p
   where not exists (select 1 from public.tama_wk_themes x where x.week = public.tama_wk_week() + p.wk and x.source = 'ops' and x.status = 'active')
  returning id, title
)
insert into public.tama_wk_opts (theme_id, label, norm)
select t.id, o, public.tama_norm(o)
  from t join plan p on p.title = t.title cross join unnest(p.opts) o
on conflict do nothing;

-- 確かめ：今週から先の運営のテーマと、選択肢の数（今週の行があれば、ホームにバナーが出る）
select t.week, t.title, t.kind, (select count(*) from public.tama_wk_opts o where o.theme_id = t.id) as opts
  from public.tama_wk_themes t where t.week >= public.tama_wk_week() and t.source = 'ops' and t.status = 'active' order by t.week, t.id;
