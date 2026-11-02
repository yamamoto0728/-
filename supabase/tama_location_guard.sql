-- Supabase の SQL Editor でこのファイルの内容をそのまま実行してください（2026-11-02）。
-- 何度実行しても同じ結果になるように書いてあります（再実行しても壊れません）。
-- ⚠️ 先に、この SQL と同じ PR（feat/location-guard）のアプリが本番に出ていること（Vercel のデプロイが終わってから実行する）。
--    古いアプリのままこれを実行すると、近くの人が約100mの区切りでしか出なくなる（壊れはしない）。
--
-- あおの依頼「アプリ化に向けて審査とセキュリティを強化しよう」。2026-10-28 に見つけた問題を直す：
--   tama_profiles の select は「ログインした人なら全員分読める」で、ちかくは匿名ログインをだれでもできるので、
--   ページに入っている公開キーさえあれば、学内にいる全員の名前と正確な緯度・経度が読めた。
--   NauNau（2023年）は、これと同じ「データベースから位置がそのまま読めた」問題で止まった。
--
-- 直し方（正確な位置はサーバーの中だけに置き、外には出さない）：
--   1. 正確な位置は新しい表 tama_locs に移す。ポリシーを作らない＝アプリからは読めない（関数の中からだけ使う）。
--      持つのは1人1行（最新の位置だけ）。キャンパスの外の位置は持たない。3時間たった行は消す。
--   2. tama_profiles に書かれた位置は、トリガーで約100mの区切り（小数3けた）に丸めてから保存する。
--      だれでも読めるのはこの丸めた位置だけ（「ぼかして出す」を選んだ人と同じ細かさ）。
--   3. 近くの人の位置は、関数 tama_nearby() で返す。返すのは、
--      ・呼んだ本人が、いまキャンパスの中で位置を共有している時だけ（家から全員の位置を見ることはできない）
--      ・位置は約30mの区切り（「ぼかして出す」の人は約100m）。正確な緯度・経度は返さない
--      ・すれ違いの判定（50m以内か）はサーバーが正確な位置で計算して、はい／いいえだけ返す
--      ・おたがいどちらかがブロックしている人、利用を止めた人は返さない
--   4. ブロックした人から、自分のプロフィールが見えないようにする（前はブロックしても相手からは見えていた）。
--
-- 限界（正直に書いておく）：
--   ・自分の位置を偽って送れば、その場所のまわり（約30m）の人は見える。偽の位置もキャンパスの中でないと使えず、
--     位置の更新は3秒に1回までしか受け付けないので、まとめて調べ回るのは難しくしてある。
--   ・本当に確実にするには、ログイン（Apple・Google）と、送る回数の上限をもっと厳しくすることが要る。

