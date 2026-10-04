-- Supabase の SQL Editor でこのファイルの内容をそのまま実行してください。
-- 学園祭版（/fes/）を多摩キャン版（/tama/）と同じ機能にするために、多摩キャン版だけにあった表・関数を fes_ 付きで作ります（2026-10-04）。
-- 中身は下の5つのファイルの tama_ を fes_ に置き換えたもの（多摩キャン版のSQLを直したら、こちらも同じように直すこと）:
--   tama_friends.sql / tama_friend_code.sql / tama_timetable.sql / tama_timetable_share.sql / tama_retention.sql
-- 多摩キャン版・通常版の表には触りません。何度実行しても同じ結果になります。
-- ⚠️ 先に fes_tables.sql / fes_attributes.sql / fes_notifications.sql が実行済みであること（2026-09-13 に実行済み）。
-- 授業のはじめの通知（tama_remind.sql・Edge Function tama-remind）は、学園祭は土日で授業が無いので作らない。

-- ===========================================================================
-- tama_friends.sql より
-- ===========================================================================
-- 学園祭版（/fes/）の「友達」と「いまどこ（建物・教室）」のテーブルを作ります。ほかのテーブルには触りません。
-- 何度実行しても同じ結果になるように書いてあります（再実行しても壊れません）。
-- ⚠️ 先に supabase/fes_tables.sql を実行済みであること（2026-09-13 に実行済み）。

-- ---------------------------------------------------------------------------
-- 1. 友達（申請 → 承認）
-- ---------------------------------------------------------------------------
-- 1行 = 1件の申請。status が 'accepted' になった行が「友達」。
create table if not exists public.fes_friends (
  id           bigint generated always as identity primary key,
  from_id      uuid        not null,                       -- 申請した人
  to_id        uuid        not null,                       -- 申請された人
  status       text        not null default 'pending' check (status in ('pending', 'accepted')),
  created_at   timestamptz not null default now(),
  responded_at timestamptz,
  unique (from_id, to_id),
  check (from_id <> to_id)
);
create index if not exists fes_friends_to_idx on public.fes_friends (to_id);

alter table public.fes_friends enable row level security;

-- 自分が関わる申請だけ読める（⚠️ SELECTポリシーが無いと upsert が403になる）
drop policy if exists "read own friend rows" on public.fes_friends;
create policy "read own friend rows" on public.fes_friends for select
  using (auth.uid() = from_id or auth.uid() = to_id);

-- 自分から「申請中」の行だけ作れる（いきなり友達にはできない）
drop policy if exists "send friend request" on public.fes_friends;
create policy "send friend request" on public.fes_friends for insert to authenticated
  with check (auth.uid() = from_id and status = 'pending');

-- 承認できるのは申請された側だけ
drop policy if exists "accept friend request" on public.fes_friends;
create policy "accept friend request" on public.fes_friends for update to authenticated
  using (auth.uid() = to_id) with check (auth.uid() = to_id);

-- 断る・取り消す・友達をやめるは、どちらからでもできる
drop policy if exists "remove friend row" on public.fes_friends;
create policy "remove friend row" on public.fes_friends for delete to authenticated
  using (auth.uid() = from_id or auth.uid() = to_id);

-- ---------------------------------------------------------------------------
-- 2. いまどこ（建物・教室・ひとこと・友達への公開範囲）
-- ---------------------------------------------------------------------------
-- 1人1行。建物（place）は位置から自動で入り、教室（room）とひとこと（note）は本人が入れる。
-- visibility: 'map' = 地図の位置も見せる / 'building' = 建物と教室だけ / 'hidden' = 友達にも見せない
create table if not exists public.fes_presence (
  id         uuid        primary key,
  place      text,
  room       text,
  note       text,
  visibility text        not null default 'building' check (visibility in ('map', 'building', 'hidden')),
  expires_at timestamptz,                                  -- 教室・ひとことが消える時刻（入力から90分）
  updated_at timestamptz not null default now()
);

alter table public.fes_presence enable row level security;

