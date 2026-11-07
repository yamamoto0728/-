-- Supabase の SQL Editor でこのファイルの内容をそのまま実行してください（2026-11-07）。
-- ⚠️ 先に supabase/tama_community.sql（部屋）・tama_safety.sql（tama_jobs）・tama_bg_cross.sql（tama_norm）を実行済みであること。
-- 何度実行しても同じ結果になるように書いてあります（再実行しても壊れません）。
-- 実行しなくてもアプリは動く（ホームの「今週のイベント」が出ないだけ）。
--
-- 2026-11-07 あおの依頼「今日のお題とは別に、週に1回のイベント。すれ違いマッチング系」：
--   ・今週のテーマは2つ：運営が出すテーマ（source='ops'）と、みんなが先週提案して票の多かったテーマ（source='vote'）
--   ・答えは、運営が用意した選択肢から選ぶか、自分で書く（書いた答えは、ほかの人の選択肢にも並ぶ）。だめな言葉は入れられない。2人から通報されたら隠す
--   ・同じ答えが5人そろったら、その答えの「今週だけの部屋」を自動で作り、答えた人を入れて知らせる（運営が見守る・オーナーなし・日曜の夜で終わり）
--   ・悩みのテーマ（kind='worry'）は部屋を作らない（だれが弱っているか分かってしまうため）。「同じ人が◯人」だけ
--   ・今週の答え（悩み以外）は、すれ違いの共通点にも入る（プロフィールの fes_attrs.wk＝{w:週の月曜, a:[{o:選択肢の番号, l:答え}]}。tama_simple_common も直す）
--
-- 運営が来週のテーマを出す時は、下の「5. 運営のテーマ」の insert を、week と title・選択肢を変えて実行する