-- ---------------------------------------------------------------------------
-- 1. 正確な位置を置く表（アプリからは読めない・書けない）
-- ---------------------------------------------------------------------------
create table if not exists public.tama_locs (
  id     text primary key,                       -- tama_profiles.id（型をそろえないため text で持つ）
  lat    double precision not null,
  lng    double precision not null,
  coarse boolean not null default false,         -- 本人が「ぼかして出す」を選んでいる
  at     timestamptz not null default now()
);
alter table public.tama_locs enable row level security;
revoke all on public.tama_locs from anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. 道具：キャンパスの形の中か・2点の距離（m）
--    形は tama/index.html の CAMPUS と同じ（66点）。形を変えた時は両方直す
-- ---------------------------------------------------------------------------
create or replace function public.tama_in_campus(p_lat double precision, p_lng double precision)
returns boolean language plpgsql immutable set search_path = public as $$
declare
  poly double precision[] := array[array[35.61719,139.28974],array[35.61699,139.28978],array[35.61728,139.29197],array[35.61708,139.29211],array[35.61545,139.2918],array[35.61519,139.29193],array[35.61499,139.29217],array[35.61473,139.29381],array[35.61255,139.29435],array[35.61219,139.29549],array[35.61265,139.296],array[35.61351,139.29604],array[35.61345,139.29642],array[35.61295,139.29651],array[35.6134,139.29737],array[35.61313,139.29768],array[35.6134,139.29808],array[35.61304,139.2988],array[35.6127,139.29908],array[35.61253,139.29886],array[35.61212,139.29918],array[35.61184,139.2989],array[35.61222,139.29957],array[35.61147,139.29986],array[35.6107,139.30198],array[35.61081,139.30254],array[35.61096,139.30273],array[35.61136,139.30283],array[35.61146,139.3032],array[35.61144,139.30286],array[35.61158,139.30257],array[35.61221,139.30225],array[35.61243,139.30188],array[35.61263,139.30044],array[35.61235,139.2998],array[35.61269,139.30038],array[35.61267,139.30069],array[35.61297,139.30103],array[35.61377,139.30057],array[35.6137,139.30032],array[35.61331,139.30035],array[35.6129,139.29919],array[35.61318,139.29926],array[35.61382,139.3],array[35.61493,139.30047],array[35.61498,139.30075],array[35.61574,139.30084],array[35.61625,139.29967],array[35.61608,139.29717],array[35.61628,139.2971],array[35.61629,139.29661],array[35.61656,139.29661],array[35.61661,139.29567],array[35.61749,139.29475],array[35.6176,139.29446],array[35.61803,139.29417],array[35.6184,139.29426],array[35.61847,139.29383],array[35.61919,139.2937],array[35.6194,139.29248],array[35.61971,139.29182],array[35.62038,139.29128],array[35.62034,139.29021],array[35.61988,139.28987],array[35.61726,139.29039],array[35.61719,139.28974]]::float8[];
  n int := array_length(poly, 1);
  i int; j int; inside boolean := false;
  yi double precision; xi double precision; yj double precision; xj double precision;
begin
  if p_lat is null or p_lng is null then return false; end if;
  j := n;
  for i in 1..n loop
    yi := poly[i][1]; xi := poly[i][2]; yj := poly[j][1]; xj := poly[j][2];
    if ((yi > p_lat) <> (yj > p_lat)) and (p_lng < (xj - xi) * (p_lat - yi) / (yj - yi) + xi) then
      inside := not inside;
    end if;
    j := i;
  end loop;
  return inside;
end $$;

create or replace function public.tama_dist_m(a_lat double precision, a_lng double precision, b_lat double precision, b_lng double precision)
returns double precision language sql immutable set search_path = public as $$
  select sqrt(power((b_lat - a_lat) * 111320, 2) + power((b_lng - a_lng) * 111320 * cos(radians(a_lat)), 2))
$$;

-- 丸めた値か（小数3けた＝約100mの区切り）。トリガーが、丸めた後の値をもう一度「新しい位置」と思わないように使う
create or replace function public.tama_is_coarse_val(v double precision)
returns boolean language sql immutable set search_path = public as $$
  select v is not null and v = round(v::numeric, 3)::double precision
$$;

-- ---------------------------------------------------------------------------
-- 3. tama_profiles に書かれた位置を tama_locs に移して、表には丸めた位置だけ残す
--    upsert は「挿入のトリガー → ぶつかったら更新のトリガー」の順に動く。
--    挿入のトリガーで丸めた値が更新のトリガーにも来るので、丸めた値は新しい位置として扱わない
-- ---------------------------------------------------------------------------
create or replace function public.tama_profiles_guard_loc()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  raw  boolean;
  prev record;
