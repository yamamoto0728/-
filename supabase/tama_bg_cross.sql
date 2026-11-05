-- Supabase の SQL Editor でこのファイルの内容をそのまま実行してください（2026-11-05）。
-- 何度実行しても同じ結果になるように書いてあります（再実行しても壊れません）。
-- ⚠️ 先に supabase/tama_safety.sql を実行しておくこと（tama_hidden・tama_jobs・tama_push_log.sender_id を使う）。
--
-- あおの依頼「まだ入れてないものは入れて」（2026-11-05）：アプリを閉じていても、すれ違える（要件定義書 v0.1 の目的①）。
--
-- しくみ：
--   1. アプリで「閉じていても、すれ違う」をオンにすると、端末ごとの合言葉（tama_bg_token_issue）を受け取る。
--      位置の部品（Transistorsoft）は、学内にいる間だけ位置を取り、アプリが閉じていても自分で tama_bg_ingest に送る（合言葉つき）。
--      合言葉はサーバーには「ハッシュ」だけを残す。ログインの鍵（JWT）は使わない（閉じている間は更新できないため）
--   2. tama_bg_ingest は、学内の位置だけを受け取り（学外は捨てる・残さない）、tama_locs に「閉じている間の位置（src='bg'）」として置く。
--      閉じている人は、地図・近くの人の一覧には出さない（tama_nearby は src='bg' を返さない）。すれ違いの記録だけに使う
--   3. すれ違いの判定はサーバーでする（50m以内）。相手は、開いている人（2分以内に位置を送った）か、閉じている人
--      （動いている時は3分以内・止まっている時は30分以内の位置）。開いている人どうしは、今まで通り画面が判定する
--   4. すれ違いの設定（お互いさま）をサーバーでも守る：どちらかが「使わない」なら記録しない。
--      どちらかが「共通点がある人だけ」なら、プロフィールの共通点（アーティスト・授業・あるある・困っていること・目標）がある時だけ。
--      ブロック・利用停止・自動で隠した人・「隠れる」の間（tama_bg_pause）は記録しない。同じ人とは30分に1回まで
--   5. 閉じている人には、共通点のある人とすれ違った時だけ通知（tama_jobs → tama-worker → send-match-push）。
--      夜（22時〜8時）は送らない・1人1日3通まで・同じ相手には1日1回。通知の種類のスイッチ「すれ違い（cross）」でオフにできる
--
-- 限界（正直に書いておく）：
--   ・時間割・今日のお題・ちかくタイムの共通点は、サーバーでは見ていない（画面で開いた時に一覧に出る）
--   ・場所は建物まで分からないので「多摩キャンパス」と記録する
--   ・位置の部品が送ってくる位置のうち、学外のものはサーバーで捨てるが、送られてくること自体は端末の側で止める（アプリの設定）

-- ---------------------------------------------------------------------------
-- 1. 道具
-- ---------------------------------------------------------------------------
alter table public.tama_locs add column if not exists src    text    not null default 'fg';   -- fg＝アプリを開いている／bg＝閉じている間の位置の部品
alter table public.tama_locs add column if not exists moving boolean not null default true;

-- 答えを比べる時の形にそろえる（tama/index.html の normAns と同じ）
create or replace function public.tama_norm(s text)
returns text language sql immutable set search_path = public as $$
  select translate(lower(regexp_replace(normalize(coalesce(s, ''), NFKC), '[[:space:]　・,.、。!?！？''"「」『』()（）ー-]', '', 'g')),
    'ぁあぃいぅうぇえぉおかがきぎくぐけげこごさざしじすずせぜそぞただちぢっつづてでとどなにぬねのはばぱひびぴふぶぷへべぺほぼぽまみむめもゃやゅゆょよらりるれろゎわゐゑをんゔゕゖ',
    'ァアィイゥウェエォオカガキギクグケゲコゴサザシジスズセゼソゾタダチヂッツヅテデトドナニヌネノハバパヒビピフブプヘベペホボポマミムメモャヤュユョヨラリルレロヮワヰヱヲンヴヵヶ')
