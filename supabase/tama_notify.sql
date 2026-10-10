-- Supabase の SQL Editor でこのファイルの内容をそのまま実行してください（2026-10-10）。
-- 何度実行しても同じ結果になるように書いてあります（再実行しても壊れません）。
-- 実行しなくてもアプリは今まで通り動く（届かない通知の自動の直し・通知の記録・ちかくタイムが動かないだけ）。
--
-- ⚠️ 実行したあと、Edge Function を2つ貼り直してデプロイすること（ダッシュボード → Edge Functions → それぞれ開いて中身を置きかえる）
--    supabase/functions/send-match-push/index.ts … 1人の複数の端末に送る・通知の種類ごとのオフ・送った記録
--    supabase/functions/tama-remind/index.ts     … 昼休みの通知に「いまキャンパスに◯人」・ちかくタイムの通知
--
-- 1. tama_push_devices  通知の送り先を端末ごとに持つ（前は1人1つで、別の端末で開くと上書きされていた）
-- 2. tama_push_events   通知を送った・押して開いた記録（どの通知が効いているかを比べるため。位置や本文は記録しない）
-- 3. ちかくタイム        週2〜3回、平日の休み時間のどこかで10分だけのお題（tama_ct_questions → tama_ct_slots）

-- ---------------------------------------------------------------------------
-- 1. 端末ごとの送り先
-- ---------------------------------------------------------------------------
-- push_subscriptions（通常版・学園祭版と共用、1人1行）はそのまま残し、アプリは両方に書く。
-- 送る側（Edge Function）は両方を読んで、同じ送り先（endpoint）は1回だけ送る
create table if not exists public.tama_push_devices (
  endpoint     text primary key,
  user_id      uuid not null,
  subscription jsonb not null,
  updated_at   timestamptz not null default now()
);
create index if not exists tama_push_devices_user on public.tama_push_devices (user_id);
alter table public.tama_push_devices enable row level security;

-- 自分の端末だけ読める・消せる（「サーバーから消されていないか」をアプリが確かめるため）。書くのは下の関数だけ
drop policy if exists "own devices read" on public.tama_push_devices;
create policy "own devices read" on public.tama_push_devices for select to authenticated using (user_id = auth.uid());
drop policy if exists "own devices delete" on public.tama_push_devices;
create policy "own devices delete" on public.tama_push_devices for delete to authenticated using (user_id = auth.uid());

-- 端末を登録する。同じ端末で別の人がログインし直した時は、その人のものに付けかえる（RLS だけだと付けかえられないため関数にする）
create or replace function public.tama_push_register(p_sub jsonb)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if coalesce(p_sub->>'endpoint', '') !~ '^https://' or length(p_sub::text) > 4000 then raise exception 'bad subscription'; end if;
  insert into public.tama_push_devices (endpoint, user_id, subscription, updated_at)
  values (p_sub->>'endpoint', auth.uid(), p_sub, now())
  on conflict (endpoint) do update set user_id = excluded.user_id, subscription = excluded.subscription, updated_at = now();
end $$;
revoke all on function public.tama_push_register(jsonb) from public, anon;
grant execute on function public.tama_push_register(jsonb) to authenticated;

-- ---------------------------------------------------------------------------
-- 2. 通知の記録
-- ---------------------------------------------------------------------------
-- ev：sent（1台以上に届けた）／fail（送れなかった）／off（その種類をオフにしていた）／open（通知を押してアプリを開いた）
-- kind：msg・like・friend・nearby・room・daily・class・ct・test
-- sent・fail・off は Edge Function が書く。open はアプリが自分の分だけ書ける。アプリからは読めない（運営が SQL Editor で見る）
create table if not exists public.tama_push_events (
  id         bigserial primary key,
  user_id    uuid not null,
  kind       text not null check (length(kind) <= 16),
  ev         text not null check (ev in ('sent', 'fail', 'off', 'open')),
  created_at timestamptz not null default now()
);
create index if not exists tama_push_events_kind on public.tama_push_events (kind, created_at);
alter table public.tama_push_events enable row level security;
drop policy if exists "own open insert" on public.tama_push_events;
create policy "own open insert" on public.tama_push_events for insert to authenticated with check (user_id = auth.uid() and ev = 'open');