-- ---------------------------------------------------------------------------
-- 1. 表（アプリからは直接読めない。下の関数からだけ使う）
-- ---------------------------------------------------------------------------
create table if not exists public.tama_wk_themes (
  id          bigserial primary key,
  week        date not null,                                   -- その週の月曜（日本時間）
  title       text not null check (char_length(title) between 1 and 40),
  norm        text not null default '',
  kind        text not null default 'like' check (kind in ('goal', 'like', 'season', 'campus', 'fun', 'worry')),
  source      text not null default 'ops' check (source in ('ops', 'vote')),
  status      text not null default 'active' check (status in ('proposed', 'active', 'hidden')),
  proposed_by uuid,
  created_at  timestamptz not null default now()
);
create table if not exists public.tama_wk_votes (
  theme_id   bigint not null references public.tama_wk_themes (id) on delete cascade,
  user_id    uuid not null,
  created_at timestamptz not null default now(),
  primary key (theme_id, user_id)
);
create table if not exists public.tama_wk_opts (
  id         bigserial primary key,
  theme_id   bigint not null references public.tama_wk_themes (id) on delete cascade,
  label      text not null check (char_length(label) between 1 and 20),
  norm       text not null,
  created_by uuid,                                             -- null＝運営が用意した選択肢
  hidden     boolean not null default false,
  created_at timestamptz not null default now(),
  unique (theme_id, norm)
);
create table if not exists public.tama_wk_answers (
  theme_id   bigint not null references public.tama_wk_themes (id) on delete cascade,
  user_id    uuid not null,
  opt_id     bigint not null references public.tama_wk_opts (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (theme_id, user_id)
);
create table if not exists public.tama_wk_rooms (
  opt_id     bigint primary key references public.tama_wk_opts (id) on delete cascade,
  room_id    text not null,
  created_at timestamptz not null default now()
);
create table if not exists public.tama_wk_reports (
  kind       text not null check (kind in ('opt', 'theme')),
  target_id  bigint not null,
  user_id    uuid not null,
  created_at timestamptz not null default now(),
  primary key (kind, target_id, user_id)
);
alter table public.tama_wk_themes  enable row level security;
alter table public.tama_wk_votes   enable row level security;
alter table public.tama_wk_opts    enable row level security;
alter table public.tama_wk_answers enable row level security;
alter table public.tama_wk_rooms   enable row level security;
alter table public.tama_wk_reports enable row level security;
revoke all on public.tama_wk_themes, public.tama_wk_votes, public.tama_wk_opts, public.tama_wk_answers, public.tama_wk_rooms, public.tama_wk_reports from anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. 道具：今週の月曜（日本時間）・だめな言葉
-- ---------------------------------------------------------------------------
create or replace function public.tama_wk_week()
returns date language sql stable set search_path = public as $$
  select (date_trunc('week', now() at time zone 'Asia/Tokyo'))::date
$$;

-- だめな言葉が入っているか（悪口・性的・出会い目的・連絡先・URL など）。アプリの画面にも同じ一覧がある（WK_NG）
create or replace function public.tama_wk_ng(p text)
returns boolean language sql immutable set search_path = public as $$
  select exists (
    select 1 from unnest(array[
      '死ね','殺す','ころす','消えろ','きえろ','キモい','きもい','ブス','デブ','ガイジ','がいじ','池沼','クズ',
      'セックス','せっくす','sex','エロ','ヤリモク','やりもく','セフレ','せふれ','パパ活','ぱぱ活','援交','えんこう','裏垢','うらあか',
      'ちんこ','ちんぽ','まんこ','おっぱい','フェラ','ホテル',
      '出会い','であい','彼女募集','彼氏募集','恋人募集','付き合って','つきあって',
      'line交換','ライン交換','らいん交換','インスタ交換','電話番号','住所','@','http',
      '大麻','覚醒剤','闇バイト'
    ]) w
    where position(w in lower(normalize(coalesce(p, ''), NFKC))) > 0
  )
$$;

-- ---------------------------------------------------------------------------
-- 3. 今週の様子（テーマ・選択肢・人数・部屋・自分の答え・来週の提案）
-- ---------------------------------------------------------------------------
create or replace function public.tama_wk_state()
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  w  date := public.tama_wk_week();
  r  jsonb;
begin
  if me is null then return null; end if;
  -- みんなの票がいちばん多かった提案を、今週の「みんなのテーマ」にする（月曜になって、はじめてだれかが開いた時）
  if not exists (select 1 from public.tama_wk_themes where week = w and source = 'vote' and status = 'active') then
    update public.tama_wk_themes set status = 'active'
     where id = (select t.id from public.tama_wk_themes t
                  where t.week = w and t.status = 'proposed' and exists (select 1 from public.tama_wk_votes v where v.theme_id = t.id)
                  order by (select count(*) from public.tama_wk_votes v where v.theme_id = t.id) desc, t.id
                  limit 1);
  end if;
  select jsonb_build_object(
    'week', w,
    'need', 5,
    'themes', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', t.id, 'title', t.title, 'kind', t.kind, 'source', t.source,
               'mine', (select a.opt_id from public.tama_wk_answers a where a.theme_id = t.id and a.user_id = me),
               'opts', coalesce((
                 select jsonb_agg(jsonb_build_object(
                          'id', o.id, 'label', o.label, 'own', o.created_by = me, 'user', o.created_by is not null,
                          'n', (select count(*) from public.tama_wk_answers a where a.opt_id = o.id),
                          'room', (select wr.room_id from public.tama_wk_rooms wr where wr.opt_id = o.id))
                        order by (select count(*) from public.tama_wk_answers a where a.opt_id = o.id) desc, o.id)
                   from public.tama_wk_opts o where o.theme_id = t.id and not o.hidden), '[]'::jsonb))
             order by t.source, t.id)
        from public.tama_wk_themes t where t.week = w and t.status = 'active'), '[]'::jsonb),
    'next', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', t.id, 'title', t.title, 'own', t.proposed_by = me,
               'votes', (select count(*) from public.tama_wk_votes v where v.theme_id = t.id),
               'voted', exists (select 1 from public.tama_wk_votes v where v.theme_id = t.id and v.user_id = me))
             order by (select count(*) from public.tama_wk_votes v where v.theme_id = t.id) desc, t.id)
        from public.tama_wk_themes t where t.week = w + 7 and t.status = 'proposed'), '[]'::jsonb)
  ) into r;
  return r;
end $$;

-- ---------------------------------------------------------------------------
-- 4. 答える・自分で書く・やめる・提案・票・通報
-- ---------------------------------------------------------------------------
-- 答える。同じ答えが5人そろったら、その答えの部屋を作って、答えた人を入れる。返り値 {status, room}
create or replace function public.tama_wk_answer(p_theme bigint, p_opt bigint)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  me     uuid := auth.uid();
  t      record;
  o      record;
  n      int;
  v_room text;
