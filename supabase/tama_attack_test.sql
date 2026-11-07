-- Supabase の SQL Editor でこのファイルの内容をそのまま実行してください（2026-11-07）。
-- 「悪い人（B）になったつもりで、ほかの人（A）のデータをさわれるか」を試します。
-- 試しに入れたものは、最後に消して元に戻します（もとからある友達・いいねなどには、さわりません）。
-- 途中でエラーが出た時は、全部が取り消されます（何も残りません）。
--
-- A・B は審査用のアカウント（chikaku.hosei+review1@gmail.com・+review2@gmail.com）。
-- まだ作っていない時は、プロフィールのある人のうち新しい2人を使います（その2人のデータも変わりません）。
-- 結果の表の「OK？」が全部 true なら大丈夫。false の行があったら、その行を Claude に貼ってください。
-- ⚠️ tama_moderation.sql と tama_hardening.sql を実行した後に試してください。

create temp table _r (no int, 試したこと text, "OK？" boolean, メモ text) on commit drop;
grant all on _r to authenticated, anon;

-- A と B を決める
select set_config('t.a', coalesce(
  (select id::text from auth.users where lower(email) = 'chikaku.hosei+review1@gmail.com'),
  (select id::text from public.tama_profiles order by updated_at desc nulls last limit 1 offset 0)), true);
select set_config('t.b', coalesce(
  (select id::text from auth.users where lower(email) = 'chikaku.hosei+review2@gmail.com'),
  (select id::text from public.tama_profiles order by updated_at desc nulls last limit 1 offset 1)), true);
-- 試しのデータ（もとから無い時だけ入れて、最後に消す）：A から B へのいいね・A のすれ違い・A から B への友達の申請
with x as (insert into public.tama_likes (from_id, to_id, reason)
             select current_setting('t.a')::uuid, current_setting('t.b')::uuid, '試し'
              where not exists (select 1 from public.tama_likes l where l.from_id::text = current_setting('t.a') and l.to_id::text = current_setting('t.b'))
           returning 1)
select set_config('t.like', (select count(*) from x)::text, true);
with x as (insert into public.tama_encounters (owner_id, other_id, count)
             select current_setting('t.a')::uuid, current_setting('t.b')::uuid, 1
              where not exists (select 1 from public.tama_encounters e where e.owner_id::text = current_setting('t.a') and e.other_id::text = current_setting('t.b'))
           returning 1)
select set_config('t.enc', (select count(*) from x)::text, true);
with x as (insert into public.tama_friends (from_id, to_id, status)
             select current_setting('t.a')::uuid, current_setting('t.b')::uuid, 'pending'
              where not exists (select 1 from public.tama_friends f where (f.from_id::text = current_setting('t.a') and f.to_id::text = current_setting('t.b'))
                                                                      or (f.from_id::text = current_setting('t.b') and f.to_id::text = current_setting('t.a')))
           returning id)
select set_config('t.fr', coalesce((select id::text from x), ''), true);
-- B の自己紹介（14 で書きかえられてしまった時に戻すため）
select set_config('t.bio', coalesce((select bio from public.tama_profiles where id::text = current_setting('t.b')), ''), true);

-- ここから B になったつもり
select set_config('request.jwt.claims', json_build_object('sub', current_setting('t.b'), 'role', 'authenticated')::text, true);
set local role authenticated;

insert into _r select 1, 'A の名前を書きかえられない', true, '';
do $$ declare n int; begin
  update public.tama_profiles set name = name where id::text = current_setting('t.a');
  get diagnostics n = row_count;
  if n > 0 then update _r set "OK？" = false, メモ = '書きかえられた' where no = 1; end if;
exception when others then update _r set メモ = '止まった（' || left(sqlerrm, 60) || '）' where no = 1; end $$;
insert into _r select 2, 'A のすれ違いの記録が読めない',
  (select count(*) = 0 from public.tama_encounters where owner_id::text = current_setting('t.a')), '';
insert into _r select 3, 'A の正確な位置（tama_locs）が読めない', true, '下の DO で確かめる';
do $$ begin
  perform 1 from public.tama_locs limit 1;
  update _r set "OK？" = false, メモ = '読めてしまった' where no = 3;
exception when others then update _r set メモ = '読めない（' || sqlerrm || '）' where no = 3; end $$;
insert into _r select 4, 'A の年齢・悩み（tama_private）が読めない',
  (select count(*) = 0 from public.tama_private where id::text = current_setting('t.a')), '';
insert into _r select 5, '「同じ人にだけ」の悩みが、だれでも読める表に残っていない',
  (select count(*) = 0 from public.tama_profiles where fes_attrs ? 'purposes' and coalesce(fes_attrs->>'purpose_vis', 'same') <> 'all'), '';