-- ---------------------------------------------------------------------------
-- 3. ちかくタイム（2026-10-10 あおの決定：週2〜3回・10分だけのお題・その日は自動の通知が3通まで）
-- ---------------------------------------------------------------------------
-- お題の一覧。Table Editor で足したり直したりしてよい（o1・o2 は選択肢。重い質問は入れない）
create table if not exists public.tama_ct_questions (
  id      serial primary key,
  q       text not null unique,
  o1      text not null,
  o2      text not null,
  used_at timestamptz
);
alter table public.tama_ct_questions enable row level security;   -- アプリからは読まない（出る前に分からないように）

insert into public.tama_ct_questions (q, o1, o2) values
  ('いま、おなかすいてる？', 'すいてる', 'まだ平気'),
  ('次の授業、ある？', 'ある', 'もう終わり・空き'),
  ('いまいる所、屋内？屋外？', '屋内', '屋外'),
  ('今日のお昼、もう食べた？', '食べた', 'まだ'),
  ('いま、ひとり？', 'ひとり', 'だれかといる'),
  ('今日、ここまで何で来た？', 'バス', 'それ以外'),
  ('いま飲みたいのは？', 'あたたかいもの', 'つめたいもの'),
  ('今日の気分は？', 'まあまあ', 'けっこういい'),
  ('次の休みの日、出かける予定ある？', 'ある', 'ない'),
  ('いま、眠い？', '眠い', '目がさえてる'),
  ('朝ごはん、食べてきた？', '食べた', '食べてない'),
  ('いま聴きたいのは？', 'しっとりした曲', 'アガる曲'),
  ('今日、帰ったら何する？', 'ゆっくりする', '予定がある'),
  ('いまのスマホの充電、半分ある？', 'ある', 'ない'),
  ('甘いものとしょっぱいもの、いまなら？', '甘いもの', 'しょっぱいもの'),
  ('今日の服、決めるのに時間かかった？', 'かかった', 'すぐ決めた'),
  ('いま、課題に追われてる？', '追われてる', '余裕あり'),
  ('今週、あと何日キャンパスに来る？', '1日以下', '2日以上'),
  ('いまの天気、好き？', '好き', 'いまいち'),
  ('食堂で頼むなら？', 'ごはん系', '麺系'),
  ('授業中の席、前と後ろどっち派？', '前のほう', '後ろのほう'),
  ('いま、外を歩きたい？', '歩きたい', '座っていたい'),
  ('今日、だれかと話した？', '話した', 'まだあまり'),
  ('コンビニで買うなら？', 'おにぎり', 'パン'),
  ('いま、手もとに飲み物ある？', 'ある', 'ない'),
  ('今日の授業、楽しかったのあった？', 'あった', 'これから'),
  ('空きコマは何して過ごす？', 'ひとりで過ごす', 'だれかと過ごす'),
  ('いま、イヤホンしてる？', 'してる', 'してない'),
  ('夜型？朝型？', '夜型', '朝型'),
  ('いま行くなら、どっち？', '食堂', '図書館'),
  ('今日の夜ごはん、決まってる？', '決まってる', 'まだ'),
  ('いま、少し寒い？', '寒い', 'ちょうどいい'),
  ('写真、よく撮るほう？', '撮る', 'あまり撮らない'),
  ('今週末、早起きする？', 'する', 'しない'),
  ('いまの気分を色で言うと？', 'あたたかい色', 'すずしい色'),
  ('キャンパスで好きな場所、ある？', 'ある', 'まだない'),
  ('いま、何か読んでる・見てるものある？', 'ある', 'とくにない'),
  ('今日、いつもより早く来た？', '早く来た', 'いつもどおり'),
  ('休み時間は、スマホを見る？', '見る', 'あまり見ない'),
  ('いま、だれかとごはんに行けそう？', '行けそう', '今日はむり')