$$;

-- me から見た、other との共通点の言葉（無ければ null）。me が「共通点に使わない」にした項目（match_off）は見ない。
-- 通知の文に使うので、困っていること・目標は中身を出さずに「共通点」とだけ言う
create or replace function public.tama_simple_common(me jsonb, other jsonb)
returns text language plpgsql immutable set search_path = public as $$
declare
  off jsonb := coalesce(me->'match_off', '[]'::jsonb);
  x text;
begin
  if me is null or other is null then return null; end if;
  if not off ? 'art' and public.tama_norm(me->>'artist') <> '' and public.tama_norm(me->>'artist') = public.tama_norm(other->>'artist') then
    return 'アーティスト「' || left(other->>'artist', 30) || '」';
  end if;
  if not off ? 'crs' and coalesce(me->>'course', '') <> ''
     and lower(regexp_replace(normalize(me->>'course', NFKC), '[[:space:]　]+', '', 'g')) = lower(regexp_replace(normalize(coalesce(other->>'course', ''), NFKC), '[[:space:]　]+', '', 'g')) then
    return '授業「' || left(other->>'course', 30) || '」';
  end if;
  if not off ? 'aru' and jsonb_typeof(me->'aruaru') = 'array' and jsonb_typeof(other->'aruaru') = 'array' then
    select a into x from jsonb_array_elements_text(me->'aruaru') a where other->'aruaru' ? a limit 1;
    if x is not null then return 'あるある「' || left(x, 30) || '」'; end if;
  end if;
  if not off ? 'pur' and jsonb_typeof(me->'purposes') = 'array' and jsonb_typeof(other->'purposes') = 'array'
     and exists (select 1 from jsonb_array_elements_text(me->'purposes') a where other->'purposes' ? a) then
    return '共通点';
  end if;
  if not off ? 'goal' and jsonb_typeof(me->'goals') = 'array' and jsonb_typeof(other->'goals') = 'array'
     and exists (select 1 from jsonb_array_elements_text(me->'goals') a where other->'goals' ? a) then
    return '共通点';
  end if;
  return null;
end $$;

create or replace function public.tama_cross_mode(fa jsonb)
returns text language sql immutable set search_path = public as $$
  select case when fa->>'cross' in ('off', 'common') then fa->>'cross' else 'all' end
$$;

-- ---------------------------------------------------------------------------
-- 2. 端末ごとの合言葉（アプリからは読めない）
-- ---------------------------------------------------------------------------
create table if not exists public.tama_bg_tokens (
  token_hash  text primary key,
  user_id     uuid not null,
  created_at  timestamptz not null default now(),
  last_used   timestamptz,
  pause_until timestamptz                           -- 「隠れる」の間（この時刻までは記録しない）
);
create index if not exists tama_bg_tokens_user on public.tama_bg_tokens (user_id);
alter table public.tama_bg_tokens enable row level security;
revoke all on public.tama_bg_tokens from anon, authenticated;

-- 合言葉を出す（オンにした時）。1人3台まで（古いものから消す）。返すのは今回だけ（サーバーにはハッシュだけ残す）
create or replace function public.tama_bg_token_issue()
returns text language plpgsql volatile security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  t  text;
begin
  if me is null then raise exception 'not signed in'; end if;
  if exists (select 1 from public.tama_bans b where b.user_id = me) then raise exception 'banned'; end if;
  t := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
  insert into public.tama_bg_tokens (token_hash, user_id) values (encode(sha256(convert_to(t, 'UTF8')), 'hex'), me);
  delete from public.tama_bg_tokens where user_id = me and token_hash not in
    (select token_hash from public.tama_bg_tokens where user_id = me order by created_at desc limit 3);
  return t;
