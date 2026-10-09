-- Supabase の SQL Editor でこのファイルの内容をそのまま実行してください（2026-10-09）。
-- 何度実行しても同じ結果になるように書いてあります（再実行しても壊れません）。
-- 実行しなくてもアプリは今まで通り動く（通報の「くわしく」「その時のやりとり」が残らないだけ）。
--
-- あおの依頼「Table Editor のメッセージの欄を、id じゃなくてユーザーネームで見られるように」「理由をもとに通報して、その通報をためる所を」。
--
-- 1. 通報（tama_reports）に列を足す
--    detail：通報した人が書いた「くわしく」（任意）
--    evidence：通報した時のやりとり（トークなら直近20件、コミュニティならその人の直近の投稿、プロフィール）。あとで相手が消しても確かめられるように
--    status：運営の対応（'未対応' → Table Editor で '対応中' '対応済み' などに書き換える）／memo：運営のメモ
-- 2. 運営用の表（ビュー）を admin スキーマに作る。Table Editor の左上のスキーマを public → admin に切り替えると見られる
--      admin.talk       … トーク（24時間・友達）を、送った人・相手の名前つきで
--      admin.community  … コミュニティの投稿を、コミュニティ名・書いた人の名前つきで
--      admin.reports    … 通報を、通報した人・された人の名前と、同じ人への通報の数つきで
--    ⚠️ admin スキーマはアプリ（API）からは読めない（anon・authenticated に権限を渡さない。API に出すスキーマにも足さない）。
--       public にビューを作ると、ビューは RLS を通らないので、アプリからだれでも全部のメッセージを読めてしまうため、public には作らない

-- 1. 通報の列
alter table public.tama_reports add column if not exists detail     text;
alter table public.tama_reports add column if not exists evidence   jsonb;
alter table public.tama_reports add column if not exists status     text not null default '未対応';
alter table public.tama_reports add column if not exists memo       text;
alter table public.tama_reports add column if not exists created_at timestamptz not null default now();
notify pgrst, 'reload schema';

-- 2. 運営用の表
create schema if not exists admin;
revoke all on schema admin from public, anon, authenticated;

create or replace view admin.talk as
select m.created_at                                    as "日時",
       coalesce(fp.name, '（消えた人）')                as "送った人",
       coalesce(tp.name, '（消えた人）')                as "相手",
       m.text                                          as "メッセージ",
       case when exists (select 1 from public.tama_friends f
                          where f.status = 'accepted'
                            and ((f.from_id::text = m.from_id::text and f.to_id::text = o.oid)
                              or (f.to_id::text = m.from_id::text and f.from_id::text = o.oid)))
            then '友達' else '24時間' end              as "種類",
       m.from_id::text                                 as "送った人のid",
       o.oid                                           as "相手のid"
  from public.tama_messages m
 cross join lateral (select case when split_part(m.match_key, '__', 1) = m.from_id::text
                                 then split_part(m.match_key, '__', 2) else split_part(m.match_key, '__', 1) end as oid) o
  left join public.tama_profiles fp on fp.id::text = m.from_id::text
  left join public.tama_profiles tp on tp.id::text = o.oid
 order by m.created_at desc;

create or replace view admin.community as
select x.created_at                                    as "日時",
       coalesce(r.name, '（消えたコミュニティ）')       as "コミュニティ",
       coalesce(p.name, x.name, '（消えた人）')         as "書いた人",
       x.text                                          as "投稿",
       x.from_id::text                                 as "書いた人のid",
       x.room_id::text                                 as "コミュニティのid"
  from public.tama_room_messages x
  left join public.tama_rooms r    on r.id::text = x.room_id::text
  left join public.tama_profiles p on p.id::text = x.from_id::text
 order by x.created_at desc;

create or replace view admin.reports as
select v.created_at                                    as "日時",
       v.status                                        as "対応",
       coalesce(rp.name, '（消えた人）')                as "通報した人",
       coalesce(tp.name, '（消えた人）')                as "通報された人",
       v.reason                                        as "理由",
       v.detail                                        as "くわしく",
       (select count(*) from public.tama_reports z where z.target_id::text = v.target_id::text) as "この人への通報の数",
       v.evidence                                      as "その時のやりとり",
       v.memo                                          as "運営のメモ",
       v.reporter_id::text                             as "通報した人のid",
       v.target_id::text                               as "通報された人のid"
  from public.tama_reports v
  left join public.tama_profiles rp on rp.id::text = v.reporter_id::text
  left join public.tama_profiles tp on tp.id::text = v.target_id::text
 order by v.created_at desc;

revoke all on all tables in schema admin from public, anon, authenticated;

-- 確認：3行（talk・community・reports）出ればOK
select table_name from information_schema.views where table_schema = 'admin' order by table_name;

-- 対応したら（例）：通報された人の id を入れて実行。Table Editor の public.tama_reports で status・memo を直接書き換えてもよい
-- update public.tama_reports set status = '対応済み', memo = '注意した' where target_id::text = 'ここに通報された人のid';