begin
  raw := new.lat is not null and new.lng is not null
     and (tg_op = 'INSERT'
          or ((new.lat is distinct from old.lat or new.lng is distinct from old.lng)
              and not (public.tama_is_coarse_val(new.lat) and public.tama_is_coarse_val(new.lng))));

  if new.sharing is not true then
    -- 共有を止めた・キャンパスを出た：正確な位置は持たない
    delete from public.tama_locs where id = new.id::text;
  elsif raw then
    if public.tama_in_campus(new.lat, new.lng) then
      -- 偽の位置をくり返し送って「50m以内か」を聞き回り、まわりの人の位置を割り出すのを難しくする
      -- （2024年の研究で、Hinge・Hily はこのやり方で位置を割り出せた）：
      --   ・位置の更新は3秒に1回まで
      --   ・前の位置から秒速15m（時速54km）より速く動いたことになる位置は受け付けない（10分以上たっていれば受け付ける）
      select l.lat, l.lng, l.at into prev from public.tama_locs l where l.id = new.id::text;
      if prev.at is null
         or (prev.at < now() - interval '3 seconds'
             and (prev.at < now() - interval '10 minutes'
                  or public.tama_dist_m(prev.lat, prev.lng, new.lat, new.lng)
                     <= 15 * extract(epoch from (now() - prev.at)))) then
        insert into public.tama_locs (id, lat, lng, coarse, at)
        values (new.id::text, new.lat, new.lng, coalesce(new.coarse, false), now())
        on conflict (id) do update set lat = excluded.lat, lng = excluded.lng, coarse = excluded.coarse, at = now();
      end if;
    else
      -- キャンパスの外の位置は持たない・ほかの人にも出さない（アプリも外では送らないが、古い版・いたずらに備えて）
      delete from public.tama_locs where id = new.id::text;
      new.sharing := false;
    end if;
  end if;

  if raw then
    new.lat := round(new.lat::numeric, 3)::double precision;
    new.lng := round(new.lng::numeric, 3)::double precision;
  end if;
  return new;
end $$;
drop trigger if exists tama_profiles_guard_loc on public.tama_profiles;
create trigger tama_profiles_guard_loc before insert or update on public.tama_profiles
  for each row execute function public.tama_profiles_guard_loc();

-- プロフィールを消したら、正確な位置も消す
create or replace function public.tama_profiles_drop_loc()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  delete from public.tama_locs where id = old.id::text;
  return old;
end $$;
drop trigger if exists tama_profiles_drop_loc on public.tama_profiles;
create trigger tama_profiles_drop_loc after delete on public.tama_profiles
  for each row execute function public.tama_profiles_drop_loc();

-- 今ある正確な位置を丸める（キャンパスにいる人は、次に位置を送った時から tama_locs に入る）
update public.tama_profiles
   set lat = round(lat::numeric, 3)::double precision, lng = round(lng::numeric, 3)::double precision
 where lat is not null and not (public.tama_is_coarse_val(lat) and public.tama_is_coarse_val(lng));

-- ---------------------------------------------------------------------------
-- 4. 近くの人（アプリから呼ぶ）。返り値：uid・約30mの区切りの位置・すれ違いの距離（50m）以内か
-- ---------------------------------------------------------------------------
create or replace function public.tama_nearby()
returns table (uid text, glat double precision, glng double precision, near boolean)
language plpgsql stable security definer set search_path = public as $$
declare
  me text := auth.uid()::text;
  m  record;
begin
  if me is null then return; end if;
  if exists (select 1 from public.tama_bans b where b.user_id::text = me) then return; end if;
  -- 呼んだ本人が、いまキャンパスの中で位置を共有している時だけ（10分以内に位置を送っている）
  select l.lat, l.lng into m from public.tama_locs l where l.id = me and l.at > now() - interval '10 minutes';
  if not found then return; end if;
  return query
    select l.id,
           case when l.coarse then round(l.lat::numeric, 3)::double precision else round(l.lat / 0.00027) * 0.00027 end,
           case when l.coarse then round(l.lng::numeric, 3)::double precision else round(l.lng / 0.00033) * 0.00033 end,
           public.tama_dist_m(m.lat, m.lng, l.lat, l.lng) <= 50
      from public.tama_locs l
      join public.tama_profiles p on p.id::text = l.id and p.sharing is true
     where l.id <> me
       and l.at > now() - interval '2 hours'
       and not exists (select 1 from public.tama_blocks k
                        where (k.blocker_id::text = me and k.blocked_id::text = l.id)
                           or (k.blocker_id::text = l.id and k.blocked_id::text = me))
       and not exists (select 1 from public.tama_bans b where b.user_id::text = l.id);
