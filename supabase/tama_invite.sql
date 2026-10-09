-- Supabase の SQL Editor でこのファイルの内容をそのまま実行してください（2026-10-09）。
-- 何度実行しても同じ結果になるように書いてあります（再実行しても壊れません）。
-- 実行しなくてもアプリは今まで通り動く（「アプリに誘う」に招待コードと特典が出ないだけ）。
--
-- あおの依頼「招待してくれた人に特典をつけて、ユーザーを増やしたい」。
--   ・1人に1つ、6文字の招待コード（tama_invite_codes）。招待のリンクに ?ref=コード を付ける
--   ・招待された人は、登録の時（リンクから来た時は入力ずみ）か、登録した日から3日のうちに、コードを1回だけ入れられる（tama_invites）
--   ・招待した人数に数えるのは、招待された人が「コードを入れた日とは別の日に、もう一度アプリを開いた」時（counted_at）。
--     いまのログインはスマホ1台でいくつも作れるので、登録しただけで数えると水増しできてしまうため
--   ・どちらの表もアプリから直接は読み書きできない（ポリシーを作らない）。下の関数だけが使う

create table if not exists public.tama_invite_codes (
  user_id    uuid        primary key,
  code       text        not null unique,
  created_at timestamptz not null default now()
);
alter table public.tama_invite_codes enable row level security;

create table if not exists public.tama_invites (
  invitee_id uuid        primary key,          -- 招待された人（1人1回だけ）
  inviter_id uuid        not null,             -- 招待した人
  created_at timestamptz not null default now(),
  counted_at timestamptz                       -- 別の日にもう一度開いた時（ここで1人と数える）
);
create index if not exists tama_invites_inviter_idx on public.tama_invites (inviter_id);
alter table public.tama_invites enable row level security;

-- 総当たり対策（1人10分に10回まで）
create table if not exists public.tama_invite_tries (
  id         bigint      generated always as identity primary key,
  user_id    uuid        not null,
  created_at timestamptz not null default now()
);
create index if not exists tama_invite_tries_user_idx on public.tama_invite_tries (user_id, created_at desc);
alter table public.tama_invite_tries enable row level security;

-- 自分の招待コードと、招待した人数。{code, counted:数えた人数, pending:まだ別の日に開いていない人数, invited_by:{id,name}|null}
create or replace function public.tama_my_invite()
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  c  text;
  i  int := 0;
begin
  if me is null then raise exception 'not signed in'; end if;
  select code into c from public.tama_invite_codes where user_id = me;
  while c is null loop
    i := i + 1;
    -- 読み違えやすい 0/O・1/I/L は使わない
    c := (select string_agg(substr('ABCDEFGHJKMNPQRSTUVWXYZ23456789', 1 + floor(random() * 31)::int, 1), '') from generate_series(1, 6));
    begin
      insert into public.tama_invite_codes (user_id, code) values (me, c);
    exception when unique_violation then
      c := null;
      select code into c from public.tama_invite_codes where user_id = me;   -- 同時に2回呼ばれた時
      if i > 20 then raise exception 'could not make a code'; end if;
    end;
  end loop;
  return jsonb_build_object(
    'code', c,
    'counted', (select count(*) from public.tama_invites where inviter_id = me and counted_at is not null),
    'pending', (select count(*) from public.tama_invites where inviter_id = me and counted_at is null),
    'invited_by', (select jsonb_build_object('id', v.inviter_id::text, 'name', p.name)
                     from public.tama_invites v left join public.tama_profiles p on p.id::text = v.inviter_id::text
                    where v.invitee_id = me)
  );
end $$;

-- 招待コードを入れる。{status, id, name}
--   status：'ok' / 'notfound'（そのコードは無い）/ 'self'（自分のコード）/ 'already'（もう入れた）/ 'tries'（入れすぎ）
create or replace function public.tama_use_invite(p_code text)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  v_inviter uuid;
begin
  if me is null then raise exception 'not signed in'; end if;
  if exists (select 1 from public.tama_invites where invitee_id = me) then return jsonb_build_object('status', 'already'); end if;
  if (select count(*) from public.tama_invite_tries where user_id = me and created_at > now() - interval '10 minutes') >= 10 then
    return jsonb_build_object('status', 'tries');
  end if;
  insert into public.tama_invite_tries (user_id) values (me);
  select user_id into v_inviter from public.tama_invite_codes where code = upper(trim(coalesce(p_code, '')));
  if v_inviter is null then return jsonb_build_object('status', 'notfound'); end if;
  if v_inviter = me then return jsonb_build_object('status', 'self'); end if;
  insert into public.tama_invites (invitee_id, inviter_id) values (me, v_inviter) on conflict do nothing;
  return jsonb_build_object('status', 'ok', 'id', v_inviter::text,
                            'name', (select p.name from public.tama_profiles p where p.id::text = v_inviter::text));
end $$;

-- 招待された人がアプリを開くたびに呼ぶ。コードを入れた日（日本時間）とは別の日なら、招待した人の人数に数える
create or replace function public.tama_invite_tick()
returns void language sql volatile security definer set search_path = public as $$
  update public.tama_invites
     set counted_at = now()
   where invitee_id = auth.uid() and counted_at is null
     and (now() at time zone 'Asia/Tokyo')::date > (created_at at time zone 'Asia/Tokyo')::date;
$$;

revoke all on function public.tama_my_invite(), public.tama_use_invite(text), public.tama_invite_tick() from public, anon;
grant execute on function public.tama_my_invite(), public.tama_use_invite(text), public.tama_invite_tick() to authenticated;

notify pgrst, 'reload schema';

-- 確認：関数が3行出ればOK
select proname from pg_proc where proname in ('tama_my_invite', 'tama_use_invite', 'tama_invite_tick') order by proname;

-- 運営用：招待した人数のランキング（読むだけ。必要な時に、下の行の先頭の「-- 」を消して実行）
-- select p.name, count(*) filter (where v.counted_at is not null) as 数えた人数, count(*) filter (where v.counted_at is null) as まだ from public.tama_invites v left join public.tama_profiles p on p.id::text = v.inviter_id::text group by p.name order by 2 desc;