begin
  if me is null then raise exception 'not signed in'; end if;
  if exists (select 1 from public.tama_bans b where b.user_id = me) then return jsonb_build_object('status', 'banned'); end if;
  select * into t from public.tama_wk_themes where id = p_theme and week = public.tama_wk_week() and status = 'active';
  if not found then return jsonb_build_object('status', 'closed'); end if;
  select * into o from public.tama_wk_opts where id = p_opt and theme_id = p_theme and not hidden;
  if not found then return jsonb_build_object('status', 'noopt'); end if;
  insert into public.tama_wk_answers (theme_id, user_id, opt_id) values (p_theme, me, p_opt)
  on conflict (theme_id, user_id) do update set opt_id = excluded.opt_id, created_at = now();
  if t.kind = 'worry' then return jsonb_build_object('status', 'ok'); end if;

  perform pg_advisory_xact_lock(hashtext('tama_wk_room:' || p_opt));
  select room_id into v_room from public.tama_wk_rooms where opt_id = p_opt;
  select count(*) into n from public.tama_wk_answers where opt_id = p_opt;
  if v_room is null and n >= 5 then
    insert into public.tama_rooms (name, topic, rules, visibility, conditions, capacity, expires_at, meet, owner_id)
    values (left(o.label, 20),
            '今週のイベント「' || left(t.title, 30) || '」で、同じ答えの人の部屋（今週だけ）',
            E'・今週だけの部屋です（日曜の夜で終わります）\n・いやな言い方をしない\n・困ったことは「運営に知らせる」から',
            'invite',
            '[]'::jsonb,                                       -- 入れるのは答えた人だけ（招待の部屋なので、ほかの人の一覧には出ない）
            null,
            ((public.tama_wk_week() + 7)::timestamp at time zone 'Asia/Tokyo'),
            null, null)
    returning id::text into v_room;
    insert into public.tama_wk_rooms (opt_id, room_id) values (p_opt, v_room);
    insert into public.tama_room_members (room_id, user_id, last_read_at)
    select r.id, a.user_id, now() from public.tama_rooms r cross join public.tama_wk_answers a
     where r.id::text = v_room and a.opt_id = p_opt
       and not exists (select 1 from public.tama_bans b where b.user_id = a.user_id)
    on conflict do nothing;
    insert into public.tama_jobs (kind, payload)
    select 'push', jsonb_build_object('to', a.user_id::text, 'kind', 'room', 'tag', 'wk-' || p_opt::text,
             'title', '今週の部屋ができました', 'body', '「' || left(o.label, 20) || '」の人が5人そろいました。のぞいてみよう',
             'url', '/tama/?go=room&r=' || v_room)
      from public.tama_wk_answers a
     where a.opt_id = p_opt and a.user_id <> me and not exists (select 1 from public.tama_bans b where b.user_id = a.user_id);
  elsif v_room is not null then
    insert into public.tama_room_members (room_id, user_id, last_read_at)
    select r.id, me, now() from public.tama_rooms r where r.id::text = v_room
       and not exists (select 1 from public.tama_room_bans b where b.room_id = v_room and b.user_id = me)
    on conflict do nothing;
  end if;
  return jsonb_build_object('status', 'ok', 'room', v_room, 'n', n);
end $$;

-- 自分で書いて答える（同じ言葉の選択肢があればそれに入る）。1つのテーマに書けるのは3つまで
create or replace function public.tama_wk_add_opt(p_theme bigint, p_label text)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  me    uuid := auth.uid();
  lab   text := left(trim(coalesce(p_label, '')), 20);
  nm    text := public.tama_norm(p_label);
  v_opt bigint;
  res   jsonb;
begin
  if me is null then raise exception 'not signed in'; end if;
  if lab = '' or nm = '' then return jsonb_build_object('status', 'empty'); end if;
  if public.tama_wk_ng(lab) then return jsonb_build_object('status', 'ng'); end if;
  if not exists (select 1 from public.tama_wk_themes where id = p_theme and week = public.tama_wk_week() and status = 'active') then
    return jsonb_build_object('status', 'closed');
  end if;
  select id into v_opt from public.tama_wk_opts where theme_id = p_theme and norm = nm;
  if v_opt is null then
    if (select count(*) from public.tama_wk_opts where theme_id = p_theme and created_by = me) >= 3 then
      return jsonb_build_object('status', 'many');
    end if;
    insert into public.tama_wk_opts (theme_id, label, norm, created_by) values (p_theme, lab, nm, me) returning id into v_opt;
  end if;
  res := public.tama_wk_answer(p_theme, v_opt);
  return res || jsonb_build_object('opt', v_opt, 'label', (select label from public.tama_wk_opts where id = v_opt));
end $$;

