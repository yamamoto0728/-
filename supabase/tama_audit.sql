-- Supabase の SQL Editor でこのファイルの内容をそのまま実行してください（2026-11-07。読むだけで、何も変えません）。
-- 本番のデータベースの「だれが何を読めて・書けるか」を1つの表にします。結果を全部コピーして Claude に貼ってください。
--
-- 列の意味：
--   種類     … 表 / 決まり / 権限 / 関数
--   名前     … 表や関数の名前
--   中身     … 決まりの条件など
--   危ない   … 「要確認」で始まる行を、まず見る（上にまとめて出ます）

with
tbl as (
  select c.relname as t, c.relrowsecurity as rls
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind in ('r', 'p')
),
pol as (
  select tablename as t, policyname, permissive, roles::text as roles, cmd, coalesce(qual, '') as q, coalesce(with_check, '') as c,
         exists (select 1 from pg_policies r where r.schemaname = 'public' and r.tablename = p.tablename and r.permissive = 'RESTRICTIVE') as has_r
    from pg_policies p where schemaname = 'public'
),
grt as (
  select table_name as t, grantee, string_agg(privilege_type, ',' order by privilege_type) as privs
    from information_schema.role_table_grants
   where table_schema = 'public' and grantee in ('anon', 'authenticated')
   group by table_name, grantee
),
fn as (
  select p.oid::regprocedure::text as sig, p.prosecdef as secdef,
         exists (select 1 from unnest(coalesce(p.proconfig, '{}')) x where x like 'search_path=%') as has_sp,
         has_function_privilege('anon', p.oid, 'execute') as anon_x,
         has_function_privilege('authenticated', p.oid, 'execute') as auth_x,
         pg_get_function_result(p.oid) as ret
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
)
select * from (
  -- 1. 表：RLS が切れていないか
  select '表' as 種類, t as 名前, case when rls then 'RLS あり' else 'RLS なし' end as 中身,
         case when not rls then '要確認：RLS が切れている（だれでも全部読める・書ける）' else '' end as 危ない, 1 as o
    from tbl where t like 'tama\_%' or t in ('push_subscriptions')
  union all
  -- 2. 決まり：ゆるすぎるもの（条件が true だけ・書く決まりで本人を確かめていない）
  select '決まり', t || ' / ' || policyname,
         permissive || ' ' || cmd || ' ' || roles || ' using(' || left(q, 160) || ') check(' || left(c, 160) || ')',
         case
           when has_r and permissive = 'PERMISSIVE' and (q = 'true' or c = 'true') then '（ゆるい決まりだが、絞る決まり r: があるので大丈夫）'
           when permissive = 'PERMISSIVE' and cmd in ('INSERT', 'UPDATE', 'DELETE', 'ALL') and (q in ('', 'true') and c in ('', 'true')) then '要確認：だれの行でも書ける'
           when permissive = 'PERMISSIVE' and cmd in ('SELECT', 'ALL') and q = 'true' and t not in ('tama_profiles', 'tama_booths', 'tama_rooms') then '要確認：だれの行でも読める'
           when roles like '%public%' and permissive = 'PERMISSIVE' and cmd <> 'SELECT' then '要確認：ログインしていない人にも効く書く決まり'
           else '' end, 2
    from pol where t like 'tama\_%' or t in ('push_subscriptions')
  union all
  -- 3. 権限：ログインしていない人（anon）が直接さわれる表
  select '権限', t || ' / ' || grantee, privs,
         case when grantee = 'anon' and t like 'tama\_%' and t <> 'tama_booths' then '要確認：ログインしていない人が直接さわれる' else '' end, 3
    from grt where t like 'tama\_%' or t in ('push_subscriptions')
  union all
  -- 4. 関数：security definer（強い権限で動く関数）の確かめ
  select '関数', sig,
         case when secdef then 'definer' else 'invoker' end || ' / anon:' || anon_x || ' / authenticated:' || auth_x || ' / 戻り値:' || left(ret, 60),
         case
           when secdef and not has_sp then '要確認：search_path が決まっていない'
           when secdef and anon_x and sig !~ '^(tama_bg_ingest|tama_public_count|tama_chikaku_users|tama_funnel_log|tama_survey_mark|fes_public_count|tama_tamasai_count)\(' then '要確認：ログインしていない人が呼べる'
           when secdef and ret = 'trigger' and auth_x then '（トリガー用。直接は呼べないので大丈夫）'
           else '' end, 4
    from fn where sig like 'tama\_%' or sig like 'fes\_%'
  union all
  -- 5. public にある view（view は RLS を通らないので、ここに無いのが正しい）
  select 'view', c.relname, 'public の view', '要確認：view は RLS を通らない。中身を確かめる', 5
    from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and c.relkind = 'v'
  union all
  -- 6. 決まった時刻の仕事（cron）を入れる仕組みがあるか（位置の自動の消去・通報のメールに使う）
  select '拡張', 'pg_cron', case when exists (select 1 from pg_extension where extname = 'pg_cron') then '入っている' else '入っていない' end,
         case when exists (select 1 from pg_extension where extname = 'pg_cron') then '' else '要確認：位置の自動の消去・通報のメールが動かない' end, 6
) x
order by (危ない not like '要確認%') , o, 名前;
