-- Supabase の SQL Editor でこのファイルの内容をそのまま実行してください（2026-11-07）。
-- 何度実行しても同じ結果になるように書いてあります（再実行しても壊れません）。
-- ⚠️ 先に tama_safety.sql・tama_weekly.sql・tama_moderation.sql を実行済みであること。
-- ⚠️ 同じブランチ（feat/safety-audit-1107）のアプリが本番に出てから実行する（「悩み・不安」を本人の画面に戻す処理がアプリに入っているため）。
--
-- 2026-11-07 安全の総点検（S2）で見つけた穴をふさぐ。
--   1. 自分の行しか書けないことを「絞る決まり（restrictive）」で約束する
--      プロフィール・いいね・すれ違い・ブロック・通報・トーク・コミュニティの表は、はじめにダッシュボードで作ったので、
--      本番にどんな決まりがあるか、ファイルからは分からない。そこで、今ある決まりはそのまま残し、
--      「それに加えて、必ずこれも満たす」という決まり（AND で効く）を足す。今ある決まりがゆるくても、ここで止まる
--   2. 友達の申請：申請された人が「申請した人」の欄を書きかえて、知らない人と勝手に友達になれた → 書きかえられないようにする
--   3. コミュニティの投稿の名前：投稿に名前を自分で書けたので「運営」などになりすませた → サーバーがプロフィールの名前を入れる
--   4. 利用停止にした人のトーク・投稿・いいね・今週のイベントの答えを、ほかの人から見えなくする（消さずに残す。証拠のため）
--   5. 招待コードの当てずっぽう：10分に10回まちがえたら、しばらく入れない
--   6. 通報で自動で隠すのは、ログインして（ゲストでない）1日以上たった人の通報だけ数える（作りたてのアカウントを大量に使った悪用を防ぐ）
--   7. 「悩み・不安」を「同じことを選んだ人にだけ」にしている人の分は、だれでも読める表に置かない
--      （前は画面で隠しているだけで、ログインすればだれでも全員分を読めた）。本人だけが読める tama_private に移し、
--      同じものを選んでいる人には、重なった分だけを関数 tama_shared_purposes() で返す
--   8. アカウント削除で、消し漏れがないようにする関数 tama_delete_user_data()（Edge Function の tama-delete-account が呼ぶ）
--   9. ログインしていない人（anon）は、多摩キャン版の表を直接さわれないようにする
--  10. security definer の関数で search_path が決まっていないものに、search_path を決める

-- ---------------------------------------------------------------------------
-- 1. 自分の行しか書けない（restrictive。今ある決まりに AND で足される）
-- ---------------------------------------------------------------------------
-- 止めた人か（決まりの中から使う。止めた人の一覧は本人たちから読めないので、関数で確かめる）
create or replace function public.tama_is_banned(p text)
returns boolean language sql stable security definer set search_path = public as $$
  select p is not null and p <> coalesce(auth.uid()::text, '') and exists (select 1 from public.tama_bans b where b.user_id::text = p)
$$;
revoke all on function public.tama_is_banned(text) from public, anon;
grant execute on function public.tama_is_banned(text) to authenticated;
do $$
declare
  me text := '(auth.uid())::text';
  t record;