create or replace function public.tama_wk_unanswer(p_theme bigint)
returns void language sql volatile security definer set search_path = public as $$
  delete from public.tama_wk_answers where theme_id = p_theme and user_id = auth.uid();
$$;

-- 来週のテーマを提案する（1人1週に1つ。自分の票も1つ入る）
create or replace function public.tama_wk_propose(p_title text)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  me  uuid := auth.uid();
  w   date := public.tama_wk_week() + 7;
  tit text := left(trim(coalesce(p_title, '')), 40);
  nm  text := public.tama_norm(p_title);
  v_t bigint;
begin
  if me is null then raise exception 'not signed in'; end if;
  if tit = '' or nm = '' then return jsonb_build_object('status', 'empty'); end if;
  if public.tama_wk_ng(tit) then return jsonb_build_object('status', 'ng'); end if;
  if exists (select 1 from public.tama_bans b where b.user_id = me) then return jsonb_build_object('status', 'banned'); end if;
  if exists (select 1 from public.tama_wk_themes where week = w and proposed_by = me) then return jsonb_build_object('status', 'once'); end if;
  select id into v_t from public.tama_wk_themes where week = w and status = 'proposed' and norm = nm;
  if v_t is null then
    insert into public.tama_wk_themes (week, title, norm, kind, source, status, proposed_by)
    values (w, tit, nm, 'like', 'vote', 'proposed', me) returning id into v_t;
  end if;
  insert into public.tama_wk_votes (theme_id, user_id) values (v_t, me) on conflict do nothing;
  return jsonb_build_object('status', 'ok', 'id', v_t);
end $$;

-- 来週のテーマに票を入れる・取り消す。返り値：入れた後なら true
create or replace function public.tama_wk_vote(p_theme bigint)
returns boolean language plpgsql volatile security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'not signed in'; end if;
  if not exists (select 1 from public.tama_wk_themes where id = p_theme and week = public.tama_wk_week() + 7 and status = 'proposed') then return false; end if;
  if exists (select 1 from public.tama_wk_votes where theme_id = p_theme and user_id = me) then
    delete from public.tama_wk_votes where theme_id = p_theme and user_id = me; return false;
  end if;
  insert into public.tama_wk_votes (theme_id, user_id) values (p_theme, me) on conflict do nothing;
  return true;
end $$;

-- 書かれた選択肢・提案されたテーマを通報する。2人から通報されたら隠す（運営があとで見て戻せる）
create or replace function public.tama_wk_report(p_kind text, p_id bigint)
returns void language plpgsql volatile security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  if me is null or p_kind not in ('opt', 'theme') then return; end if;
  insert into public.tama_wk_reports (kind, target_id, user_id) values (p_kind, p_id, me) on conflict do nothing;
  if (select count(*) from public.tama_wk_reports where kind = p_kind and target_id = p_id) >= 2 then
    if p_kind = 'opt' then update public.tama_wk_opts set hidden = true where id = p_id and created_by is not null;
    else update public.tama_wk_themes set status = 'hidden' where id = p_id and source = 'vote'; end if;
  end if;
end $$;

revoke all on function public.tama_wk_state(), public.tama_wk_answer(bigint, bigint), public.tama_wk_add_opt(bigint, text),
  public.tama_wk_unanswer(bigint), public.tama_wk_propose(text), public.tama_wk_vote(bigint), public.tama_wk_report(text, bigint) from public, anon;
grant execute on function public.tama_wk_state(), public.tama_wk_answer(bigint, bigint), public.tama_wk_add_opt(bigint, text),
  public.tama_wk_unanswer(bigint), public.tama_wk_propose(text), public.tama_wk_vote(bigint), public.tama_wk_report(text, bigint) to authenticated;

-- ---------------------------------------------------------------------------
-- 5. 運営のテーマ（はじめの週の分。今週の運営のテーマがまだ無い時だけ入る）
--    来週の分を入れる時は、week を「来週の月曜の日付」にして、同じ形で実行する
-- ---------------------------------------------------------------------------
with t as (
  insert into public.tama_wk_themes (week, title, norm, kind, source, status)
  select public.tama_wk_week(), '今月こそやりたいこと', public.tama_norm('今月こそやりたいこと'), 'goal', 'ops', 'active'
   where not exists (select 1 from public.tama_wk_themes where week = public.tama_wk_week() and source = 'ops')
  returning id
)
insert into public.tama_wk_opts (theme_id, label, norm)
select t.id, x, public.tama_norm(x)
  from t cross join unnest(array['英語・TOEIC','資格の勉強','筋トレ・運動','早起き','本を読む','貯金','新しいバイト','サークルをがんばる']) x
