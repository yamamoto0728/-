-- 多摩祭（2026-10-17・18）の数字をまとめて見る SQL（2026-10-14）。
-- 見るだけ（何も書きかえない）。SQL Editor で、見たいものを1つずつ選んで実行する（全部まとめて実行すると最後の結果しか出ないため）。
-- 前提：tama_retention.sql・tama_meet.sql・tama_notify.sql・tama_tamasai.sql・tama_growth.sql を実行済み。
-- ビジコンで使う時は「数」と「割合」を一緒に出す（例：参加 83人のうち、2日とも来た人 21人＝25%）。
-- チームの6人は除いて数えたい時は、各 SQL の where に  and user_id not in (select id from tama_profiles where name in ('あお','しゅうすけ'))  のように足す。

-- ① 参加した人（その日にキャンパスで開いた人）・初めての人・2日とも来た人
select v.day as 日,
       count(*) as 参加,
       count(*) filter (where not exists (select 1 from tama_visits w where w.user_id = v.user_id and w.day < v.day)) as この日が初めて,
       count(*) filter (where v.push_ok) as 通知オン
  from tama_visits v
 where v.day in ('2026-10-17', '2026-10-18') and v.on_campus
 group by v.day order by v.day;

select count(*) as 二日とも来た人
  from (select user_id from tama_visits where day in ('2026-10-17', '2026-10-18') and on_campus group by user_id having count(*) = 2) x;

-- ② 多摩祭のあとも使った人（多摩祭に来た人のうち、10/19〜10/25 にもう一度開いた人）
with fes as (select distinct user_id from tama_visits where day in ('2026-10-17', '2026-10-18') and on_campus)
select count(*) as 多摩祭に来た人,
       count(*) filter (where exists (select 1 from tama_visits w where w.user_id = fes.user_id and w.day between '2026-10-19' and '2026-10-25')) as 翌週も開いた人
  from fes;

-- ③ 登録までのどこで抜けたか（日ごと）と、QR ごと
select day as 日, count(*) filter (where ev = 'web') as ブラウザで開いた, count(*) filter (where ev = 'app') as アプリで開いた, count(*) filter (where ev = 'reg') as 登録した
  from tama_funnel where day in ('2026-10-17', '2026-10-18') group by day order by day;
select coalesce(src, '（なし）') as QR, count(*) filter (where ev = 'web') as 開いた, count(*) filter (where ev = 'reg') as 登録した
  from tama_funnel where day in ('2026-10-17', '2026-10-18') group by 1 order by 2 desc;

-- ④ 「ちかくをどこで知りましたか」（多摩祭の日に初めて開いた人）
with first as (select user_id, min(day) d0 from tama_visits group by user_id)
select coalesce(p.fes_attrs->>'heard', '（答えていない）') as どこで知った, count(*)
  from first f join tama_profiles p on p.id = f.user_id
 where f.d0 in ('2026-10-17', '2026-10-18') group by 1 order by 2 desc;

-- ⑤ すれ違い（のべ回数・すれ違った2人の組の数）
select (at at time zone 'Asia/Tokyo')::date as 日, count(*) as のべ, count(distinct least(owner_id::text, other_id::text) || greatest(owner_id::text, other_id::text)) as 組
  from tama_encounter_log
 where (at at time zone 'Asia/Tokyo')::date in ('2026-10-17', '2026-10-18') group by 1 order by 1;

-- ⑥ いいね・友達（多摩祭の日に送られたもの・成立したもの）
select (created_at at time zone 'Asia/Tokyo')::date as 日, count(*) as いいね
  from tama_likes where (created_at at time zone 'Asia/Tokyo')::date in ('2026-10-17', '2026-10-18') group by 1 order by 1;
select (responded_at at time zone 'Asia/Tokyo')::date as 日, count(*) as 友達になった組
  from tama_friends where status = 'accepted' and (responded_at at time zone 'Asia/Tokyo')::date in ('2026-10-17', '2026-10-18') group by 1 order by 1;

-- ⑦ ちかくタイム（祭りの4回）の答えた人数
select s.starts_at at time zone 'Asia/Tokyo' as 時刻, s.q as お題,
       count(p.id) filter (where p.fes_attrs->'ct'->>'a' = s.o1) as 答え1, count(p.id) filter (where p.fes_attrs->'ct'->>'a' = s.o2) as 答え2
  from tama_ct_slots s left join tama_profiles p on p.fes_attrs->'ct'->>'id' = s.id::text
 where (s.starts_at at time zone 'Asia/Tokyo')::date in ('2026-10-17', '2026-10-18')
 group by s.id, s.starts_at, s.q order by s.starts_at;
-- ⚠️ ちかくタイムの答えは「最後に答えた回」だけがプロフィールに残る（前の回の答えは上書き）。正確な数は、その回のすぐ後に見ること

-- ⑧ 祭りの質問（食べたいもの・楽しみなこと）
select 'food' as 質問, fes_attrs->'fes26q'->>'food' as 答え, count(*) from tama_profiles where fes_attrs->'fes26q'->>'food' is not null group by 2
union all
select 'fun', fes_attrs->'fes26q'->>'fun', count(*) from tama_profiles where fes_attrs->'fes26q'->>'fun' is not null group by 2
order by 1, 3 desc;

-- ⑨ 出店のクーポン（使われた数・お会計の合計）＝ 法人向けモデルの根拠
select b.name as 出店, b.coupon as クーポン, count(u.id) as 使われた数, coalesce(sum(u.amount), 0) as お会計の合計, count(u.amount) as 金額を入れた数
  from tama_booths b left join tama_coupon_uses u on u.booth_id = b.id
 group by b.id, b.name, b.coupon order by 3 desc;

-- ⑩ 通知の「届けた → 開いた」（多摩祭の2日間）
select kind as 種類, count(*) filter (where ev = 'sent') as 届けた, count(*) filter (where ev = 'open') as 開いた,
       round(100.0 * count(*) filter (where ev = 'open') / nullif(count(*) filter (where ev = 'sent'), 0), 1) as 開いた割合
  from tama_push_events where (created_at at time zone 'Asia/Tokyo')::date in ('2026-10-17', '2026-10-18')
 group by kind order by 2 desc;

-- ⑪ 多摩祭のバッジを持っている人数
select b as バッジ, count(*) from tama_profiles, jsonb_array_elements_text(coalesce(fes_attrs->'badges', '[]'::jsonb)) b
 where b in ('fes26', 'fes26x', 'fesgoal') group by b;

-- ⑫ アンケート：多摩祭のアンケートの案内を押した人数（Googleフォームの回答数はフォーム側で見る）・ちかくプラスのアンケート
select count(*) filter (where fes_attrs ? 'fes26sv') as 多摩祭アンケートを押した人 from tama_profiles;
select feature as 一番ほしい機能, count(*) from tama_wtp group by 1 order by 2 desc;
select price as 半年いくらなら払う, count(*) from tama_wtp group by 1 order by 1;