begin
  for t in select * from (values
    -- 表, 決まりの名前, 種類, using の条件, with check の条件
    ('tama_profiles',      'own row insert',  'insert', null, 'id::text = ' || me),
    ('tama_profiles',      'own row update',  'update', 'id::text = ' || me, 'id::text = ' || me),
    ('tama_profiles',      'own row delete',  'delete', 'id::text = ' || me, null),
    ('tama_likes',         'own likes read',  'select', '(from_id::text = ' || me || ' or to_id::text = ' || me || ') and not public.tama_is_banned(tama_likes.from_id::text)', null),
    ('tama_likes',         'own likes insert','insert', null, 'from_id::text = ' || me || ' and to_id::text <> ' || me),
    ('tama_likes',         'own likes update','update', 'from_id::text = ' || me, 'from_id::text = ' || me),
    ('tama_likes',         'own likes delete','delete', 'from_id::text = ' || me || ' or to_id::text = ' || me, null),
    ('tama_encounters',    'own enc read',    'select', 'owner_id::text = ' || me, null),
    ('tama_encounters',    'own enc insert',  'insert', null, 'owner_id::text = ' || me),
    ('tama_encounters',    'own enc update',  'update', 'owner_id::text = ' || me, 'owner_id::text = ' || me),
    ('tama_encounters',    'own enc delete',  'delete', 'owner_id::text = ' || me, null),
    ('tama_blocks',        'own blocks read', 'select', 'blocker_id::text = ' || me, null),
    ('tama_blocks',        'own blocks insert','insert', null, 'blocker_id::text = ' || me),
    ('tama_blocks',        'own blocks update','update', 'blocker_id::text = ' || me, 'blocker_id::text = ' || me),
    ('tama_blocks',        'own blocks delete','delete', 'blocker_id::text = ' || me, null),
    ('tama_reports',       'reports no read', 'select', 'false', null),
    ('tama_reports',       'own report insert','insert', null, 'reporter_id::text = ' || me),
    ('tama_reports',       'reports no update','update', 'false', 'false'),
    ('tama_reports',       'reports no delete','delete', 'false', null),
    ('tama_messages',      'talk read ok',    'select', me || ' = any (string_to_array(match_key, ''__'')) and not public.tama_is_banned(tama_messages.from_id::text)', null),
    ('tama_messages',      'talk own insert', 'insert', null, 'from_id::text = ' || me || ' and ' || me || ' = any (string_to_array(match_key, ''__''))'),
    ('tama_messages',      'talk no update',  'update', 'false', 'false'),
    ('tama_messages',      'talk no delete',  'delete', 'false', null),
    ('tama_room_messages', 'room read ok',    'select', 'not public.tama_is_banned(tama_room_messages.from_id::text)', null),
    ('tama_room_messages', 'room own insert', 'insert', null, 'from_id::text = ' || me),
    ('tama_rooms',         'rooms by fn insert','insert', null, 'false'),
    ('tama_rooms',         'rooms by fn update','update', 'false', 'false'),
    ('tama_rooms',         'rooms by fn delete','delete', 'false', null),
    ('tama_match_unlocks', 'unlocks closed',  'select', 'false', null)
  ) as x(tbl, pol, cmd, q, c) loop
    if to_regclass('public.' || t.tbl) is null then raise notice '% が無いので飛ばします', t.tbl; continue; end if;
    execute format('alter table public.%I enable row level security', t.tbl);
    execute format('drop policy if exists %I on public.%I', 'r: ' || t.pol, t.tbl);
    execute format('create policy %I on public.%I as restrictive for %s to public %s %s', 'r: ' || t.pol, t.tbl, t.cmd,
      case when t.q is not null then 'using (' || t.q || ')' else '' end,
      case when t.c is not null then 'with check (' || t.c || ')' else '' end);
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- 2. 友達の申請：申請した人・された人の欄は書きかえられない。変えられるのは「承認」と時刻だけ
-- ---------------------------------------------------------------------------
create or replace function public.tama_friends_keep_ids()
returns trigger language plpgsql set search_path = public as $$
begin
  if new.from_id is distinct from old.from_id or new.to_id is distinct from old.to_id then
    raise exception 'friend_ids_locked' using hint = '友達の申請の相手は変えられません';
  end if;
  return new;
end $$;
revoke all on function public.tama_friends_keep_ids() from public, anon, authenticated;
drop trigger if exists tama_friends_keep_ids on public.tama_friends;
create trigger tama_friends_keep_ids before update on public.tama_friends
  for each row execute function public.tama_friends_keep_ids();
revoke update on public.tama_friends from anon, authenticated;
grant update (status, responded_at) on public.tama_friends to authenticated;

-- ---------------------------------------------------------------------------
-- 3. コミュニティの投稿の名前・アイコンは、サーバーがプロフィールから入れる（なりすましを防ぐ）
-- ---------------------------------------------------------------------------
create or replace function public.tama_room_msg_name()
returns trigger language plpgsql security definer set search_path = public as $$
declare p record;
begin
  select name, emoji into p from public.tama_profiles where id::text = new.from_id::text;
  new.name  := left(coalesce(nullif(trim(p.name), ''), '名前なし'), 30);
  new.emoji := left(coalesce(nullif(p.emoji, ''), '🙂'), 16);
  return new;
