-- Supabase の SQL Editor でこのファイルの内容をそのまま実行してください。
-- 学園祭版（/fes/）専用のテーブルを作ります。通常版のテーブルには一切触りません。
-- 何度実行しても同じ結果になるように書いてあります（再実行しても壊れません）。
--
-- なぜ別テーブルにするか:
--   1. 学園祭の来場者に、通常版（常時ログ実験のメンバーなど）の位置が見えないようにする
--   2. 実験データを通常版と混ぜずに、学園祭の分だけ集計できるようにする
--
-- 通常版のテーブル定義はダッシュボードで作られていてリポジトリに記録が無い。
-- 決め打ちで書くと列や型がずれて失敗するため、既存テーブルから「列・制約・インデックス・RLSポリシー」を読み取って複製する。
-- push_subscriptions は Edge Function（send-match-push）が読むので複製せず、通常版と共用する。

do $$
declare
  src   text;
  dst   text;
  pol   record;
  roles text;
begin
  foreach src in array array[
    'profiles', 'encounters', 'likes', 'match_unlocks', 'messages',
    'blocks', 'reports', 'rooms', 'room_members', 'room_messages'
  ] loop
    dst := 'fes_' || src;

    if to_regclass('public.' || src) is null then
      raise notice 'public.% が見つからないので飛ばします', src;
      continue;
    end if;

    -- 列・デフォルト値・主キー/UNIQUE・インデックスを複製（外部キーは複製されない）
    execute format('create table if not exists public.%I (like public.%I including all)', dst, src);

    if (select c.relrowsecurity from pg_class c where c.oid = ('public.' || src)::regclass) then
      execute format('alter table public.%I enable row level security', dst);
    end if;

    -- RLSポリシーを同じ条件で複製（SELECTポリシーが無いと upsert が403になるため、漏れなく写す）
    for pol in
      select * from pg_policies where schemaname = 'public' and tablename = src
    loop
      select string_agg(case when r = 'public' then 'public' else quote_ident(r) end, ', ')
        into roles
        from unnest(pol.roles) as r;

      execute format('drop policy if exists %I on public.%I', pol.policyname, dst);
      execute format(
        'create policy %I on public.%I as %s for %s to %s %s %s',
        pol.policyname, dst, pol.permissive, pol.cmd, roles,
        case when pol.qual       is not null then 'using (' || pol.qual || ')'            else '' end,
        case when pol.with_check is not null then 'with check (' || pol.with_check || ')' else '' end
      );
    end loop;
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- 確認1: 作られたテーブルと、複製されたポリシーの数（通常版と同じ数になっていればOK）
-- ---------------------------------------------------------------------------
select
  t.src                                                                           as 通常版,
  (select count(*) from pg_policies p where p.schemaname = 'public' and p.tablename = t.src)          as 通常版のポリシー数,
  to_regclass('public.fes_' || t.src) is not null                                 as 学園祭版テーブルあり,
  (select count(*) from pg_policies p where p.schemaname = 'public' and p.tablename = 'fes_' || t.src) as 学園祭版のポリシー数
from unnest(array[
  'profiles', 'encounters', 'likes', 'match_unlocks', 'messages',
  'blocks', 'reports', 'rooms', 'room_members', 'room_messages'
]) as t(src);

-- ---------------------------------------------------------------------------
-- 確認2: 通常版のテーブルを参照したままのポリシー（0行ならOK）
-- ---------------------------------------------------------------------------
-- ポリシーの条件の中で別のテーブル（例: likes）を見ている場合、複製しても通常版のテーブルを見たままになる。
-- ここに行が出たら、その条件を fes_ 付きのテーブル名に書き換える必要がある。
select tablename, policyname, qual, with_check
from pg_policies
where schemaname = 'public'
  and tablename like 'fes\_%'
  and (coalesce(qual, '') || ' ' || coalesce(with_check, ''))
      ~ '(^|[^a-z_])(profiles|encounters|likes|match_unlocks|messages|blocks|reports|rooms|room_members|room_messages)([^a-z_]|$)';

-- ---------------------------------------------------------------------------
-- 学園祭が終わったあと（実行するときだけコメントを外す）
-- ---------------------------------------------------------------------------
-- 利用規約で「実証実験の終了後、取得したデータは速やかに削除」としているので、集計が済んだら消す。
-- ⚠️ 元に戻せません。必ず集計用にデータを書き出してから実行すること。
-- truncate public.fes_profiles, public.fes_encounters, public.fes_likes, public.fes_match_unlocks,
--          public.fes_messages, public.fes_blocks, public.fes_reports, public.fes_rooms,
--          public.fes_room_members, public.fes_room_messages;
