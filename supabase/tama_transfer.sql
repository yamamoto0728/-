-- Web 版からアプリへの引き継ぎコード（2026-11-02 あおの決定：「Web 版とメールはいったん切り離して、引き継ぎは Web 版に出すコードのコピペ」）
-- Supabase の SQL Editor でこのファイルの内容をそのまま実行してください（何回実行しても大丈夫）。
--
-- 流れ：
--   1. Web 版の「設定 → アプリに引き継ぐ」で tama_transfer_issue() を呼ぶ → 10文字のコードが出る（30分だけ・1回だけ使える）
--   2. アプリで、メールのコードでログインする（新しいアカウントができる）
--   3. まだ何も使っていなければ「Web 版から引き継ぐ」にコードを貼る → Edge Function "tama-transfer" が
--      tama_transfer_check() でコードを確かめ、いまできたアカウントを消して、Web 版のアカウントにそのメールを付ける
--      → アプリはそのまま Web 版のアカウントでログインし直す（ID が変わらないので、データを移す作業はない）
--   4. アプリは Web 版のログインを切る（同じアカウントが2か所で位置を送ると、学外の Web が共有を止めてしまうため）
--
-- コードはこのデータベースに「ハッシュ」だけを残す（コードそのものは残さない）。表は本人も含めて誰も直接読めない。

create extension if not exists pgcrypto with schema extensions;

create table if not exists public.tama_transfer_codes (
  code_hash  text primary key,
  uid        uuid not null,                    -- コードを出した Web 版のアカウント
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  used_at    timestamptz,
  used_by    uuid                              -- 使ったアプリのアカウント（引き継いだあとは消えている）
);
create index if not exists tama_transfer_codes_uid on public.tama_transfer_codes (uid, created_at desc);

-- コードを試した記録（違うコードを何度も試せないように。1時間に10回まで）
create table if not exists public.tama_transfer_tries (
  uid uuid not null,
  at  timestamptz not null default now()
);
create index if not exists tama_transfer_tries_uid on public.tama_transfer_tries (uid, at desc);

alter table public.tama_transfer_codes enable row level security;
alter table public.tama_transfer_tries enable row level security;
revoke all on public.tama_transfer_codes from anon, authenticated;
revoke all on public.tama_transfer_tries from anon, authenticated;

-- コードの文字の正規化（小文字・ハイフン・空白を許す）
create or replace function public.tama_transfer_norm(p text) returns text
language sql immutable as $$ select upper(regexp_replace(coalesce(p, ''), '[^A-Za-z0-9]', '', 'g')) $$;

-- ① Web 版：コードを出す。前に出してまだ使っていないコードは使えなくする
create or replace function public.tama_transfer_issue() returns json
language plpgsql security definer set search_path = public, extensions as $$
declare
  me  uuid := auth.uid();
  abc constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';   -- 見まちがえやすい I・O・0・1 は使わない（32文字）
  b   bytea;
  c   text := '';
  i   int;
  exp timestamptz := now() + interval '30 minutes';
begin
  if me is null then raise exception 'not_signed_in'; end if;
  delete from tama_transfer_codes where created_at < now() - interval '2 days';
  delete from tama_transfer_tries where at < now() - interval '2 days';
  if (select count(*) from tama_transfer_codes where uid = me and created_at > now() - interval '1 hour') >= 10 then
    raise exception 'too_many';
  end if;
  update tama_transfer_codes set expires_at = now() where uid = me and used_at is null and expires_at > now();
  b := gen_random_bytes(10);
  for i in 0..9 loop c := c || substr(abc, (get_byte(b, i) % 32) + 1, 1); end loop;
  insert into tama_transfer_codes (code_hash, uid, expires_at) values (encode(digest(c, 'sha256'), 'hex'), me, exp);
  return json_build_object('code', c, 'expires_at', exp);
end $$;

-- ② Web 版：出したコードがもう使われたか（コードの画面を開いている間に見る → 使われたら Web 版からログアウトする）
create or replace function public.tama_transfer_status() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from tama_transfer_codes where uid = auth.uid() and used_at is not null and used_at > now() - interval '1 day')
$$;

-- ③ Edge Function だけが使う：コードを確かめて「使った」にする。返すのは {ok, uid} か {ok:false, error}
--    error … too_many（1時間に10回）・bad_code（ちがう・時間切れ・使用ずみ）・same_account・new_has_data（アプリのアカウントがもう使われている）
--            ・old_has_email（Web 版のアカウントにもうメールが付いている → そのメールでログインすればよい）
--    例外にしないのは、試した記録（tama_transfer_tries）を取り消さないため
create or replace function public.tama_transfer_check(p_code text, p_new uuid) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare
  h text := encode(digest(public.tama_transfer_norm(p_code), 'sha256'), 'hex');
  r public.tama_transfer_codes;
  u record;
begin
  if (select count(*) from tama_transfer_tries where uid = p_new and at > now() - interval '1 hour') >= 10 then
    return json_build_object('ok', false, 'error', 'too_many');
  end if;
  insert into tama_transfer_tries (uid) values (p_new);
  select * into r from tama_transfer_codes where code_hash = h for update;
  if not found or r.used_at is not null or r.expires_at <= now() then return json_build_object('ok', false, 'error', 'bad_code'); end if;
  if r.uid = p_new then return json_build_object('ok', false, 'error', 'same_account'); end if;
  if exists (select 1 from tama_profiles where id::text = p_new::text) then return json_build_object('ok', false, 'error', 'new_has_data'); end if;
  select is_anonymous, email into u from auth.users where id = r.uid;
  if not found then return json_build_object('ok', false, 'error', 'bad_code'); end if;
  if coalesce(u.email, '') <> '' and not coalesce(u.is_anonymous, false) then return json_build_object('ok', false, 'error', 'old_has_email'); end if;
  update tama_transfer_codes set used_at = now(), used_by = p_new where code_hash = h;
  return json_build_object('ok', true, 'uid', r.uid);
end $$;

-- ④ Edge Function だけが使う：途中で失敗した時に、コードを「まだ使っていない」に戻す
create or replace function public.tama_transfer_undo(p_code text) returns void
language sql security definer set search_path = public, extensions as $$
  update tama_transfer_codes set used_at = null, used_by = null
   where code_hash = encode(digest(public.tama_transfer_norm(p_code), 'sha256'), 'hex')
$$;

revoke all on function public.tama_transfer_issue()           from public, anon;
revoke all on function public.tama_transfer_status()          from public, anon;
revoke all on function public.tama_transfer_check(text, uuid) from public, anon, authenticated;
revoke all on function public.tama_transfer_undo(text)        from public, anon, authenticated;
grant execute on function public.tama_transfer_issue()           to authenticated;
grant execute on function public.tama_transfer_status()          to authenticated;
grant execute on function public.tama_transfer_check(text, uuid) to service_role;
grant execute on function public.tama_transfer_undo(text)        to service_role;

notify pgrst, 'reload schema';

-- 確かめる（4つとも true なら OK）
select
  (to_regclass('public.tama_transfer_codes') is not null)                                   as codes_table,
  (to_regprocedure('public.tama_transfer_issue()') is not null)                              as issue_fn,
  has_function_privilege('authenticated', 'public.tama_transfer_issue()', 'execute')         as web_can_issue,
  not has_function_privilege('authenticated', 'public.tama_transfer_check(text, uuid)', 'execute') as web_cannot_check;