-- 読めるのは本人と、承認済みの友達だけ。'hidden' の人は友達からも読めない。
-- （教室まで分かる情報なので、アプリの表示だけでなくデータベース側で読める人を絞る）
drop policy if exists "read presence self or friends" on public.fes_presence;
create policy "read presence self or friends" on public.fes_presence for select
  using (
    auth.uid() = id
    or (visibility <> 'hidden' and exists (
      select 1 from public.fes_friends f
      where f.status = 'accepted'
        and ((f.from_id = auth.uid() and f.to_id = fes_presence.id)
          or (f.to_id = auth.uid() and f.from_id = fes_presence.id))
    ))
  );

drop policy if exists "write own presence" on public.fes_presence;
create policy "write own presence" on public.fes_presence for insert to authenticated
  with check (auth.uid() = id);

drop policy if exists "update own presence" on public.fes_presence;
create policy "update own presence" on public.fes_presence for update to authenticated
  using (auth.uid() = id) with check (auth.uid() = id);

drop policy if exists "delete own presence" on public.fes_presence;
create policy "delete own presence" on public.fes_presence for delete to authenticated
  using (auth.uid() = id);

notify pgrst, 'reload schema';

-- 確認: 2行出て、ポリシー数が fes_friends=4 / fes_presence=4 ならOK
select tablename, count(*) as ポリシー数
from pg_policies
where schemaname = 'public' and tablename in ('fes_friends', 'fes_presence')
group by tablename;

-- ---------------------------------------------------------------------------
-- 実験が終わったあと（実行するときだけコメントを外す）
-- ---------------------------------------------------------------------------
-- ⚠️ 元に戻せません。必ず集計用にデータを書き出してから実行すること。
-- truncate public.fes_friends, public.fes_presence;

-- ===========================================================================
-- tama_friend_code.sql より
-- ===========================================================================
-- 学園祭版の「4桁のコードで友達になる」と「友達どうしのメッセージ」に必要なものを作ります。
-- 何度実行しても同じ結果になるように書いてあります（再実行しても壊れません）。
-- （fes_friends は、このファイルの上の部分で作られる）

-- ---------------------------------------------------------------------------
-- 1. 友達コード（表示してから5分だけ使える4桁の数字）
-- ---------------------------------------------------------------------------
-- ポリシーを作らない＝アプリから直接は読めも書けもしない（下の関数だけが使う）。
-- 読めると、いま有効なコードを全部見て、知らない人と勝手に友達になれてしまうため
create table if not exists public.fes_friend_codes (
  code       text        primary key,
  owner_id   uuid        not null,
  expires_at timestamptz not null
);
alter table public.fes_friend_codes enable row level security;

-- コードを入れた記録（総当たり対策で、1人10分に10回までに制限するため）
create table if not exists public.fes_friend_code_tries (
  id         bigint      generated always as identity primary key,
  user_id    uuid        not null,
  created_at timestamptz not null default now()
);
create index if not exists fes_friend_code_tries_user_idx on public.fes_friend_code_tries (user_id, created_at desc);
alter table public.fes_friend_code_tries enable row level security;

-- 自分のコードを出す。前に出したコードは消し、いま使われていない4桁を選ぶ
create or replace function public.fes_issue_friend_code()
returns table (code text, expires_at timestamptz)
language plpgsql volatile security definer set search_path = public
as $$
#variable_conflict use_column
declare
  c text;
  i int := 0;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  delete from public.fes_friend_codes f where f.expires_at < now() or f.owner_id = auth.uid();
  loop
    c := lpad((floor(random() * 10000))::int::text, 4, '0');
    exit when not exists (select 1 from public.fes_friend_codes f where f.code = c);
    i := i + 1;
    if i > 200 then raise exception 'no free code'; end if;
  end loop;
  insert into public.fes_friend_codes (code, owner_id, expires_at) values (c, auth.uid(), now() + interval '5 minutes');
  return query select c, now() + interval '5 minutes';
end $$;

-- 相手のコードを入れて友達になる（承認なし。目の前でコードを見せている時点で同意しているとみなす）。
-- status: 'ok' / 'not_found'（無い・期限切れ・ブロック関係）/ 'self'（自分のコード）/ 'too_many'（入力しすぎ）
create or replace function public.fes_add_friend_by_code(p_code text)
returns table (friend_id uuid, status text)
language plpgsql volatile security definer set search_path = public
as $$
#variable_conflict use_column
declare
  me uuid := auth.uid();
  other uuid;
  tries int;
