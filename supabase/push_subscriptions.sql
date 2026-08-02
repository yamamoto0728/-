-- Supabase の SQL Editor でこのファイルの内容をそのまま実行してください。
-- マッチ通知（Web Push）の購読情報を保存するテーブルです。

create table if not exists public.push_subscriptions (
  id uuid primary key,
  subscription jsonb not null,
  updated_at timestamptz not null default now()
);

alter table public.push_subscriptions enable row level security;

-- 自分（匿名認証のuser id = profiles.id と同じ）の購読情報だけ登録・更新・削除できる
create policy "insert own subscription"
  on public.push_subscriptions for insert
  with check (auth.uid() = id);

create policy "update own subscription"
  on public.push_subscriptions for update
  using (auth.uid() = id);

create policy "delete own subscription"
  on public.push_subscriptions for delete
  using (auth.uid() = id);

-- SELECTポリシーが無いとPostgREST経由の`.upsert()`がRLSで403になる（Edge Function自体はservice roleで
-- RLSを回避して読むため不要に思えるが、クライアントのsupabase-js upsertには必須）。原因調査の詳細はCLAUDE.md参照。
create policy "select own subscription"
  on public.push_subscriptions for select
  using (auth.uid() = id);
