-- Supabase の SQL Editor でこのファイルの内容をそのまま実行してください。
-- コミュニティ（rooms）への「所属」を保存するテーブルです。
-- 何度実行しても同じ結果になるように書いてあります（再実行しても壊れません）。
--
-- このテーブルが解決すること:
--   1. 正確なメンバー数（今までは「投稿した人」しか数えられておらず、ROM専が0人扱いだった）
--   2. プッシュ通知の宛先（誰に送ればいいかが分かるようになる）
--   3. 未読バッジ（last_read_at と room_messages.created_at の比較で出せる）

-- ---------------------------------------------------------------------------
-- テーブル作成
-- ---------------------------------------------------------------------------
-- rooms.id の型（uuid / bigint など）はダッシュボードで作られていてリポジトリに記録が無い。
-- 決め打ちすると型不一致で失敗するため、既存の rooms.id から型を読み取って合わせる。
do $$
declare
  rid_type text;
begin
  select format_type(a.atttypid, a.atttypmod)
    into rid_type
    from pg_attribute a
   where a.attrelid = 'public.rooms'::regclass
     and a.attname  = 'id'
     and a.attnum   > 0
     and not a.attisdropped;

  if rid_type is null then
    raise exception 'public.rooms.id が見つかりません。先に rooms テーブルを確認してください。';
  end if;

  execute format($f$
    create table if not exists public.room_members (
      room_id      %s          not null references public.rooms(id) on delete cascade,
      user_id      uuid        not null,
      joined_at    timestamptz not null default now(),
      last_read_at timestamptz not null default now(),
      primary key (room_id, user_id)
    )
  $f$, rid_type);
end $$;

-- 「自分が入っている部屋」を引く用（クライアントが起動のたびに使う）
create index if not exists room_members_user_idx on public.room_members (user_id);

alter table public.room_members enable row level security;

-- ---------------------------------------------------------------------------
-- RLSポリシー
-- ---------------------------------------------------------------------------
-- ⚠️ SELECTポリシーは必須。無いとPostgREST経由の .upsert() が 403 で弾かれる。
--    （push_subscriptions で実際にこれを踏み、原因特定に数セッション溶かした。詳細はCLAUDE.md）
--    メンバー一覧は「誰が入っているか」を全員に見せる前提なので using (true) でよい。
drop policy if exists "read room members" on public.room_members;
create policy "read room members"
  on public.room_members for select
  using (true);

-- 参加できるのは自分自身の行だけ（他人を勝手に入れられない）
drop policy if exists "join as self" on public.room_members;
create policy "join as self"
  on public.room_members for insert
  with check (auth.uid() = user_id);

-- last_read_at の更新も自分の行だけ
drop policy if exists "update own membership" on public.room_members;
create policy "update own membership"
  on public.room_members for update
  using (auth.uid() = user_id);

-- 退出できるのも自分自身だけ（他人をキックできない）
drop policy if exists "leave as self" on public.room_members;
create policy "leave as self"
  on public.room_members for delete
  using (auth.uid() = user_id);
