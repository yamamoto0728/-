-- Supabase の SQL Editor でこのファイルの内容をそのまま実行してください。
-- 多摩キャン版（/tama/、学園祭の前に学食のQRから入ってもらう簡易実験）専用のテーブルを作ります。
-- 通常版・学園祭版のテーブルには一切触りません。何度実行しても同じ結果になります。
--
-- なぜ別テーブルにするか:
--   学園祭の前に取るデータ（保険）を、学園祭当日のデータと混ぜずに集計できるようにするため。
--
-- 学園祭版の fes_ テーブル（属性の fes_attrs 列・いいねの matched 列・RLSポリシー込み）を読み取って複製する。
-- ⚠️ 先に fes_tables.sql / fes_attributes.sql / fes_notifications.sql が実行済みであること（2026-09-13 に実行済み）。
-- 出店（fes_booths）と時間で全員に送る通知（fes_scheduled_pushes）は多摩キャン版では使わないので作らない。
-- push_subscriptions は Edge Function（send-match-push）が読むので複製せず共用する。

do $$
declare
  src   text;
  dst   text;
  pol   record;
  roles text;
begin
  foreach src in array array[
    'profiles', 'encounters', 'likes', 'match_unlocks', 'messages',
    'blocks', 'reports', 'rooms', 'room_members', 'room_messages', 'push_log'
  ] loop
    dst := 'tama_' || src;

    if to_regclass('public.fes_' || src) is null then
      raise notice 'public.fes_% が見つからないので飛ばします', src;
      continue;
    end if;

    -- 列・デフォルト値・主キー/UNIQUE・インデックスを複製（外部キーは複製されない）
    execute format('create table if not exists public.%I (like public.%I including all)', dst, 'fes_' || src);

    if (select c.relrowsecurity from pg_class c where c.oid = ('public.fes_' || src)::regclass) then
      execute format('alter table public.%I enable row level security', dst);
    end if;

    -- RLSポリシーを同じ条件で複製（SELECTポリシーが無いと upsert が403になるため、漏れなく写す）
    for pol in
      select * from pg_policies where schemaname = 'public' and tablename = 'fes_' || src
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

notify pgrst, 'reload schema';

-- ---------------------------------------------------------------------------
-- 確認1: 11行すべて「多摩キャン版テーブルあり = true」で、ポリシー数が学園祭版と同じならOK
-- ---------------------------------------------------------------------------
select
  t.src                                                                                                  as テーブル,
  (select count(*) from pg_policies p where p.schemaname = 'public' and p.tablename = 'fes_'  || t.src) as 学園祭版のポリシー数,
  to_regclass('public.tama_' || t.src) is not null                                                       as 多摩キャン版テーブルあり,
  (select count(*) from pg_policies p where p.schemaname = 'public' and p.tablename = 'tama_' || t.src) as 多摩キャン版のポリシー数
from unnest(array[
  'profiles', 'encounters', 'likes', 'match_unlocks', 'messages',
  'blocks', 'reports', 'rooms', 'room_members', 'room_messages', 'push_log'
]) as t(src);

-- ---------------------------------------------------------------------------
-- 確認2: 属性の列が複製されているか（2行出ればOK）
-- ---------------------------------------------------------------------------
select table_name, column_name
from information_schema.columns
where table_schema = 'public'
  and ((table_name = 'tama_profiles' and column_name = 'fes_attrs')
    or (table_name = 'tama_likes'    and column_name = 'matched'));

-- ---------------------------------------------------------------------------
-- 実験が終わったあと（実行するときだけコメントを外す）
-- ---------------------------------------------------------------------------
-- ⚠️ 元に戻せません。必ず集計用にデータを書き出してから実行すること。
-- truncate public.tama_profiles, public.tama_encounters, public.tama_likes, public.tama_match_unlocks,
--          public.tama_messages, public.tama_blocks, public.tama_reports, public.tama_rooms,
--          public.tama_room_members, public.tama_room_messages, public.tama_push_log;