end $$;
revoke all on function public.tama_room_msg_name() from public, anon, authenticated;
do $$
begin
  if exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'tama_room_messages' and column_name = 'name') then
    drop trigger if exists tama_room_msg_name on public.tama_room_messages;
    create trigger tama_room_msg_name before insert on public.tama_room_messages
      for each row execute function public.tama_room_msg_name();
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 4. 利用停止にした人の今週のイベントの答え・提案を、ほかの人から見えなくする
--    （トーク・投稿・いいねは「1.」の決まりで見えなくなる）。今の関数の中身を読んで、1か所ずつ書き足す
-- ---------------------------------------------------------------------------
do $$
declare
  src text;
  f   text;
begin
  if to_regprocedure('public.tama_wk_state()') is null then raise notice 'tama_wk_state が無いので飛ばします'; return; end if;
  src := pg_get_functiondef('public.tama_wk_state()'::regprocedure);
  if position('tama_bans b where b.user_id = o.created_by' in src) = 0 then
    f := replace(src, 'from public.tama_wk_opts o where o.theme_id = t.id and not o.hidden',
                      'from public.tama_wk_opts o where o.theme_id = t.id and not o.hidden and not exists (select 1 from public.tama_bans b where b.user_id = o.created_by)');
    f := replace(f, 'from public.tama_wk_themes t where t.week = w + 7 and t.status = ''proposed''',
                    'from public.tama_wk_themes t where t.week = w + 7 and t.status = ''proposed'' and not exists (select 1 from public.tama_bans b where b.user_id = t.proposed_by)');
    if f = src then raise notice 'tama_wk_state の形が変わっていて、書き足せませんでした';
    else execute f; end if;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 5. 招待コードの当てずっぽうを止める（10分に10回まちがえたら、しばらく入れない）
-- ---------------------------------------------------------------------------
create table if not exists public.tama_code_fails (
  user_id    uuid not null,
  created_at timestamptz not null default now()
);
create index if not exists tama_code_fails_user on public.tama_code_fails (user_id, created_at);
alter table public.tama_code_fails enable row level security;
revoke all on public.tama_code_fails from anon, authenticated;

create or replace function public.tama_code_too_many()
returns boolean language sql stable security definer set search_path = public as $$
  select (select count(*) from public.tama_code_fails f where f.user_id = auth.uid() and f.created_at > now() - interval '10 minutes') >= 10
$$;
create or replace function public.tama_code_fail()
returns void language sql volatile security definer set search_path = public as $$
  delete from public.tama_code_fails where created_at < now() - interval '1 day';
  insert into public.tama_code_fails (user_id) select auth.uid() where auth.uid() is not null;
$$;
revoke all on function public.tama_code_too_many(), public.tama_code_fail() from public, anon, authenticated;

create or replace function public.tama_room_join_code(p_code text)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare v_room text;
begin
  if auth.uid() is null then return jsonb_build_object('status', 'code'); end if;
  if public.tama_code_too_many() then return jsonb_build_object('status', 'too_many'); end if;
  select c.room_id into v_room from public.tama_room_codes c where c.code = upper(trim(coalesce(p_code, '')));
  if v_room is null then perform public.tama_code_fail(); return jsonb_build_object('status', 'code'); end if;
  return jsonb_build_object('status', public.tama_room_join(v_room, p_code), 'room', v_room);
end $$;
revoke all on function public.tama_room_join_code(text) from public, anon;
grant execute on function public.tama_room_join_code(text) to authenticated;

-- 部屋に直接コードを付けて入る道（tama_room_join）にも、同じ上限を書き足す
do $$
declare
  src text;
  f   text;
begin
  if to_regprocedure('public.tama_room_join(text, text)') is null then return; end if;
  src := pg_get_functiondef('public.tama_room_join(text, text)'::regprocedure);
  if position('tama_code_too_many' in src) = 0 then
    -- 1行ずつの目印で書き足す（改行の違いで外れないように）
    f := replace(src, 'if r.owner_id::text is distinct from me::text then',
                      'if r.owner_id::text is distinct from me::text then if r.visibility = ''invite'' and public.tama_code_too_many() then return ''too_many''; end if;');
    f := replace(f, 'return ''code'';', 'perform public.tama_code_fail(); return ''code'';');
    if f = src then raise notice 'tama_room_join の形が変わっていて、書き足せませんでした';
    else execute f; end if;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 6. 通報で自動で隠すのは、ログインして（ゲストでない）1日以上たった人の通報だけ数える
