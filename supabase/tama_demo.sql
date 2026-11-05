-- 審査用のアカウント2つを、すぐ試せる状態にする（2026-11-05。審査の報告書 A10・Apple 2.1）。何度実行しても壊れません。
-- ⚠️ 先に Supabase → Authentication → Users → Add user → Create new user で、次の2つをパスワードつきで作る
--    （Auto Confirm User にチェック）：
--      chikaku.hosei+review1@gmail.com
--      chikaku.hosei+review2@gmail.com
--    アプリ（tama/index.html の DEMO）は、この2つのアドレスだけパスワードでログインでき、位置をいつもキャンパスの中として扱う。
--    パスワードは審査のメモ（App Store Connect の「App Review に関する情報」・Google Play の「アプリのアクセス権」）にだけ書く。
--
-- このファイルがすること：2人のプロフィール（共通点つき）・友達（承認ずみ）・トークの履歴・すれ違いの記録を入れる

do $$
declare
  a uuid := (select id from auth.users where lower(email) = 'chikaku.hosei+review1@gmail.com');
  b uuid := (select id from auth.users where lower(email) = 'chikaku.hosei+review2@gmail.com');
  k text;
begin
  if a is null or b is null then raise exception '先に Authentication → Users で、審査用のアカウントを2つ作ってください'; end if;
  k := least(a::text, b::text) || '__' || greatest(a::text, b::text);

  insert into public.tama_profiles (id, name, emoji, bio, tags, looking, likes, interests, fes_attrs, sharing, updated_at)
  values (a, 'デモ（審査用1）', '🐳', '審査用のアカウントです', '{}', '{}', '{}', '{}', '{"faculty":"社会学部","grade":"2年","artist":"ヨルシカ","aruaru":["方向音痴"]}'::jsonb, true, now()),
         (b, 'デモ（審査用2）', '🌿', '審査用のアカウントです', '{}', '{}', '{}', '{}', '{"faculty":"社会学部","grade":"2年","artist":"ヨルシカ","aruaru":["方向音痴"]}'::jsonb, true, now())
  on conflict (id) do update set name = excluded.name, emoji = excluded.emoji, bio = excluded.bio, fes_attrs = excluded.fes_attrs, sharing = true, updated_at = now();

  if to_regclass('public.tama_private') is not null then
    insert into public.tama_private (id, age) values (a, 20), (b, 20) on conflict (id) do update set age = 20;
  end if;

  -- 友達（承認ずみ）
  if not exists (select 1 from public.tama_friends where (from_id = a and to_id = b) or (from_id = b and to_id = a)) then
    insert into public.tama_friends (from_id, to_id, status, responded_at) values (a, b, 'accepted', now());
  else
    update public.tama_friends set status = 'accepted', responded_at = coalesce(responded_at, now()) where (from_id = a and to_id = b) or (from_id = b and to_id = a);
  end if;

  -- トークの履歴（無い時だけ）
  if not exists (select 1 from public.tama_messages where match_key = k) then
    insert into public.tama_messages (match_key, from_id, text, created_at) values
      (k, a, 'さっき図書館の前ですれ違いましたね', now() - interval '50 minutes'),
      (k, b, 'ヨルシカ好きなんですね！', now() - interval '48 minutes'),
      (k, a, '3限のあと、食堂で少し話しませんか', now() - interval '45 minutes');
  end if;

  -- すれ違いの記録（2人とも）
  insert into public.tama_encounters (owner_id, other_id, count, first_at, last_at, last_place)
  select x.o, x.t, 3, now() - interval '2 days', now() - interval '1 hour', '図書館・研究棟'
    from (values (a, b), (b, a)) as x(o, t)
   where not exists (select 1 from public.tama_encounters e where e.owner_id = x.o and e.other_id = x.t);
end $$;

select id, email from auth.users where lower(email) in ('chikaku.hosei+review1@gmail.com', 'chikaku.hosei+review2@gmail.com');