begin
  if me is null then raise exception 'not signed in'; end if;
  insert into public.fes_friend_code_tries (user_id) values (me);
  select count(*) into tries from public.fes_friend_code_tries t where t.user_id = me and t.created_at > now() - interval '10 minutes';
  if tries > 10 then return query select null::uuid, 'too_many'; return; end if;

  select f.owner_id into other from public.fes_friend_codes f where f.code = p_code and f.expires_at > now();
  if other is null then return query select null::uuid, 'not_found'; return; end if;
  if other = me then return query select null::uuid, 'self'; return; end if;
  -- どちらかがブロックしている相手とは友達にしない（ブロックされていることは相手に知らせない）
  if exists (select 1 from public.fes_blocks b
             where (b.blocker_id::text = me::text and b.blocked_id::text = other::text)
                or (b.blocker_id::text = other::text and b.blocked_id::text = me::text)) then
    return query select null::uuid, 'not_found'; return;
  end if;

  -- すでに申請の行があれば友達にし、無ければ友達の行を作る
  update public.fes_friends fr set status = 'accepted', responded_at = now()
   where (fr.from_id = me and fr.to_id = other) or (fr.from_id = other and fr.to_id = me);
  if not found then
    insert into public.fes_friends (from_id, to_id, status, responded_at) values (me, other, 'accepted', now());
  end if;
  return query select other, 'ok';
end $$;

revoke all on function public.fes_issue_friend_code() from public, anon;
revoke all on function public.fes_add_friend_by_code(text) from public, anon;
grant execute on function public.fes_issue_friend_code() to authenticated;
grant execute on function public.fes_add_friend_by_code(text) to authenticated;

-- ---------------------------------------------------------------------------
-- 2. 友達どうしのメッセージ
-- ---------------------------------------------------------------------------
-- メッセージはマッチと同じ fes_messages（match_key = 2人のIDを並べて '__' でつないだもの）。
-- 今あるポリシーはそのまま残し、「承認済みの友達どうしなら読める・送れる」を足す（ポリシーは OR で効くので、今の動きは変わらない）
drop policy if exists "friends read messages" on public.fes_messages;
create policy "friends read messages" on public.fes_messages for select to authenticated
  using (
    auth.uid()::text = any (string_to_array(match_key, '__'))
    and exists (select 1 from public.fes_friends f
                where f.status = 'accepted'
                  and ((f.from_id = auth.uid() and f.to_id::text = any (string_to_array(match_key, '__')))
                    or (f.to_id = auth.uid() and f.from_id::text = any (string_to_array(match_key, '__')))))
  );

drop policy if exists "friends send messages" on public.fes_messages;
create policy "friends send messages" on public.fes_messages for insert to authenticated
  with check (
    from_id::text = auth.uid()::text
    and auth.uid()::text = any (string_to_array(match_key, '__'))
    and exists (select 1 from public.fes_friends f
                where f.status = 'accepted'
                  and ((f.from_id = auth.uid() and f.to_id::text = any (string_to_array(match_key, '__')))
                    or (f.to_id = auth.uid() and f.from_id::text = any (string_to_array(match_key, '__')))))
  );

notify pgrst, 'reload schema';

-- 確認: 関数が2行、fes_messages のポリシーに friends read messages / friends send messages が出ればOK
select proname from pg_proc where proname in ('fes_issue_friend_code', 'fes_add_friend_by_code');
select policyname, cmd from pg_policies where schemaname = 'public' and tablename = 'fes_messages' order by policyname;

-- ---------------------------------------------------------------------------
-- 実験が終わったあと（実行するときだけコメントを外す）
-- ---------------------------------------------------------------------------
-- truncate public.fes_friend_codes, public.fes_friend_code_tries;

-- ===========================================================================
-- tama_timetable.sql より
-- ===========================================================================
-- 学園祭版（/fes/）の「時間割（履修）」のテーブルと、「同じ授業の人」を返す関数を作ります。ほかのテーブルには触りません。
-- 何度実行しても同じ結果になるように書いてあります（再実行しても壊れません）。