--    （メールは今まで通り、どの通報でも運営に届く）
-- ---------------------------------------------------------------------------
create or replace function public.tama_reports_after()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  n int := 0;
  hid boolean := false;
  contact boolean := coalesce(new.reason, '') like '運営への連絡%';
begin
  if new.target_id is not null and not contact then
    select count(distinct r.reporter_id) into n from public.tama_reports r
      join auth.users u on u.id::text = r.reporter_id::text
     where r.target_id::text = new.target_id::text and coalesce(r.reason, '') not like '運営への連絡%'
       and r.created_at > now() - interval '30 days'
       and coalesce(u.is_anonymous, false) = false
       and u.created_at < now() - interval '1 day';
    if n >= 3 then
      insert into public.tama_hidden (user_id, reason) values (new.target_id::uuid, '30日のうちに' || n || '人から通報')
      on conflict (user_id) do nothing;
      hid := true;
    end if;
  end if;
  -- 運営へのメール（中身のやりとりの写しは入れない。運営は SQL Editor の tama_admin.sql の一覧で見る）
  insert into public.tama_jobs (kind, payload) values ('report', jsonb_build_object(
    'contact', contact, 'reason', left(coalesce(new.reason, ''), 200), 'detail', left(coalesce(new.detail, ''), 500),
    'target', left(coalesce(new.target_id::text, ''), 8), 'reporter', left(coalesce(new.reporter_id::text, ''), 8),
    'count', n, 'hidden', hid));
  return null;
end $$;
revoke all on function public.tama_reports_after() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 7. 「悩み・不安」（purposes）を、だれでも読める表に置かない（「同じことを選んだ人にだけ」の人）
-- ---------------------------------------------------------------------------
alter table public.tama_private add column if not exists purposes jsonb;

-- プロフィールに入ってきたら、本人だけが読める表に移す。「近くの人みんなに」の人は、そのまま残す
create or replace function public.tama_profiles_purposes_private()
returns trigger language plpgsql security definer set search_path = public as $$
declare f jsonb := coalesce(new.fes_attrs, '{}'::jsonb);
begin
  if not (f ? 'purposes') then return new; end if;
  insert into public.tama_private (id, purposes) values (new.id::text::uuid, f->'purposes')
  on conflict (id) do update set purposes = excluded.purposes;
  if coalesce(f->>'purpose_vis', 'same') <> 'all' then
    new.fes_attrs := (f - 'purposes') || jsonb_build_object('pur_h',
      jsonb_typeof(f->'purposes') = 'array' and jsonb_array_length(f->'purposes') > 0);
  else
    new.fes_attrs := f - 'pur_h';
  end if;
  return new;
end $$;
revoke all on function public.tama_profiles_purposes_private() from public, anon, authenticated;
drop trigger if exists tama_profiles_purposes_private on public.tama_profiles;
create trigger tama_profiles_purposes_private before insert or update on public.tama_profiles
  for each row execute function public.tama_profiles_purposes_private();

-- その人の全部の属性（サーバーの中だけで使う。隠した悩みも入れる）
create or replace function public.tama_fa_full(p_id text)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(p.fes_attrs, '{}'::jsonb)
         || case when coalesce((p.fes_attrs->>'pur_h')::boolean, false) and v.purposes is not null
                 then jsonb_build_object('purposes', v.purposes) else '{}'::jsonb end
    from public.tama_profiles p left join public.tama_private v on v.id::text = p.id::text
   where p.id::text = p_id
$$;
revoke all on function public.tama_fa_full(text) from public, anon, authenticated;

-- 自分の属性（コミュニティの参加条件で使う）にも、隠した悩みを入れる
create or replace function public.tama_my_fa()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(public.tama_fa_full(auth.uid()::text), '{}'::jsonb)
$$;
revoke all on function public.tama_my_fa() from public, anon;
grant execute on function public.tama_my_fa() to authenticated;

