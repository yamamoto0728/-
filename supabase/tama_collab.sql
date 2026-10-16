-- 🤝 当日決まった「ちかく」コラボの団体・出店（2026-10-16 あおの依頼）
-- Supabase の SQL Editor で「1」をそのまま実行してください。何度実行しても同じ結果になります。
-- 実行しなくてもアプリは今まで通り動きます（コラボの一覧に Saenggi だけが出る）。
--
-- コラボは、出店の表 tama_booths の collab を true にした行。アプリの🎪カードとコミュニティのページに
-- 「🤝 ちかくコラボ：◯◯・◯◯ ほか ›」の1行が出て、押すと一覧（説明・場所・コミュニティ・地図）が開く。
-- room_name を入れると、その名前が入っている「だれでも入れる」コミュニティへのボタンが出る。
-- アプリの更新はいらない（入れたら、開き直した時から出る。出店の読み込みは数分ごと）。

-- ---------------------------------------------------------------------------
-- 1. 列を足す
-- ---------------------------------------------------------------------------
alter table public.tama_booths add column if not exists collab    boolean not null default false;   -- ちかくコラボか
alter table public.tama_booths add column if not exists room_name text;                             -- コミュニティの名前（一部でよい）
notify pgrst, 'reload schema';

-- 確認：いまのコラボ（はじめは 0 行）
select id, name, description, place, room_name, active from public.tama_booths where collab order by id;


-- ===========================================================================
-- 2. 当日の使い方（🅲 サーバー管理ペア。使う時だけ、コメントの -- を外して実行）
-- ===========================================================================
-- 2-1. 新しくコラボの出店・団体を足す（名前・ひとこと・絵文字・場所。コミュニティがあれば room_name も）
-- insert into public.tama_booths (name, description, emoji, place, collab, room_name) values
--   ('たこせん（法政弓の会）', 'アツアツのたこせん 300円', '🐙', '経済学部棟エリア', true, null);
--
-- 2-2. もう出店として登録してある行を、コラボにする
-- update public.tama_booths set collab = true where name like '%たこせん%';
--
-- 2-3. コミュニティができたら、その名前（一部でよい）を入れる
-- update public.tama_booths set room_name = 'たこせん' where name like '%たこせん%';
--
-- 2-4. コラボをやめる（表示だけ外す）
-- update public.tama_booths set collab = false where name like '%たこせん%';