-- ---------------------------------------------------------------------------
-- 1. 時間割（1人1行）
-- ---------------------------------------------------------------------------
-- slots の例: {"1-2": "マーケティング論", "3-1": ""}
--   キー = 曜日(1=月〜5=金) - 時限(1〜5)、値 = 授業名（任意。空なら名前なし）
-- 使い道: ①授業のある時限の始まりにだけ「いまどこ？」の通知を送る（Edge Function tama-remind）
--         ②同じ曜日・時限に同じ授業名を入れた人を「同じ授業」として共通点に出す
create table if not exists public.fes_timetable (
  id         uuid        primary key,
  slots      jsonb       not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);

alter table public.fes_timetable enable row level security;

-- 「毎週いつどこにいるか」が分かる情報なので、読めるのも書けるのも本人だけ
-- （⚠️ SELECTポリシーが無いと upsert が403になる）
drop policy if exists "read own timetable" on public.fes_timetable;
create policy "read own timetable" on public.fes_timetable for select
  using (auth.uid() = id);

drop policy if exists "insert own timetable" on public.fes_timetable;
create policy "insert own timetable" on public.fes_timetable for insert to authenticated
  with check (auth.uid() = id);

drop policy if exists "update own timetable" on public.fes_timetable;
create policy "update own timetable" on public.fes_timetable for update to authenticated
  using (auth.uid() = id) with check (auth.uid() = id);

drop policy if exists "delete own timetable" on public.fes_timetable;
create policy "delete own timetable" on public.fes_timetable for delete to authenticated
  using (auth.uid() = id);

-- ---------------------------------------------------------------------------
-- 2. 同じ授業の人
-- ---------------------------------------------------------------------------
-- 自分と「同じ曜日・同じ時限に、同じ授業名」を入れている人だけを返す。
-- 他の人の時間割そのものは返さない（RLS で読めない表を、この関数だけが必要な分だけ見る）。
-- 授業名は全角・半角、大文字・小文字、空白の違いをそろえてから比べる（アプリの normCourse と同じ）。
create or replace function public.fes_same_course_peers()
returns table (other_id uuid, slot text, course text)
language sql stable security definer set search_path = public
as $$
  with mine as (
    select s.key as slot, s.value as course,
           lower(regexp_replace(normalize(s.value, NFKC), '\s+', '', 'g')) as n
    from public.fes_timetable t, jsonb_each_text(t.slots) s
    where t.id = auth.uid()
  )
  select o.id, m.slot, m.course
  from public.fes_timetable o, jsonb_each_text(o.slots) s, mine m
  where o.id <> auth.uid()
    and m.n <> ''
    and s.key = m.slot
    and lower(regexp_replace(normalize(s.value, NFKC), '\s+', '', 'g')) = m.n
$$;

revoke all on function public.fes_same_course_peers() from public, anon;
grant execute on function public.fes_same_course_peers() to authenticated;

notify pgrst, 'reload schema';

-- 確認: ポリシー数が 4、関数が 1 行出ればOK
select tablename, count(*) as ポリシー数 from pg_policies
where schemaname = 'public' and tablename = 'fes_timetable' group by tablename;
select proname from pg_proc where proname = 'fes_same_course_peers';

-- ---------------------------------------------------------------------------
-- 実験が終わったあと（実行するときだけコメントを外す）
-- ---------------------------------------------------------------------------
-- ⚠️ 元に戻せません。必ず集計用にデータを書き出してから実行すること。
-- truncate public.fes_timetable;

-- ===========================================================================
-- tama_timetable_share.sql より
-- ===========================================================================
-- 学園祭版（/fes/）の時間割に「教室名」を足し、「時間割を友達に見せる」機能の表とルールを作ります（2026-09-28）。
-- （fes_timetable・fes_friends は、このファイルの上の部分で作られる）
-- 何度実行しても同じ結果になるように書いてあります（再実行しても壊れません）。

