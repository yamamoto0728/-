-- Supabase の SQL Editor でこのファイルの内容をそのまま実行してください。
-- 「プロフィールを消して共有をやめる」で、トーク・友達も消せるようにする関数を作ります（2026-10-05 アイデア班のフィードバック）。
-- 多摩キャン版（tama_forget_talks）と学園祭版（fes_forget_talks）の2つ。ほかのテーブルの形には触りません。
-- 何度実行しても同じ結果になるように書いてあります（再実行しても壊れません）。
--
-- なぜ関数にするか：トークは2人で1つなので、相手の発言・相手からのいいねは本人の権限（RLS）では消せない。
-- security definer の関数の中で、auth.uid() が関わる行だけをまとめて消す（1回の呼び出しで全部消えるか、何も消えないか）。
-- plpgsql で書いているので、fes_ のテーブルがまだ無くても作成はでき、呼んだ時に初めてエラーになる。
--
-- 消すもの：1対1のトーク（自分が入っている会話は相手の発言も）・いいね（送った／届いた）・友達（申請中も）・
--           時間割の共有（見せている／見せてもらっている）・コミュニティの参加と自分の投稿・いまどこ
-- 残すもの：通報・ブロック（安全のため）・すれ違いの記録（研究データ。プロフィールが消えるので一覧には出ない）・
--           自分が作ったコミュニティの部屋（ほかの人の投稿があるため）

create or replace function public.tama_forget_talks()
returns void
language plpgsql volatile security definer set search_path = public
as $$
declare
  me uuid := auth.uid();
begin
  if me is null then return; end if;
  -- トークの match_key は2人のIDを並べて '__' でつないだもの（アプリの chatKey）
  delete from public.tama_messages
   where split_part(match_key, '__', 1) = me::text or split_part(match_key, '__', 2) = me::text;
  delete from public.tama_likes where from_id = me or to_id = me;
  delete from public.tama_friends where from_id = me or to_id = me;
  delete from public.tama_timetable_shares where owner_id = me or friend_id = me;
  delete from public.tama_room_messages where from_id = me;
  delete from public.tama_room_members where user_id = me;
  delete from public.tama_presence where id = me;
end $$;

create or replace function public.fes_forget_talks()
returns void
language plpgsql volatile security definer set search_path = public
as $$
declare
  me uuid := auth.uid();
begin
  if me is null then return; end if;
  delete from public.fes_messages
   where split_part(match_key, '__', 1) = me::text or split_part(match_key, '__', 2) = me::text;
  delete from public.fes_likes where from_id = me or to_id = me;
  delete from public.fes_friends where from_id = me or to_id = me;
  delete from public.fes_timetable_shares where owner_id = me or friend_id = me;
  delete from public.fes_room_messages where from_id = me;
  delete from public.fes_room_members where user_id = me;
  delete from public.fes_presence where id = me;
end $$;

revoke all on function public.tama_forget_talks() from public, anon;
revoke all on function public.fes_forget_talks() from public, anon;
grant execute on function public.tama_forget_talks() to authenticated;
grant execute on function public.fes_forget_talks() to authenticated;

notify pgrst, 'reload schema';

-- 確認: 2行（fes_forget_talks / tama_forget_talks）出ればOK
select proname from pg_proc where proname in ('tama_forget_talks', 'fes_forget_talks') order by proname;
