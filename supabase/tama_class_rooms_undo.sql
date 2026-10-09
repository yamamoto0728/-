-- Supabase の SQL Editor で実行してください（2026-10-09）。
-- あおの指示「授業の部屋を勝手に作らないで。だれかがオーナーとして作ったコミュニティを表示するだけに」で、
-- supabase/tama_class_rooms.sql で作った「オーナーなしの授業の部屋を1タップで作る」しくみをやめる。
--
-- 1. 作る関数を消す（古い版のアプリが残っていても、もう部屋を作れないように）
drop function if exists public.tama_class_room_join(text);
drop function if exists public.tama_class_rooms();
notify pgrst, 'reload schema';

-- 2. すでに作られたオーナーなしの授業の部屋を確かめる（読むだけ。部屋の名前・参加している人数・投稿の数）
select r.id::text as 部屋のid, r.name as 部屋の名前,
       (select count(*) from public.tama_room_members m where m.room_id::text = r.id::text)  as 参加している人,
       (select count(*) from public.tama_room_messages x where x.room_id::text = r.id::text) as 投稿の数,
       r.created_at as 作られた日時
  from public.tama_rooms r
 where r.owner_id is null
   and exists (select 1 from jsonb_array_elements(r.conditions) c where c->>'k' = 'cname')
 order by r.created_at;

-- 3. 2で出た部屋を消す（投稿・参加者ごと。元に戻せない）。消す時だけ、下の行の先頭の「-- 」を消して実行する
-- select public.tama_room_purge(r.id::text) from public.tama_rooms r where r.owner_id is null and exists (select 1 from jsonb_array_elements(r.conditions) c where c->>'k' = 'cname');