-- 相手と自分で重なっている悩みだけを返す（相手が「同じことを選んだ人にだけ」にしている時）。1回に300人まで
create or replace function public.tama_shared_purposes(p_ids text[])
returns table (id text, purposes jsonb)
language plpgsql stable security definer set search_path = public as $$
declare
  me   text := auth.uid()::text;
  mine jsonb;
begin
  if me is null then return; end if;
  mine := public.tama_fa_full(me)->'purposes';
  if mine is null or jsonb_typeof(mine) <> 'array' or jsonb_array_length(mine) = 0 then return; end if;
  return query
    select p.id::text,
           (select jsonb_agg(x) from jsonb_array_elements_text(v.purposes) x where mine ? x)
      from public.tama_profiles p join public.tama_private v on v.id::text = p.id::text
     where p.id::text = any (p_ids[1:300]) and p.id::text <> me
       and coalesce((p.fes_attrs->>'pur_h')::boolean, false)
       and jsonb_typeof(v.purposes) = 'array'
       and exists (select 1 from jsonb_array_elements_text(v.purposes) x where mine ? x)
       and not exists (select 1 from public.tama_blocks k where (k.blocker_id::text = me and k.blocked_id::text = p.id::text)
                                                         or (k.blocker_id::text = p.id::text and k.blocked_id::text = me));
end $$;
revoke all on function public.tama_shared_purposes(text[]) from public, anon;
grant execute on function public.tama_shared_purposes(text[]) to authenticated;

-- 本人が自分の悩みを読む（tama_private の自分の行。前から本人だけ読める決まりがある）
grant select on public.tama_private to authenticated;

-- 閉じている間のすれ違い（tama_cross_detect）の共通点にも、隠した悩みを入れる。今の関数の中身を読んで2か所を書きかえる
do $$
declare
  src text;
  f   text;
begin
  if to_regprocedure('public.tama_cross_detect(text, text)') is null then return; end if;
  src := pg_get_functiondef('public.tama_cross_detect(text, text)'::regprocedure);
  if position('tama_fa_full' in src) = 0 then
    f := replace(src, 'select id, fes_attrs into mp from public.tama_profiles where id::text = p_id;',
                      'select id, public.tama_fa_full(id::text) as fes_attrs into mp from public.tama_profiles where id::text = p_id;');
    f := replace(f, 'select id, fes_attrs into op from public.tama_profiles where id::text = o.id;',
                    'select id, public.tama_fa_full(id::text) as fes_attrs into op from public.tama_profiles where id::text = o.id;');
    if f = src then raise notice 'tama_cross_detect の形が変わっていて、書きかえられませんでした';
    else execute f; end if;
  end if;
end $$;

-- 今あるプロフィールの悩みを移す（トリガーが動く）
update public.tama_profiles set fes_attrs = fes_attrs
 where fes_attrs ? 'purposes' and coalesce(fes_attrs->>'purpose_vis', 'same') <> 'all';

-- ---------------------------------------------------------------------------
-- 8. アカウント削除の残りを消す（Edge Function tama-delete-account が強い鍵で呼ぶ。アプリからは呼べない）
--    消さずに残すもの：利用停止の記録（tama_bans・tama_ban_devices・tama_devices）・通報（tama_reports）・運営の表
--    （プライバシーポリシーの「5. 保存する期間」に書いてあるとおり）
-- ---------------------------------------------------------------------------
create or replace function public.tama_delete_user_data(p_user uuid)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  u   text := p_user::text;
  c   record;
  n   int;
  out jsonb := '{}'::jsonb;
  keep text[] := array['tama_bans', 'tama_ban_devices', 'tama_devices', 'tama_reports', 'tama_admins', 'tama_jobs',
                       'tama_ng_words', 'tama_survey_secret', 'tama_funnel'];