end $$;

revoke all on function public.tama_nearby() from public, anon;
grant execute on function public.tama_nearby() to authenticated;
revoke all on function public.tama_profiles_guard_loc() from public, anon, authenticated;
revoke all on function public.tama_profiles_drop_loc() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 5. ブロックした人から、自分のプロフィールが見えないようにする
--    （tama_blocks は本人の行しか読めないので、ポリシーの中では関数で確かめる）
-- ---------------------------------------------------------------------------
create or replace function public.tama_blocked_by(p_owner text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.tama_blocks k
                  where k.blocker_id::text = p_owner and k.blocked_id::text = auth.uid()::text)
$$;
revoke all on function public.tama_blocked_by(text) from public, anon;
grant execute on function public.tama_blocked_by(text) to authenticated;

drop policy if exists "signed in users read profiles" on public.tama_profiles;
create policy "signed in users read profiles" on public.tama_profiles for select to authenticated
  using (not public.tama_blocked_by(id::text));

-- ---------------------------------------------------------------------------
-- 6. 3時間たった正確な位置を消す（30分ごと。pg_cron がある時だけ）
-- ---------------------------------------------------------------------------
do $$
begin
  if exists (select 1 from pg_namespace where nspname = 'cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'tama-locs-cleanup';
    perform cron.schedule('tama-locs-cleanup', '*/30 * * * *',
      $c$delete from public.tama_locs where at < now() - interval '3 hours'$c$);
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 7. 前の版（学園祭版・通常版）の表に残っている正確な位置も丸める（表がある時だけ）
-- ---------------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['fes_profiles', 'profiles'] loop
    if to_regclass('public.' || t) is not null
       and exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = t and column_name = 'lat')
       and exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = t and column_name = 'lng') then
      execute format('update public.%I set lat = round(lat::numeric, 3)::double precision, lng = round(lng::numeric, 3)::double precision
                       where lat is not null and lat <> round(lat::numeric, 3)::double precision', t);
    end if;
  end loop;
end $$;

notify pgrst, 'reload schema';

-- ---------------------------------------------------------------------------
-- 確認：下の表が出ればOK
--   ・正確な位置が残っているプロフィール = 0
--   ・tama_locs を読めるアプリの決まり = 0
--   ・tama_nearby・トリガー2つ・cron がある
-- ---------------------------------------------------------------------------
select '正確な位置が残っているプロフィール' as 項目,
       count(*)::text as 結果
  from public.tama_profiles where lat is not null and not (public.tama_is_coarse_val(lat) and public.tama_is_coarse_val(lng))
union all
select 'tama_locs を読めるアプリの決まり', count(*)::text from pg_policies where tablename = 'tama_locs'
union all
select 'tama_nearby があるか', (to_regprocedure('public.tama_nearby()') is not null)::text
union all
select 'トリガー', string_agg(tgname, ' / ') from pg_trigger where tgrelid = 'public.tama_profiles'::regclass and tgname in ('tama_profiles_guard_loc', 'tama_profiles_drop_loc')
union all
select 'pg_cron があるか（位置を3時間で消す）', (to_regclass('cron.job') is not null)::text;

-- 参考：tama_ の表の読む決まりの一覧（ほかに「だれでも読める」が残っていないかを見る。結果を Claude に貼ってください）
select tablename, policyname, cmd, array_to_string(roles, ',') as roles, qual
  from pg_policies
 where schemaname = 'public' and tablename like 'tama\_%' and cmd in ('SELECT', 'ALL')
 order by tablename, policyname;