end $$;

-- やめる（オフにした時・ログアウト・アカウントの削除）：その人の合言葉を全部消し、閉じている間の位置も消す
create or replace function public.tama_bg_revoke()
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then return; end if;
  delete from public.tama_bg_tokens where user_id = auth.uid();
  delete from public.tama_locs where id = auth.uid()::text and src = 'bg';
end $$;

-- 「隠れる」：この時刻まで記録しない（null で戻る）
create or replace function public.tama_bg_pause(p_until timestamptz)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then return; end if;
  update public.tama_bg_tokens set pause_until = case when p_until is null or p_until < now() then null else least(p_until, now() + interval '2 days') end
   where user_id = auth.uid();
  if p_until is not null and p_until > now() then delete from public.tama_locs where id = auth.uid()::text and src = 'bg'; end if;
end $$;

revoke all on function public.tama_bg_token_issue() from public, anon;
revoke all on function public.tama_bg_revoke() from public, anon;
revoke all on function public.tama_bg_pause(timestamptz) from public, anon;
grant execute on function public.tama_bg_token_issue() to authenticated;
grant execute on function public.tama_bg_revoke() to authenticated;
grant execute on function public.tama_bg_pause(timestamptz) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. すれ違いの判定（p_id がいま位置を送った。p_src='fg' の時は、閉じている人とだけ比べる＝開いている人どうしは画面が判定する）
-- ---------------------------------------------------------------------------
create or replace function public.tama_cross_detect(p_id text, p_src text)
returns int language plpgsql volatile security definer set search_path = public as $$
declare
  m   record;  o record;
  mp  record;  op record;
  n   int := 0;
  lab text;
  jst int := extract(hour from (now() at time zone 'Asia/Tokyo'));
