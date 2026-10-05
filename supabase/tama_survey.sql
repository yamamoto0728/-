-- Supabase の SQL Editor でこのファイルの内容をそのまま実行してください。
-- 多摩キャン版（/tama/）の「アンケートに答えると特典」の仕組みを作ります（2026-10-05）。ほかのテーブルには触りません。
-- 何度実行しても同じ結果になるように書いてあります（再実行しても壊れません。合言葉も作り直しません）。
--
-- 流れ：Googleフォームの送信 → フォームの Apps Script が参加者番号と合言葉を tama_survey_mark に送る
--       → tama_survey_done に参加者番号が入る → アプリが tama_survey_status で自分の分を確かめて特典を出す。
-- 参加者番号はユーザーIDの先頭8文字（アプリの fesNo()。フォームのURLの {id} に入る）。
-- 合言葉は Apps Script だけが知っている文字列。アプリのコードに載っている anon キーだけでは「回答済み」にできないようにする。
-- 手順の全体は docs/tama-survey.md。

-- 回答済みの参加者番号（読めるのは関数だけ。RLS を有効にしてポリシーを作らない）
create table if not exists public.tama_survey_done (
  participant_no text        primary key,
  answered_at    timestamptz not null default now(),
  answers        int         not null default 1        -- 同じ番号で何回送られたか
);
alter table public.tama_survey_done enable row level security;

-- 合言葉（1行だけ。読めるのは関数とSQL Editorだけ）
create table if not exists public.tama_survey_secret (
  id     int  primary key default 1 check (id = 1),
  secret text not null
);
alter table public.tama_survey_secret enable row level security;
insert into public.tama_survey_secret (id, secret)
values (1, md5(random()::text || clock_timestamp()::text) || md5(random()::text))
on conflict (id) do nothing;

-- Apps Script から呼ぶ。合言葉が合っていて、番号の形が正しければ記録して true
create or replace function public.tama_survey_mark(p_no text, p_secret text)
returns boolean
language plpgsql volatile security definer set search_path = public
as $$
declare
  n text := lower(trim(coalesce(p_no, '')));
begin
  if p_secret is null or p_secret is distinct from (select secret from public.tama_survey_secret where id = 1) then
    return false;
  end if;
  if n !~ '^[0-9a-f]{8}$' then return false; end if;
  insert into public.tama_survey_done as d (participant_no) values (n)
  on conflict (participant_no) do update set answers = d.answers + 1;
  return true;
end $$;

-- アプリから呼ぶ。自分（ログイン中のユーザー）が回答済みか
create or replace function public.tama_survey_status()
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (select 1 from public.tama_survey_done where participant_no = left(auth.uid()::text, 8));
$$;

revoke all on function public.tama_survey_mark(text, text) from public;
revoke all on function public.tama_survey_status() from public, anon;
grant execute on function public.tama_survey_mark(text, text) to anon, authenticated;
grant execute on function public.tama_survey_status() to authenticated;

notify pgrst, 'reload schema';

-- 確認: 関数が2行出ればOK。下の合言葉（secret）を Apps Script の SECRET に貼る（ほかの人に見せない）
select proname from pg_proc where proname in ('tama_survey_mark', 'tama_survey_status') order by proname;
select secret from public.tama_survey_secret;

-- ---------------------------------------------------------------------------
-- 実験が終わったあと（実行するときだけコメントを外す）
-- ---------------------------------------------------------------------------
-- 回答した人数:  select count(*) from public.tama_survey_done;
-- ⚠️ 元に戻せません。必ず集計用にデータを書き出してから実行すること。
-- truncate public.tama_survey_done;