-- ---------------------------------------------------------------------------
-- 1. 時間割に教室名の列を足す
-- ---------------------------------------------------------------------------
-- rooms の例: {"4-2": "A棟401"}（キーは slots と同じ「曜日-時限」。任意）
-- 授業のある時限に「いまの自分」を開くと、この教室名が候補のボタンとして出る
alter table public.fes_timetable add column if not exists rooms jsonb not null default '{}'::jsonb;

-- ---------------------------------------------------------------------------
-- 2. 時間割を見せる相手（本人が友達ごとに選ぶ）
-- ---------------------------------------------------------------------------
-- 1行 =「owner_id の人が friend_id の人に、自分の時間割（授業名・教室）を見せている」
create table if not exists public.fes_timetable_shares (
  owner_id   uuid        not null,
  friend_id  uuid        not null,
  created_at timestamptz not null default now(),
  primary key (owner_id, friend_id)
);

alter table public.fes_timetable_shares enable row level security;

-- 読めるのは、見せている本人と、見せてもらっている相手だけ
drop policy if exists "read own shares" on public.fes_timetable_shares;
create policy "read own shares" on public.fes_timetable_shares for select to authenticated
  using (auth.uid() = owner_id or auth.uid() = friend_id);

-- 見せる相手を足せるのは本人だけ。相手は承認済みの友達に限る
drop policy if exists "insert own shares" on public.fes_timetable_shares;
create policy "insert own shares" on public.fes_timetable_shares for insert to authenticated
  with check (
    auth.uid() = owner_id
    and exists (select 1 from public.fes_friends f
                where f.status = 'accepted'
                  and ((f.from_id = owner_id and f.to_id = friend_id) or (f.to_id = owner_id and f.from_id = friend_id)))
  );

-- やめられるのも本人だけ
drop policy if exists "delete own shares" on public.fes_timetable_shares;
create policy "delete own shares" on public.fes_timetable_shares for delete to authenticated
  using (auth.uid() = owner_id);

-- ---------------------------------------------------------------------------
-- 3. 見せてもらっている友達の時間割を読めるようにする
-- ---------------------------------------------------------------------------
-- いまの「本人だけ読める」ルールはそのまま残し、「見せてもらっていて、いまも友達なら読める」を足す（ポリシーは OR で効く）。
-- 友達をやめると、見せる設定の行が残っていても読めなくなる
drop policy if exists "friends read shared timetable" on public.fes_timetable;
create policy "friends read shared timetable" on public.fes_timetable for select to authenticated
  using (
    exists (select 1 from public.fes_timetable_shares s
            where s.owner_id = fes_timetable.id and s.friend_id = auth.uid())
    and exists (select 1 from public.fes_friends f
                where f.status = 'accepted'
                  and ((f.from_id = fes_timetable.id and f.to_id = auth.uid()) or (f.to_id = fes_timetable.id and f.from_id = auth.uid())))
  );

notify pgrst, 'reload schema';

-- 確認: rooms 列が1行、fes_timetable のポリシーに friends read shared timetable、fes_timetable_shares のポリシーが3つ出ればOK
select column_name from information_schema.columns where table_schema = 'public' and table_name = 'fes_timetable' and column_name = 'rooms';
select tablename, policyname from pg_policies where schemaname = 'public' and tablename in ('fes_timetable', 'fes_timetable_shares') order by tablename, policyname;

-- ---------------------------------------------------------------------------
-- 実験が終わったあと（実行するときだけコメントを外す）
-- ---------------------------------------------------------------------------
-- ⚠️ 元に戻せません。必ず集計用にデータを書き出してから実行すること。
-- truncate public.fes_timetable_shares;

-- ===========================================================================
-- tama_retention.sql より
-- ===========================================================================
-- 学園祭版の「入れたい・続けたい」の改善（2026-10-01）に必要なものを作ります。ほかのテーブルの中身には触りません。
-- 何度実行しても同じ結果になるように書いてあります（再実行しても壊れません）。
-- ⚠️ 先に supabase/fes_tables.sql を実行済みであること（2026-09-13 に実行済み）。
-- 実行しなくてもアプリは今まで通り動く（お題の「みんなの答え」・ホーム画面追加の案内の人数が出ず、開いた日の記録がされないだけ）。
--
-- 作るもの
--   1. fes_daily_stats(...)  今日のお題の「みんなの答え」（人数と割合）を返す
--   2. fes_public_count()    ホーム画面に追加する前の案内に出す「登録した人数・今日使った人数」を返す（ログイン前でも呼べる）
--   3. fes_visits            開いた日の記録（1人1日1行。位置は記録しない）と、それを書く関数 fes_log_visit(...)