begin
  select * into m from public.tama_locs where id = p_id;
  if not found then return 0; end if;
  select id, fes_attrs into mp from public.tama_profiles where id::text = p_id;
  if not found or public.tama_cross_mode(mp.fes_attrs) = 'off' then return 0; end if;
  if exists (select 1 from public.tama_bans b where b.user_id::text = p_id) or exists (select 1 from public.tama_hidden h where h.user_id::text = p_id) then return 0; end if;

  for o in
    select l.* from public.tama_locs l
     where l.id <> p_id
       and public.tama_dist_m(m.lat, m.lng, l.lat, l.lng) <= 50
       and (case when l.src = 'bg' then l.at > now() - case when l.moving then interval '3 minutes' else interval '30 minutes' end
                 else l.at > now() - interval '2 minutes' end)
       and (p_src = 'bg' or l.src = 'bg')
  loop
    select id, fes_attrs into op from public.tama_profiles where id::text = o.id;
    continue when not found;
    -- お互いさま
    continue when public.tama_cross_mode(op.fes_attrs) = 'off';
    continue when public.tama_cross_mode(mp.fes_attrs) = 'common' and public.tama_simple_common(mp.fes_attrs, op.fes_attrs) is null;
    continue when public.tama_cross_mode(op.fes_attrs) = 'common' and public.tama_simple_common(op.fes_attrs, mp.fes_attrs) is null;
    continue when exists (select 1 from public.tama_blocks k where (k.blocker_id::text = p_id and k.blocked_id::text = o.id) or (k.blocker_id::text = o.id and k.blocked_id::text = p_id));
    continue when exists (select 1 from public.tama_bans b where b.user_id::text = o.id) or exists (select 1 from public.tama_hidden h where h.user_id::text = o.id);
    continue when exists (select 1 from public.tama_bg_tokens t where t.user_id::text in (p_id, o.id) and t.pause_until > now());
    -- 同じ人とは30分に1回まで
    continue when exists (select 1 from public.tama_encounters e where e.owner_id::text = p_id and e.other_id::text = o.id and e.last_at > now() - interval '30 minutes');

    -- 2人とも、相手とのすれ違いを記録する（回数・最後に会った時・1回ずつの記録）
    update public.tama_encounters set count = coalesce(count, 0) + 1, last_at = now(), last_place = '多摩キャンパス'
     where owner_id::text = p_id and other_id::text = o.id;
    if not found then insert into public.tama_encounters (owner_id, other_id, count, first_at, last_at, last_place) values (p_id::uuid, o.id::uuid, 1, now(), now(), '多摩キャンパス'); end if;
    update public.tama_encounters set count = coalesce(count, 0) + 1, last_at = now(), last_place = '多摩キャンパス'
     where owner_id::text = o.id and other_id::text = p_id;
    if not found then insert into public.tama_encounters (owner_id, other_id, count, first_at, last_at, last_place) values (o.id::uuid, p_id::uuid, 1, now(), now(), '多摩キャンパス'); end if;
    if to_regclass('public.tama_encounter_log') is not null then
      insert into public.tama_encounter_log (owner_id, other_id, place) values (p_id::uuid, o.id::uuid, '多摩キャンパス'), (o.id::uuid, p_id::uuid, '多摩キャンパス');
    end if;
    n := n + 1;

    -- 閉じている人にだけ、共通点がある時だけ知らせる（夜は送らない・1日3通まで・同じ相手には1日1回）
    if jst >= 8 and jst < 22 then
      if m.src = 'bg' then
        lab := public.tama_simple_common(mp.fes_attrs, op.fes_attrs);
        if lab is not null
           and (select count(*) from public.tama_push_log x where x.recipient_id::text = p_id and x.kind = 'cross' and x.created_at > now() - interval '20 hours') < 3
           and not exists (select 1 from public.tama_push_log x where x.recipient_id::text = p_id and x.kind = 'cross' and x.sender_id::text = o.id and x.created_at > now() - interval '20 hours') then
          insert into public.tama_push_log (recipient_id, kind, sender_id) values (p_id::uuid, 'cross', o.id::uuid);
          insert into public.tama_jobs (kind, payload) values ('push', jsonb_build_object('to', p_id, 'kind', 'cross', 'tag', 'cross',
            'title', '共通点のある人とすれ違いました', 'body', lab || 'が同じ人と、学内ですれ違いました', 'url', '/tama/?go=cross&n=cross'));
        end if;
      end if;
      if o.src = 'bg' then
        lab := public.tama_simple_common(op.fes_attrs, mp.fes_attrs);
        if lab is not null
           and (select count(*) from public.tama_push_log x where x.recipient_id::text = o.id and x.kind = 'cross' and x.created_at > now() - interval '20 hours') < 3
           and not exists (select 1 from public.tama_push_log x where x.recipient_id::text = o.id and x.kind = 'cross' and x.sender_id::text = p_id and x.created_at > now() - interval '20 hours') then
          insert into public.tama_push_log (recipient_id, kind, sender_id) values (o.id::uuid, 'cross', p_id::uuid);
          insert into public.tama_jobs (kind, payload) values ('push', jsonb_build_object('to', o.id, 'kind', 'cross', 'tag', 'cross',
            'title', '共通点のある人とすれ違いました', 'body', lab || 'が同じ人と、学内ですれ違いました', 'url', '/tama/?go=cross&n=cross'));
        end if;
      end if;
    end if;
  end loop;
  return n;