on conflict (q) do nothing;

-- その週の「ちかくタイム」。出す時刻（starts_at）とお題を、週のはじめに決めておく。
-- アプリからは「始まった後のもの」だけ読める（いつ来るか分からないように、先の予定は見えない）
create table if not exists public.tama_ct_slots (
  id        bigserial primary key,
  starts_at timestamptz not null unique,
  q         text not null,
  o1        text not null,
  o2        text not null,
  sent_at   timestamptz
);
alter table public.tama_ct_slots enable row level security;
drop policy if exists "started slots read" on public.tama_ct_slots;
create policy "started slots read" on public.tama_ct_slots for select to authenticated using (starts_at <= now());

-- 出す時刻の候補（日本時間・平日の休み時間）。昼休みのはじめ（12:55 のお題の通知）とは重ねない
--   11:00（2限の前の10分休み）・13:10・13:25（昼休み）・15:20（4限の前）・17:10（5限の前）
-- その週の月〜金から、まだ過ぎていない日を2〜3日選び、それぞれ候補の時刻を1つ選ぶ。お題は使っていない順（同じくらいなら選ばれる順は決まっていない）
create or replace function public.tama_ct_plan()
returns int language plpgsql security definer set search_path = public as $$
declare
  v_today date := (now() at time zone 'Asia/Tokyo')::date;
  v_mon   date := date_trunc('week', (now() at time zone 'Asia/Tokyo'))::date;
  v_times time[] := array['11:00','13:10','13:25','15:20','17:10']::time[];
  v_n     int := 2 + (random() < 0.5)::int;
  v_made  int := 0;
  d       date;
  t       time;
  v_at    timestamptz;
  qq      record;
begin
  -- この週の分がもうあれば作らない
  if exists (select 1 from public.tama_ct_slots
              where starts_at >= (v_mon::timestamp at time zone 'Asia/Tokyo')
                and starts_at <  ((v_mon + 7)::timestamp at time zone 'Asia/Tokyo')) then
    return 0;
  end if;
  for d in
    select x::date from generate_series(v_mon, v_mon + 4, interval '1 day') x
     where x::date >= v_today
     order by random()
  loop
    exit when v_made >= v_n;
    -- 今日なら、まだ5分以上先の時刻だけ
    select tt into t from unnest(v_times) tt
     where (d + tt)::timestamp at time zone 'Asia/Tokyo' > now() + interval '5 minutes'
     order by random() limit 1;
    continue when t is null;
    v_at := (d + t)::timestamp at time zone 'Asia/Tokyo';
    select * into qq from public.tama_ct_questions order by used_at nulls first, random() limit 1;
    continue when qq is null;
    insert into public.tama_ct_slots (starts_at, q, o1, o2) values (v_at, qq.q, qq.o1, qq.o2) on conflict (starts_at) do nothing;
    update public.tama_ct_questions set used_at = now() where id = qq.id;
    v_made := v_made + 1;
  end loop;
  return v_made;
end $$;
revoke all on function public.tama_ct_plan() from public, anon, authenticated;

-- ちかくタイムの答えの数。答えはプロフィール（fes_attrs.ct = {id: スロットの番号, a: 答え}）に入る。
-- 今日のお題と同じく、5人未満の間は人数（total）だけを返す（割合から誰が何と答えたか分からないように）
create or replace function public.tama_ct_stats(p_id bigint)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_total int; v_groups jsonb;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  with ans as (
    select p.fes_attrs->'ct'->>'a' as a from public.tama_profiles p
     where p.fes_attrs->'ct'->>'id' = p_id::text and coalesce(p.fes_attrs->'ct'->>'a', '') <> ''
  )
  select (select count(*)::int from ans),
         coalesce((select jsonb_agg(jsonb_build_object('a', a, 'c', c) order by c desc, a)
                     from (select a, count(*)::int c from ans group by a) g), '[]'::jsonb)
    into v_total, v_groups;
  if v_total < 5 then return jsonb_build_object('total', v_total); end if;
  return jsonb_build_object('total', v_total, 'groups', v_groups);
