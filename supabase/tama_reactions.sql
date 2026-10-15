-- トークのリアクション（2026-10-15 しゅうすけさんの依頼）
-- Supabase の SQL Editor でこのファイルの内容をそのまま実行してください。何度実行しても同じ結果になります。
-- 実行しなくてもアプリは今まで通り動きます（吹き出しを押してもリアクションの選ぶ所が出ないだけ）。
--
-- 1対1のトーク（tama_messages）の吹き出しに、👍❤️😂😮😢🙏 のどれか1つを付けられる。1人1つまで（付け直すと置きかわる）。
-- 読めるのも書けるのも、その会話の2人だけ（match_key は「2人のIDを並べて __ でつないだもの」。tama_messages と同じ）。

create table if not exists public.tama_msg_reactions (
  msg_id     text        not null,                       -- tama_messages.id（文字にして持つ）
  match_key  text        not null,                       -- 会話の2人（tama_messages.match_key と同じ）
  user_id    uuid        not null default auth.uid(),    -- 付けた人
  emoji      text        not null check (emoji in ('👍','❤️','😂','😮','😢','🙏')),
  created_at timestamptz not null default now(),
  primary key (msg_id, user_id)
);
create index if not exists tama_msg_reactions_key on public.tama_msg_reactions (match_key);

alter table public.tama_msg_reactions enable row level security;

-- 読む：会話の2人だけ
drop policy if exists "talk members read reactions" on public.tama_msg_reactions;
create policy "talk members read reactions" on public.tama_msg_reactions for select to authenticated
using ( auth.uid()::text = any (string_to_array(match_key, '__')) );

-- 付ける：自分の分だけ・会話の2人のうちの1人・その会話に本当にあるメッセージだけ
drop policy if exists "talk members add reactions" on public.tama_msg_reactions;
create policy "talk members add reactions" on public.tama_msg_reactions for insert to authenticated
with check (
  user_id = auth.uid()
  and auth.uid()::text = any (string_to_array(match_key, '__'))
  and exists (select 1 from public.tama_messages m
               where m.id::text = tama_msg_reactions.msg_id and m.match_key = tama_msg_reactions.match_key)
);

-- 付け直す（upsert）：自分の分だけ
drop policy if exists "talk members change reactions" on public.tama_msg_reactions;
create policy "talk members change reactions" on public.tama_msg_reactions for update to authenticated
using ( user_id = auth.uid() )
with check (
  user_id = auth.uid()
  and auth.uid()::text = any (string_to_array(match_key, '__'))
  and exists (select 1 from public.tama_messages m
               where m.id::text = tama_msg_reactions.msg_id and m.match_key = tama_msg_reactions.match_key)
);

-- 外す：自分の分。プロフィールを消す時は、自分の会話のリアクションをまとめて消せる（相手の分も）
drop policy if exists "talk members remove reactions" on public.tama_msg_reactions;
create policy "talk members remove reactions" on public.tama_msg_reactions for delete to authenticated
using ( user_id = auth.uid() or auth.uid()::text = any (string_to_array(match_key, '__')) );

-- 確認：下の2行が出ればOK（ポリシーが4つ）
select 'リアクションの表', count(*) from public.tama_msg_reactions;
select 'リアクションの決まり', count(*) from pg_policies where schemaname = 'public' and tablename = 'tama_msg_reactions';