on conflict do nothing;

-- ---------------------------------------------------------------------------
-- 6. 今週の答えも、すれ違いの共通点に入れる（tama_xitems.sql の版に「今週のイベント」を足したもの）
-- ---------------------------------------------------------------------------
create or replace function public.tama_simple_common(me jsonb, other jsonb)
returns text language plpgsql stable set search_path = public as $$
declare
  off jsonb := coalesce(me->'match_off', '[]'::jsonb);
  x text;
begin
  if me is null or other is null then return null; end if;
  if not off ? 'art' and public.tama_norm(me->>'artist') <> '' and public.tama_norm(me->>'artist') = public.tama_norm(other->>'artist') then
    return 'アーティスト「' || left(other->>'artist', 30) || '」';
  end if;
  if not off ? 'crs' and coalesce(me->>'course', '') <> ''
     and lower(regexp_replace(normalize(me->>'course', NFKC), '[[:space:]　]+', '', 'g')) = lower(regexp_replace(normalize(coalesce(other->>'course', ''), NFKC), '[[:space:]　]+', '', 'g')) then
    return '授業「' || left(other->>'course', 30) || '」';
  end if;
  -- 今週のイベントで同じ答え（2026-11-07。今週の分だけ）
  if not off ? 'wk' and jsonb_typeof(me->'wk') = 'object' and jsonb_typeof(other->'wk') = 'object'
     and me->'wk'->>'w' = public.tama_wk_week()::text and other->'wk'->>'w' = me->'wk'->>'w'
     and jsonb_typeof(me->'wk'->'a') = 'array' and jsonb_typeof(other->'wk'->'a') = 'array' then
    select a->>'l' into x from jsonb_array_elements(me->'wk'->'a') a
     where coalesce(a->>'o', '') <> '' and exists (select 1 from jsonb_array_elements(other->'wk'->'a') b where b->>'o' = a->>'o') limit 1;
    if x is not null then return '今週のイベント「' || left(x, 20) || '」'; end if;
  end if;
  -- すれ違いの項目（2026-11-07）
  if not off ? 'cir' and public.tama_norm(me->>'circle') <> '' and public.tama_norm(me->>'circle') = public.tama_norm(other->>'circle') then
    return 'サークル「' || left(other->>'circle', 20) || '」';
  end if;
  if not off ? 'bus' and coalesce(me->>'bus', '') <> '' and me->>'bus' = other->>'bus' then
    return '通学の駅・バス「' || left(other->>'bus', 20) || '」';
  end if;
  if not off ? 'mbti' and coalesce(me->>'mbti', '') <> '' and me->>'mbti' = other->>'mbti' then
    return 'MBTI「' || left(other->>'mbti', 4) || '」';
  end if;
  if not off ? 'gen' and jsonb_typeof(me->'genres') = 'array' and jsonb_typeof(other->'genres') = 'array' then
    select a into x from jsonb_array_elements_text(me->'genres') a where other->'genres' ? a limit 1;
    if x is not null then return '好きなジャンル「' || left(x, 20) || '」'; end if;
  end if;
  if not off ? 'home' and coalesce(me->>'hometown', '') <> '' and me->>'hometown' = other->>'hometown' then
    return '出身「' || left(other->>'hometown', 10) || '」';
  end if;
  if not off ? 'food' and coalesce(me->>'food', '') not in ('', '学食はあまり使わない') and me->>'food' = other->>'food' then
    return '好きな学食メニュー「' || left(other->>'food', 20) || '」';
  end if;
  if not off ? 'aru' and jsonb_typeof(me->'aruaru') = 'array' and jsonb_typeof(other->'aruaru') = 'array' then
    select a into x from jsonb_array_elements_text(me->'aruaru') a where other->'aruaru' ? a limit 1;
    if x is not null then return 'あるある「' || left(x, 30) || '」'; end if;
  end if;
  if not off ? 'pur' and jsonb_typeof(me->'purposes') = 'array' and jsonb_typeof(other->'purposes') = 'array'
     and exists (select 1 from jsonb_array_elements_text(me->'purposes') a where other->'purposes' ? a) then
    return '共通点';
  end if;
  if not off ? 'goal' and jsonb_typeof(me->'goals') = 'array' and jsonb_typeof(other->'goals') = 'array'
     and exists (select 1 from jsonb_array_elements_text(me->'goals') a where other->'goals' ? a) then
    return '共通点';
  end if;
  return null;
end $$;