begin
  if p_user is null then return out; end if;
  -- 部屋のオーナーは外す（ほかの人の投稿は残す。オーナーのいない部屋は運営が見守る）
  if to_regclass('public.tama_rooms') is not null then update public.tama_rooms set owner_id = null where owner_id::text = u; end if;
  -- 今週のイベントで書いた答え・提案は、ほかの人の答えが付いているので、書いた人の印だけ外す
  if to_regclass('public.tama_wk_opts') is not null then update public.tama_wk_opts set created_by = null where created_by = p_user; end if;
  if to_regclass('public.tama_wk_themes') is not null then update public.tama_wk_themes set proposed_by = null where proposed_by = p_user; end if;
  -- トーク（2人の id をつないだ鍵）
  if to_regclass('public.tama_messages') is not null then
    delete from public.tama_messages where split_part(match_key, '__', 1) = u or split_part(match_key, '__', 2) = u;
  end if;
  if to_regclass('public.tama_msg_reactions') is not null then
    delete from public.tama_msg_reactions where split_part(match_key, '__', 1) = u or split_part(match_key, '__', 2) = u;
  end if;
  -- そのほか：人の id が入る列を持つ表を全部見て、その人の行を消す
  for c in
    select col.table_name, col.column_name from information_schema.columns col
      join information_schema.tables t on t.table_schema = col.table_schema and t.table_name = col.table_name and t.table_type = 'BASE TABLE'
     where col.table_schema = 'public'
       and (col.table_name like 'tama\_%' or col.table_name = 'push_subscriptions')
       and not (col.table_name = any (keep))
       and col.data_type in ('uuid', 'text')
       and col.column_name in ('id', 'user_id', 'owner_id', 'friend_id', 'from_id', 'to_id', 'other_id', 'watcher_id', 'target_id',
                               'blocker_id', 'blocked_id', 'sender_id', 'recipient_id', 'inviter_id', 'invitee_id')
       and not (col.table_name in ('tama_rooms', 'tama_room_codes', 'tama_wk_reports') and col.column_name in ('id', 'target_id', 'owner_id'))
  loop
    execute format('delete from public.%I where %I::text = $1', c.table_name, c.column_name) using u;
    get diagnostics n = row_count;
    if n > 0 then out := out || jsonb_build_object(c.table_name || '.' || c.column_name, n); end if;
  end loop;
  return out;
end $$;
revoke all on function public.tama_delete_user_data(uuid) from public, anon, authenticated;
grant execute on function public.tama_delete_user_data(uuid) to service_role;

-- ---------------------------------------------------------------------------
-- 9. ログインしていない人（anon）は、多摩キャン版の表を直接さわれない（出店の一覧だけは読める）
--    アプリは開いた時にゲストかメールでログインするので、ふつうに使う人には変わりがない
-- ---------------------------------------------------------------------------
do $$
declare t record;
begin
  for t in select tablename from pg_tables where schemaname = 'public' and tablename like 'tama\_%' and tablename <> 'tama_booths' loop
    execute format('revoke all on public.%I from anon', t.tablename);
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- 10. security definer の関数で search_path が決まっていないものに決める（ほかの schema の同じ名前の物にすりかえられないように）
-- ---------------------------------------------------------------------------
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.prosecdef
       and not exists (select 1 from unnest(coalesce(p.proconfig, '{}')) c where c like 'search_path=%')
  loop
    execute format('alter function %s set search_path = public', f.sig);
    raise notice 'search_path を決めました: %', f.sig;
  end loop;
end $$;

notify pgrst, 'reload schema';

-- ---------------------------------------------------------------------------
-- 確認（下の表が出れば OK）
-- ---------------------------------------------------------------------------
select
  (select count(*) from pg_policies where schemaname = 'public' and policyname like 'r: %')                        as "足した絞る決まりの数（29前後）",
  (select count(*) from pg_trigger where tgname in ('tama_friends_keep_ids', 'tama_room_msg_name', 'tama_profiles_purposes_private')) as "トリガー（3なら全部）",
  (select count(*) from public.tama_profiles where fes_attrs ? 'purposes' and coalesce(fes_attrs->>'purpose_vis', 'same') <> 'all') as "まだだれでも読める隠したい悩み（0ならOK）",
  has_function_privilege('authenticated', 'public.tama_delete_user_data(uuid)', 'execute')                       as "アプリから削除の関数を呼べる（false ならOK）",
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.prosecdef and not exists (select 1 from unnest(coalesce(p.proconfig, '{}')) c where c like 'search_path=%')) as "search_path の無い関数（0ならOK）";