-- ---------------------------------------------------------------------------
-- 1. 今日のお題の「みんなの答え」
-- ---------------------------------------------------------------------------
-- 答えはプロフィール（fes_profiles.fes_attrs）の daily = {d:日付, q:お題の番号, a:答え, n:そろえた答え} に入っている。
-- 次の日に答えると、前の日の答えは daily_prev に移る（アプリ側）ので、「昨日の結果」も数えられる。
-- 人数が少ないと割合から誰が何と答えたか分かってしまうので（あおの決定、2026-10-01）:
--   ・回答が5人未満の間は人数（total）だけを返す
--   ・自由記述（p_free）は、3人以上が同じ答えのものだけ・多い順に3つまで返す
create or replace function public.fes_daily_stats(p_d text, p_q int, p_free boolean default false)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  v_total  int;
  v_groups jsonb;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  with ans as (
    select coalesce(nullif(x->>'n', ''), lower(x->>'a')) as k, x->>'a' as a
      from public.fes_profiles p
      cross join lateral (values (p.fes_attrs->'daily'), (p.fes_attrs->'daily_prev')) v(x)
     where x is not null
       and x->>'d' = p_d
       and x->>'q' = p_q::text
       and coalesce(x->>'a', '') <> ''
  ), g as (
    select k, min(a) as a, count(*)::int as c from ans group by k
  )
  select (select count(*)::int from ans),
         coalesce((select jsonb_agg(jsonb_build_object('a', s.a, 'c', s.c) order by s.c desc, s.a)
                     from (select * from g
                            where not p_free or g.c >= 3
                            order by g.c desc, g.a
                            limit case when p_free then 3 else 10 end) s), '[]'::jsonb)
    into v_total, v_groups;
  if v_total < 5 then return jsonb_build_object('total', v_total); end if;
  return jsonb_build_object('total', v_total, 'groups', v_groups);
end $$;

revoke all on function public.fes_daily_stats(text, int, boolean) from public, anon;
grant execute on function public.fes_daily_stats(text, int, boolean) to authenticated;

-- ---------------------------------------------------------------------------
-- 2. ホーム画面に追加する前の案内に出す人数
-- ---------------------------------------------------------------------------
-- スマホのブラウザで開いた人は、ホーム画面に追加するまでログインしない（Safari とアプリで別人になるのを防ぐため）。
-- そのためログイン前（anon）でも呼べるようにし、数だけを返す（名前・位置などは返さない）。
-- 少ない数をそのまま見せると逆効果なので、10人未満の時はアプリ側で出さない
create or replace function public.fes_public_count()
returns jsonb
language sql stable security definer set search_path = public
as $$
  select jsonb_build_object(
    'total', (select count(*) from public.fes_profiles),
    'today', (select count(*) from public.fes_profiles
               where updated_at::timestamptz >= (date_trunc('day', now() at time zone 'Asia/Tokyo') at time zone 'Asia/Tokyo'))
  )
$$;

revoke all on function public.fes_public_count() from public;
grant execute on function public.fes_public_count() to anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. 開いた日の記録（続けて使われているかを測る）
-- ---------------------------------------------------------------------------
-- 1人1日（日本時間）1行。位置は記録しない（あおの決定、2026-10-01。利用規約の第4条に記載）。
--   opens      その日にアプリを開いた回数（5分以上あけて開き直したら1回と数える。数えるのはアプリ側）
--   on_campus  その日、キャンパスの中で位置が取れたか
--   nearby_max その日「いまキャンパスにいる人」に出た人数の最大
--   push_ok    通知を許可していたか
--   standalone ホーム画面のアプリから開いたか（PCのブラウザは false）
--   daily      その日のお題に答えたか
--   ver        アプリの版（変更の前後で比べるため）
-- ポリシーを作らない＝アプリから直接は読めも書けもしない（下の関数だけが書く）
create table if not exists public.fes_visits (
  user_id    uuid        not null,
  day        date        not null,
  opens      int         not null default 0,
  first_at   timestamptz not null default now(),
  last_at    timestamptz not null default now(),
  on_campus  boolean     not null default false,
  nearby_max int         not null default 0,
  push_ok    boolean     not null default false,
  standalone boolean     not null default false,
  daily      boolean     not null default false,
  ver        text,
  primary key (user_id, day)
);
alter table public.fes_visits enable row level security;