insert into _r select 6, '通報が読めない', (select count(*) = 0 from public.tama_reports), '';
insert into _r select 7, '止めた人の一覧が読めない', (select count(*) = 0 from public.tama_bans), '';
insert into _r select 8, 'A になりすまして、いいねを送れない', true, '';
do $$ begin
  insert into public.tama_likes (from_id, to_id, reason) values (current_setting('t.a')::uuid, gen_random_uuid(), 'なりすまし');
  update _r set "OK？" = false, メモ = '送れてしまった' where no = 8;
exception when others then update _r set メモ = '止まった（' || left(sqlerrm, 60) || '）' where no = 8; end $$;
insert into _r select 9, '友達の申請の相手を書きかえられない', true, '';
do $$ begin
  if current_setting('t.fr') = '' then update _r set メモ = 'もとから2人の申請・友達の行があるので試せていない（その行にはさわらない）' where no = 9; return; end if;
  update public.tama_friends set from_id = gen_random_uuid() where id::text = current_setting('t.fr');
  if found then update _r set "OK？" = false, メモ = '書きかえられた' where no = 9; end if;
exception when others then update _r set メモ = '止まった（' || left(sqlerrm, 60) || '）' where no = 9; end $$;
insert into _r select 10, 'A とだれかのトークが読めない（B が入っていないトーク）',
  (select count(*) = 0 from public.tama_messages where position(current_setting('t.b') in match_key) = 0), '';
insert into _r select 11, 'アカウント削除の関数を呼べない', true, '';
do $$ begin
  perform public.tama_delete_user_data(current_setting('t.a')::uuid);
  update _r set "OK？" = false, メモ = '呼べてしまった' where no = 11;
exception when others then update _r set メモ = '呼べない（' || left(sqlerrm, 50) || '）' where no = 11; end $$;
insert into _r select 12, '運営でない人は、人を止められない',
  (select public.tama_ban(current_setting('t.a')::uuid, '試し') = 'denied'), '';
insert into _r select 13, '通知の記録（tama_push_log）が読めない', true, '';
do $$ begin
  perform 1 from public.tama_push_log limit 1;
  update _r set "OK？" = false, メモ = '読めてしまった' where no = 13;
exception when others then update _r set メモ = '読めない' where no = 13; end $$;
insert into _r select 14, 'ひどい言葉で自己紹介を変えられない', true, '';
do $$ begin
  update public.tama_profiles set bio = '死ねばいいのに' where id::text = current_setting('t.b');
  if found then update _r set "OK？" = false, メモ = '変えられた（tama_moderation.sql の実行前？）' where no = 14;
  else update _r set メモ = 'B のプロフィールが無いので試せていない' where no = 14; end if;
exception when others then update _r set メモ = '止まった（' || left(sqlerrm, 40) || '）' where no = 14; end $$;
insert into _r select 15, 'A のいまどこ（友達でなければ）が読めない',
  (select count(*) = 0 from public.tama_presence where id::text = current_setting('t.a')
     and not exists (select 1 from public.tama_friends f where f.status = 'accepted'
                      and ((f.from_id::text = current_setting('t.a') and f.to_id::text = current_setting('t.b'))
                        or (f.to_id::text = current_setting('t.a') and f.from_id::text = current_setting('t.b'))))), '';
insert into _r select 16, 'A の時間割（見せていなければ）が読めない',
  (select count(*) = 0 from public.tama_timetable t where t.id::text = current_setting('t.a')
     and not exists (select 1 from public.tama_timetable_shares s where s.owner_id::text = current_setting('t.a') and s.friend_id::text = current_setting('t.b'))), '';

-- ログインしていない人
reset role;
select set_config('request.jwt.claims', '', true);
set local role anon;
insert into _r select 17, 'ログインしていない人はプロフィールを読めない', true, '';
do $$ begin
  perform 1 from public.tama_profiles limit 1;
  update _r set "OK？" = false, メモ = '読めてしまった' where no = 17;
exception when others then update _r set メモ = '読めない' where no = 17; end $$;
insert into _r select 18, 'ログインしていない人はトークを読めない', true, '';
do $$ begin
  perform 1 from public.tama_messages limit 1;
  update _r set "OK？" = false, メモ = '読めてしまった' where no = 18;
exception when others then update _r set メモ = '読めない' where no = 18; end $$;
reset role;

-- 元に戻す（試しに入れた行だけ消す）
delete from public.tama_likes where current_setting('t.like') = '1' and from_id::text = current_setting('t.a') and to_id::text = current_setting('t.b') and reason = '試し';
delete from public.tama_likes where reason = 'なりすまし';
delete from public.tama_encounters where current_setting('t.enc') = '1' and owner_id::text = current_setting('t.a') and other_id::text = current_setting('t.b');
delete from public.tama_friends where current_setting('t.fr') <> '' and id::text = current_setting('t.fr');
update public.tama_profiles set bio = nullif(current_setting('t.bio'), '') where id::text = current_setting('t.b') and bio = '死ねばいいのに';

select no, 試したこと, "OK？", メモ, left(current_setting('t.a'), 8) as "A", left(current_setting('t.b'), 8) as "B" from _r order by no;