end $$;
revoke all on function public.tama_cross_detect(text, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. 位置の部品から受け取る（アプリが閉じていても、部品が自分で呼ぶ。合言葉で本人を確かめる）
--    p_locs：1つの位置 {lat,lng,acc,at,mv} か、その配列（まとめて送られた時）。使うのは一番新しい1つだけ
--    返り値：記録したすれ違いの数（部品は返り値を使わない）
-- ---------------------------------------------------------------------------
create or replace function public.tama_bg_ingest(p_token text, p_locs jsonb)
returns int language plpgsql volatile security definer set search_path = public as $$
declare
  tk   record;
  me   text;
  loc  jsonb;
  la double precision; ln double precision; ac double precision; t timestamptz; t0 timestamptz; mv boolean;
  prev record;
begin
  if p_token is null or length(p_token) < 32 or p_locs is null then return 0; end if;
  select * into tk from public.tama_bg_tokens where token_hash = encode(sha256(convert_to(p_token, 'UTF8')), 'hex');
  if not found then return 0; end if;
  me := tk.user_id::text;
  update public.tama_bg_tokens set last_used = now() where token_hash = tk.token_hash and (last_used is null or last_used < now() - interval '10 minutes');
  if tk.pause_until > now() then return 0; end if;
  if exists (select 1 from public.tama_bans b where b.user_id = tk.user_id) then return 0; end if;

  -- 一番新しい位置（届いた時刻より1分以上先の時刻は信じない）
  if jsonb_typeof(p_locs) = 'array' then
    select e into loc from jsonb_array_elements(p_locs) e where jsonb_typeof(e) = 'object' order by coalesce(e->>'at', '') desc limit 1;
  elsif jsonb_typeof(p_locs) = 'object' then
    loc := p_locs;
  end if;
  if loc is null then return 0; end if;
  begin
    la := (loc->>'lat')::double precision; ln := (loc->>'lng')::double precision; ac := coalesce((loc->>'acc')::double precision, 999);
    t0 := (loc->>'at')::timestamptz;
    t := least(coalesce(t0, now()), now());
    mv := coalesce((loc->>'mv')::boolean, true);
  exception when others then return 0;
  end;
  if la is null or ln is null or t0 > now() + interval '1 minute' then return 0; end if;

  -- 学外の位置は残さない（閉じている間の位置も消す）
  if not public.tama_in_campus(la, ln) then
    delete from public.tama_locs where id = me and src = 'bg';
    return 0;
  end if;
  -- 古い位置（電波が無かった間にたまっていた分）・ずれの大きい位置は、すれ違いには使わない
  if t < now() - interval '3 minutes' or ac > 50 then return 0; end if;

  select * into prev from public.tama_locs where id = me;
  if found then
    -- アプリを開いている間は、画面が送る位置を使う（上書きしない）
    if prev.src = 'fg' and prev.at > now() - interval '90 seconds' then return 0; end if;
    -- 3秒に1回まで・秒速15mより速い動きは受け付けない（tama_profiles_guard_loc と同じ）
    if prev.at > now() - interval '3 seconds' then return 0; end if;
    if prev.at > now() - interval '10 minutes' and public.tama_dist_m(prev.lat, prev.lng, la, ln) > 15 * extract(epoch from (now() - prev.at)) then return 0; end if;
  end if;
  insert into public.tama_locs (id, lat, lng, coarse, at, src, moving)
  values (me, la, ln, coalesce((select p.coarse from public.tama_profiles p where p.id = tk.user_id), false), now(), 'bg', mv)
  on conflict (id) do update set lat = excluded.lat, lng = excluded.lng, coarse = excluded.coarse, at = now(), src = 'bg', moving = excluded.moving;

  return public.tama_cross_detect(me, 'bg');
end $$;
revoke all on function public.tama_bg_ingest(text, jsonb) from public;
grant execute on function public.tama_bg_ingest(text, jsonb) to anon, authenticated;

-- ---------------------------------------------------------------------------
-- 5. 開いている人の位置（tama_profiles_guard_loc。tama_safety.sql の版を置きかえる）：
--    tama_locs に src='fg' で入れ、閉じている人とのすれ違いをサーバーで判定する
-- ---------------------------------------------------------------------------
create or replace function public.tama_profiles_guard_loc()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  raw  boolean;
  prev record;
  wrote boolean := false;
begin
  raw := new.lat is not null and new.lng is not null;

  if new.sharing is not true then
    delete from public.tama_locs where id = new.id::text and src = 'fg';
  elsif raw then
    if public.tama_in_campus(new.lat, new.lng) then
      select l.lat, l.lng, l.at, l.src into prev from public.tama_locs l where l.id = new.id::text;
      if prev.at is null or prev.src = 'bg'
         or (prev.at < now() - interval '3 seconds'
             and (prev.at < now() - interval '10 minutes'
                  or public.tama_dist_m(prev.lat, prev.lng, new.lat, new.lng)
                     <= 15 * extract(epoch from (now() - prev.at)))) then
        insert into public.tama_locs (id, lat, lng, coarse, at, src, moving)
        values (new.id::text, new.lat, new.lng, coalesce(new.coarse, false), now(), 'fg', true)
        on conflict (id) do update set lat = excluded.lat, lng = excluded.lng, coarse = excluded.coarse, at = now(), src = 'fg', moving = true;
        wrote := true;
      end if;
    else
      delete from public.tama_locs where id = new.id::text;
      new.sharing := false;
    end if;
  end if;

  new.lat := null;
  new.lng := null;
  if wrote then perform public.tama_cross_detect(new.id::text, 'fg'); end if;
  return new;
end $$;
revoke all on function public.tama_profiles_guard_loc() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 6. 近くの人（tama_safety.sql の版を置きかえる）：閉じている人（src='bg'）は地図・一覧に出さない
-- ---------------------------------------------------------------------------
create or replace function public.tama_nearby()
returns table (uid text, glat double precision, glng double precision, near boolean)
language plpgsql stable security definer set search_path = public as $$
declare
  me text := auth.uid()::text;
  m  record;
begin
  if me is null then return; end if;
  if exists (select 1 from public.tama_bans b where b.user_id::text = me) then return; end if;
  if exists (select 1 from public.tama_hidden h where h.user_id::text = me) then return; end if;
  select l.lat, l.lng into m from public.tama_locs l where l.id = me and l.at > now() - interval '10 minutes';
  if not found then return; end if;
  return query
    select l.id,
           case when l.coarse then round(l.lat::numeric, 3)::double precision else round(l.lat / 0.00027) * 0.00027 end,
           case when l.coarse then round(l.lng::numeric, 3)::double precision else round(l.lng / 0.00033) * 0.00033 end,
           public.tama_dist_m(m.lat, m.lng, l.lat, l.lng) <= 50
      from public.tama_locs l
      join public.tama_profiles p on p.id::text = l.id and p.sharing is true
     where l.id <> me
       and l.src = 'fg'
       and l.at > now() - interval '2 hours'
       and not exists (select 1 from public.tama_blocks k
                        where (k.blocker_id::text = me and k.blocked_id::text = l.id)
                           or (k.blocker_id::text = l.id and k.blocked_id::text = me))
       and not exists (select 1 from public.tama_bans b where b.user_id::text = l.id)
       and not exists (select 1 from public.tama_hidden h where h.user_id::text = l.id);
end $$;
revoke all on function public.tama_nearby() from public, anon;
grant execute on function public.tama_nearby() to authenticated;

notify pgrst, 'reload schema';

-- ---------------------------------------------------------------------------
-- 確認：下の表が出ればOK
-- ---------------------------------------------------------------------------
select 'tama_bg_ingest があるか' as 項目, (to_regprocedure('public.tama_bg_ingest(text,jsonb)') is not null)::text as 結果
union all
select 'tama_bg_token_issue があるか', (to_regprocedure('public.tama_bg_token_issue()') is not null)::text
union all
select 'tama_locs の列', (select string_agg(column_name, ', ' order by ordinal_position) from information_schema.columns where table_schema = 'public' and table_name = 'tama_locs')
union all
select 'tama_jobs があるか（tama_safety.sql の実行ずみか）', (to_regclass('public.tama_jobs') is not null)::text;