create or replace function public.fes_log_visit(
  p_open boolean, p_on_campus boolean, p_nearby int, p_push boolean, p_standalone boolean, p_daily boolean, p_ver text)
returns void
language plpgsql volatile security definer set search_path = public
as $$
declare
  me uuid := auth.uid();
  d  date := (now() at time zone 'Asia/Tokyo')::date;
begin
  if me is null then return; end if;
  insert into public.fes_visits as v (user_id, day, opens, on_campus, nearby_max, push_ok, standalone, daily, ver)
  values (me, d, case when p_open then 1 else 0 end, coalesce(p_on_campus, false),
          least(greatest(coalesce(p_nearby, 0), 0), 10000), coalesce(p_push, false),
          coalesce(p_standalone, false), coalesce(p_daily, false), left(p_ver, 20))
  on conflict (user_id, day) do update set
    opens      = v.opens + case when p_open then 1 else 0 end,
    last_at    = now(),
    on_campus  = v.on_campus or coalesce(p_on_campus, false),
    nearby_max = greatest(v.nearby_max, least(greatest(coalesce(p_nearby, 0), 0), 10000)),
    push_ok    = v.push_ok or coalesce(p_push, false),
    standalone = v.standalone or coalesce(p_standalone, false),
    daily      = v.daily or coalesce(p_daily, false),
    ver        = coalesce(left(p_ver, 20), v.ver);
end $$;

-- 「プロフィールを消す」を押した人の記録を消す（利用規約 第10条「いつでも自分の情報を削除できます」）
create or replace function public.fes_forget_visits()
returns void
language sql volatile security definer set search_path = public
as $$
  delete from public.fes_visits where user_id = auth.uid();
$$;

revoke all on function public.fes_log_visit(boolean, boolean, int, boolean, boolean, boolean, text) from public, anon;
revoke all on function public.fes_forget_visits() from public, anon;
grant execute on function public.fes_log_visit(boolean, boolean, int, boolean, boolean, boolean, text) to authenticated;
grant execute on function public.fes_forget_visits() to authenticated;

notify pgrst, 'reload schema';

-- 確認: 関数が4行、fes_visits が1行出ればOK
select proname from pg_proc where proname in ('fes_daily_stats', 'fes_public_count', 'fes_log_visit', 'fes_forget_visits') order by proname;
select tablename from pg_tables where schemaname = 'public' and tablename = 'fes_visits';

-- ---------------------------------------------------------------------------
-- 続けて使われているかを見る（実行するときだけコメントを外す）
-- ---------------------------------------------------------------------------
-- 初めて開いた日ごとに、その後の何日目に戻ってきたか（0日目＝初日）:
--   with f as (select user_id, min(day) as d0 from public.fes_visits group by user_id)
--   select f.d0, (v.day - f.d0) as nth_day, count(*) as people
--     from public.fes_visits v join f using (user_id)
--    group by 1, 2 order by 1, 2;
-- 平日5日のうち何日開いたか（週ごと）:
--   select date_trunc('week', day)::date as week, user_id, count(*) filter (where extract(isodow from day) <= 5) as weekdays
--     from public.fes_visits group by 1, 2 order by 1, 3 desc;

-- ---------------------------------------------------------------------------
-- 実験が終わったあと（データを書き出してから、実行するときだけコメントを外す）
-- ---------------------------------------------------------------------------
-- drop table if exists public.fes_visits;
-- drop function if exists public.fes_log_visit(boolean, boolean, int, boolean, boolean, boolean, text);
-- drop function if exists public.fes_forget_visits();
-- drop function if exists public.fes_daily_stats(text, int, boolean);
-- drop function if exists public.fes_public_count();