end $$;
revoke all on function public.tama_ct_stats(bigint) from public, anon;
grant execute on function public.tama_ct_stats(bigint) to authenticated;

-- 自動で動かす（pg_cron）
--   毎週月曜 0:05（日本時間）にその週の予定を作る
--   平日の候補の時刻に tama-remind（kind: ct）を呼ぶ。その時刻が予定に入っていれば通知を送る（入っていなければ何もしない）
create extension if not exists pg_cron;
create extension if not exists pg_net;

do $$
declare
  j record;
  -- Authorization の値は tama/index.html にも書かれている公開用の anon キー（秘密の鍵ではない。tama_remind.sql と同じ）
  anon text := 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InJvc2d2bnhxY3V5ZW5saXBha2NrIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODMyNTQ5MDEsImV4cCI6MjA5ODgzMDkwMX0.SrEjGpoZUe6yfOMnQ-g6Cb-cBUg4L8AIElJ5e8UFXyg';
begin
  if exists (select 1 from cron.job where jobname = 'tama-ct-plan') then perform cron.unschedule('tama-ct-plan'); end if;
  perform cron.schedule('tama-ct-plan', '5 15 * * 0', 'select public.tama_ct_plan()');   -- 日曜 15:05（世界標準時）＝月曜 0:05（日本時間）
  for j in select * from (values
    ('tama-ct-1100', '0 2 * * 1-5'),
    ('tama-ct-1310', '10 4 * * 1-5'),
    ('tama-ct-1325', '25 4 * * 1-5'),
    ('tama-ct-1520', '20 6 * * 1-5'),
    ('tama-ct-1710', '10 8 * * 1-5')
  ) as v(name, sched)
  loop
    if exists (select 1 from cron.job where jobname = j.name) then perform cron.unschedule(j.name); end if;
    perform cron.schedule(j.name, j.sched, format(
      $cmd$select net.http_post(
        url     := 'https://rosgvnxqcuyenlipakck.supabase.co/functions/v1/tama-remind',
        headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer %s'),
        body    := '{"kind":"ct"}'::jsonb
      )$cmd$, anon));
  end loop;
end $$;

-- 今週の分を今すぐ作る（もうあれば何もしない）
select public.tama_ct_plan() as 今週のちかくタイムを作った数;

notify pgrst, 'reload schema';

-- 確認：tama-ct- で始まる6行が active = true で出ればOK
select jobname, schedule, active from cron.job where jobname like 'tama-ct-%' order by jobname;

-- ---------------------------------------------------------------------------
-- 見るための SQL（実行するときだけコメントを外す）
-- ---------------------------------------------------------------------------
-- 今週のちかくタイムの予定（運営だけが見られる。アプリには始まるまで出ない）:
--   select starts_at at time zone 'Asia/Tokyo' as 日本時間, q, o1, o2, sent_at from tama_ct_slots order by starts_at desc limit 10;
-- 通知の種類ごとの「押して開いた割合」（直近14日）:
--   select kind,
--          count(*) filter (where ev = 'sent') as 届けた,
--          count(*) filter (where ev = 'open') as 開いた,
--          round(100.0 * count(*) filter (where ev = 'open') / nullif(count(*) filter (where ev = 'sent'), 0), 1) as 開いた割合,
--          count(*) filter (where ev = 'fail') as 送れなかった,
--          count(*) filter (where ev = 'off')  as オフにしていた
--     from tama_push_events where created_at > now() - interval '14 days' group by kind order by 届けた desc;
-- 通知が届かないと言われた人（名前で探す）の送り先と、直近の記録:
--   select p.name, d.updated_at, split_part(d.endpoint, '/', 3) as 送り先 from tama_profiles p join tama_push_devices d on d.user_id = p.id where p.name like '%名前%';
--   select e.kind, e.ev, e.created_at at time zone 'Asia/Tokyo' from tama_push_events e join tama_profiles p on p.id = e.user_id where p.name like '%名前%' order by e.created_at desc limit 30;
