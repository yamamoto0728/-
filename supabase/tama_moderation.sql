-- Supabase の SQL Editor でこのファイルの内容をそのまま実行してください（2026-11-07）。
-- 何度実行しても同じ結果になるように書いてあります（再実行しても壊れません）。
-- ⚠️ 先に tama_safety.sql・tama_weekly.sql を実行済みであること。
--
-- 2026-11-07 安全の総点検（S2）：使えない言葉（NGワード）を、サーバーの1つの表と1つの関数にまとめる。
--   前は、画面の NGWORDS（チャット）・WK_NG（今週のイベント）・サーバーの tama_wk_ng の3つがばらばらで、
--   画面の確かめは改造すれば通り抜けられた。いまは、人が書ける所はどこでも、サーバーが保存する前に確かめる。
--
--   ・言葉の一覧は表 tama_ng_words（運営が足せる。下の「5.」）。画面は tama_ng_list() で同じ一覧を受け取って、先に知らせるだけ
--   ・書き方をそろえてから比べる（全角・半角・大文字・カタカナ→ひらがな・空白や記号を抜く）。「し ね」「ｼﾈ」「死　ね」も同じに見る
--   ・ふつうの言葉まで止めないように、短くて紛らわしい言葉は入れない（「えろ」は「かえろう」、「くず」は「くずもち」も止めるため）
--   ・2つの範囲：
--       public … 知らない人も見る所（プロフィール・コミュニティ・知らない人へのトーク・いいねのひとこと・今週のイベント）。
--                 ひどい言葉に加えて、出会い目的の言葉・連絡先（URL・メール・電話番号・@ID・LINE交換など）も止める
--       dm     … 友達どうしのトーク・いまどこの一言。ひどい言葉だけ止める（友達どうしで連絡先を教え合うのは止めない）
--   ・止めた時はエラー「ng_word」を返す（画面は「使えない言葉が入っています」と出す）
--   ・止めるのは「書いた・変えた時」だけ。前から入っている文は確かめない（位置の更新などで、急に保存できなくなるのを防ぐ）
--
-- 回数の上限も足す：友達の申請（1日30件）・今日のお題のアイデア（1日5件）

-- ---------------------------------------------------------------------------
-- 1. 書き方をそろえる関数
-- ---------------------------------------------------------------------------
create or replace function public.tama_ng_norm(p text)
returns text language sql immutable set search_path = public as $$
  select regexp_replace(
           translate(lower(normalize(coalesce(p, ''), NFKC)),
             'ァアィイゥウェエォオカガキギクグケゲコゴサザシジスズセゼソゾタダチヂッツヅテデトドナニヌネノハバパヒビピフブプヘベペホボポマミムメモャヤュユョヨラリルレロヮワヰヱヲンヴヵヶ',
             'ぁあぃいぅうぇえぉおかがきぎくぐけげこごさざしじすずせぜそぞただちぢっつづてでとどなにぬねのはばぱひびぴふぶぷへべぺほぼぽまみむめもゃやゅゆょよらりるれろゎわゐゑをんゔゕゖ'),
           '[^a-z0-9ぁ-ゖ一-鿿々]', '', 'g')
$$;

-- ---------------------------------------------------------------------------
-- 2. 言葉の一覧（kind：block＝どこでも止める／public＝知らない人も見る所だけ止める）
-- ---------------------------------------------------------------------------
create table if not exists public.tama_ng_words (
  word       text primary key check (char_length(word) between 2 and 40),
  kind       text not null default 'block' check (kind in ('block', 'public')),
  note       text,
  created_at timestamptz not null default now()
);
alter table public.tama_ng_words enable row level security;
revoke all on public.tama_ng_words from anon, authenticated;

insert into public.tama_ng_words (word, kind, note) values
  -- 暴言・おどし
  ('死ね', 'block', '暴言'), ('氏ね', 'block', '暴言'), ('しねよ', 'block', '暴言'), ('しんでしまえ', 'block', '暴言'),
  ('殺す', 'block', '暴言'), ('ころすぞ', 'block', '暴言'), ('ころしてやる', 'block', '暴言'), ('殺害', 'block', '暴言'),
  ('消えろ', 'block', '暴言'), ('きえろ', 'block', '暴言'), ('うざすぎて死', 'block', '暴言'), ('きもすぎて無理', 'block', '暴言'),
  ('きしょい', 'block', '暴言'), ('ぶさいく', 'block', '暴言'), ('不細工', 'block', '暴言'), 
  ('デブ', 'block', '暴言'), ('低能', 'block', '暴言'), ('無能', 'block', '暴言'), ('人間のくず', 'block', '暴言'),
  ('くずやろう', 'block', '暴言'), ('クズ野郎', 'block', '暴言'), ('ゴミ人間', 'block', '暴言'), ('ガイジ', 'block', '差別'),
  ('きちがい', 'block', '差別'), ('キチガイ', 'block', '差別'), ('基地外', 'block', '差別'), ('池沼', 'block', '差別'), ('土人', 'block', '差別'),
  -- 性的
  ('セックス', 'block', '性的'), ('sexしよ', 'block', '性的'), ('セフレ', 'block', '性的'), ('エッチしよ', 'block', '性的'),
  ('ヤリモク', 'block', '性的'), ('童貞', 'block', '性的'), ('中出し', 'block', '性的'), ('全裸', 'block', '性的'),
  ('パンツ見せ', 'block', '性的'), ('ちんこ', 'block', '性的'), ('ちんぽ', 'block', '性的'), ('まんこ', 'block', '性的'),
  ('おっぱい', 'block', '性的'), ('巨乳', 'block', '性的'), ('風俗', 'block', '性的'), ('エロい', 'block', '性的'),
  ('エロ画像', 'block', '性的'), ('エロ動画', 'block', '性的'), ('勃起', 'block', '性的'), ('フェラして', 'block', '性的'),
  ('裏垢', 'block', '性的'), ('ホテル行', 'block', '性的'), ('ラブホ', 'block', '性的'),
  -- お金・勧誘・危ない物
  ('援交', 'block', '売買春'), ('援助交際', 'block', '売買春'), ('パパ活', 'block', '売買春'), ('ママ活', 'block', '売買春'),
  ('副業紹介', 'block', '勧誘'), ('バイナリーオプション', 'block', '勧誘'), ('ネットワークビジネス', 'block', '勧誘'),
  ('マルチ商法', 'block', '勧誘'), ('宗教の勧誘', 'block', '勧誘'), ('闇バイト', 'block', '犯罪'), ('大麻', 'block', '薬物'),
  ('覚醒剤', 'block', '薬物'), ('お酒飲ませ', 'block', '危険'),
  -- 出会い目的（知らない人も見る所だけ）
  ('出会い目的', 'public', '出会い目的'), ('出会い系', 'public', '出会い目的'), ('彼女募集', 'public', '出会い目的'),
  ('彼氏募集', 'public', '出会い目的'), ('恋人募集', 'public', '出会い目的'), ('恋人探し', 'public', '出会い目的'),
  ('付き合ってください', 'public', '出会い目的'), ('ワンナイト', 'public', '出会い目的'),
  -- 連絡先で外に連れ出す（知らない人も見る所だけ）
  ('LINE交換', 'public', '連絡先'), ('ライン交換', 'public', '連絡先'), ('LINEID', 'public', '連絡先'), ('ラインID', 'public', '連絡先'),
  ('LINE教え', 'public', '連絡先'), ('インスタ交換', 'public', '連絡先'), ('インスタ教え', 'public', '連絡先'),
  ('DMください', 'public', '連絡先'), ('電話番号教え', 'public', '連絡先'), ('住所教え', 'public', '連絡先'), ('本名教え', 'public', '連絡先'),
  ('カカオ交換', 'public', '連絡先'), ('ID教え', 'public', '連絡先')
on conflict (word) do nothing;

-- ---------------------------------------------------------------------------
-- 3. 確かめる関数。当たったら、その種類（暴言・連絡先など）を返す。当たらなければ null
-- ---------------------------------------------------------------------------
create or replace function public.tama_ng_hit(p text, p_scope text default 'public')
returns text language plpgsql stable security definer set search_path = public as $$
declare
  n   text;
  raw text;
  hit text;
begin
  if p is null or btrim(p) = '' then return null; end if;
  n := public.tama_ng_norm(p);
  select coalesce(w.note, w.kind) into hit from public.tama_ng_words w
   where (w.kind = 'block' or p_scope = 'public')
     and public.tama_ng_norm(w.word) <> '' and position(public.tama_ng_norm(w.word) in n) > 0
   limit 1;
  if hit is not null then return hit; end if;
  if p_scope = 'public' then
    raw := regexp_replace(lower(normalize(p, NFKC)), '[[:space:]　]+', '', 'g');
    if raw ~ '(https?:|www\.|[a-z0-9-]+\.(com|jp|net|org|me|io|ly|link|xyz|info|co)([^a-z]|$))' then return 'URL'; end if;
    if raw ~ '[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}' then return 'メールアドレス'; end if;
    if regexp_replace(raw, '[-()（）ー‐]', '', 'g') ~ '(^|[^0-9])0[0-9]{9,10}([^0-9]|$)' then return '電話番号'; end if;
    if raw ~ '@[a-z0-9_.]{3,}' then return 'SNSのID'; end if;
  end if;
  return null;
end $$;
revoke all on function public.tama_ng_hit(text, text) from public, anon;
grant execute on function public.tama_ng_hit(text, text) to authenticated, service_role;

-- 画面用の一覧（書き方をそろえた言葉と種類。画面はこれで先に知らせるだけで、決めるのはサーバー）
create or replace function public.tama_ng_list()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('w', public.tama_ng_norm(word), 'k', kind)), '[]'::jsonb)
    from public.tama_ng_words where public.tama_ng_norm(word) <> ''
$$;
revoke all on function public.tama_ng_list() from public, anon;
grant execute on function public.tama_ng_list() to authenticated;

-- 止める時のエラー（画面は message の ng_word を見る）
create or replace function public.tama_ng_raise(p text, p_scope text, p_where text)
returns void language plpgsql stable set search_path = public as $$
declare h text := public.tama_ng_hit(p, p_scope);
begin
  if h is not null then
    raise exception 'ng_word' using errcode = 'P0001', detail = p_where, hint = '使えない言葉が入っています（' || h || '）';
  end if;
end $$;
revoke all on function public.tama_ng_raise(text, text, text) from public, anon, authenticated;

-- 今週のイベントの確かめも、この一覧に合わせる（tama_weekly.sql の tama_wk_ng を置きかえる）
create or replace function public.tama_wk_ng(p text)
returns boolean language sql stable security definer set search_path = public as $$
  select public.tama_ng_hit(p, 'public') is not null
$$;
revoke all on function public.tama_wk_ng(text) from public, anon;
grant execute on function public.tama_wk_ng(text) to authenticated;

-- ---------------------------------------------------------------------------
-- 4. 書く所ごとの確かめ（トリガー。書いた・変えた時だけ）
-- ---------------------------------------------------------------------------
-- プロフィール：名前・自己紹介・自由に書ける項目（アーティスト・授業・すれ違いのひとこと・サークル・探していること・今日の答え・いまの一言）
create or replace function public.tama_ng_profiles()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  k text;
  o jsonb := case when tg_op = 'UPDATE' then coalesce(old.fes_attrs, '{}'::jsonb) else '{}'::jsonb end;
  f jsonb := coalesce(new.fes_attrs, '{}'::jsonb);
begin
  -- upsert（あれば上書き）の時は、先に INSERT のトリガーが動く。もう行がある人は、あとの UPDATE の方で「変えた所」だけ確かめる
  if tg_op = 'INSERT' and exists (select 1 from public.tama_profiles x where x.id::text = new.id::text) then return new; end if;
  if tg_op = 'INSERT' or new.name is distinct from old.name then perform public.tama_ng_raise(new.name, 'public', 'name'); end if;
  if tg_op = 'INSERT' or new.bio is distinct from old.bio then perform public.tama_ng_raise(new.bio, 'public', 'bio'); end if;
  foreach k in array array['artist', 'course', 'xmsg', 'circle', 'seek'] loop
    if (f->>k) is distinct from (o->>k) then perform public.tama_ng_raise(f->>k, 'public', k); end if;
  end loop;
  if (f->'want'->>'t') is distinct from (o->'want'->>'t') then perform public.tama_ng_raise(f->'want'->>'t', 'public', 'want'); end if;
  if (f->'daily'->>'a') is distinct from (o->'daily'->>'a') then perform public.tama_ng_raise(f->'daily'->>'a', 'public', 'daily'); end if;
  return new;
end $$;

-- いいね（知らない人へのひとこと）
create or replace function public.tama_ng_likes()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' and exists (select 1 from public.tama_likes x where x.from_id::text = new.from_id::text and x.to_id::text = new.to_id::text) then return new; end if;
  if tg_op = 'INSERT' or new.reason is distinct from old.reason then perform public.tama_ng_raise(new.reason, 'public', 'like'); end if;
  return new;
end $$;

-- 1対1のトーク：友達どうしは dm（ひどい言葉だけ）、まだ友達でない人（いいねし合っただけ）には public
create or replace function public.tama_ng_messages()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  a text := split_part(new.match_key, '__', 1);
  b text := split_part(new.match_key, '__', 2);
  fr boolean;
begin
  select exists (select 1 from public.tama_friends f where f.status = 'accepted'
                  and ((f.from_id::text = a and f.to_id::text = b) or (f.from_id::text = b and f.to_id::text = a))) into fr;
  perform public.tama_ng_raise(new.text, case when fr then 'dm' else 'public' end, 'message');
  return new;
end $$;

-- コミュニティの投稿
create or replace function public.tama_ng_room_messages()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform public.tama_ng_raise(new.text, 'public', 'room_message');
  return new;
end $$;

-- コミュニティの名前・ひとこと・ルール・お知らせ・集まる約束
create or replace function public.tama_ng_rooms()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' or new.name  is distinct from old.name  then perform public.tama_ng_raise(new.name,  'public', 'room_name'); end if;
  if tg_op = 'INSERT' or new.topic is distinct from old.topic then perform public.tama_ng_raise(new.topic, 'public', 'room_topic'); end if;
  if tg_op = 'INSERT' or new.rules is distinct from old.rules then perform public.tama_ng_raise(new.rules, 'public', 'room_rules'); end if;
  if tg_op = 'INSERT' or new.notice is distinct from old.notice then perform public.tama_ng_raise(new.notice, 'public', 'room_notice'); end if;
  if tg_op = 'INSERT' or new.meet is distinct from old.meet then
    perform public.tama_ng_raise(coalesce(new.meet->>'place', '') || ' ' || coalesce(new.meet->>'note', ''), 'public', 'room_meet');
  end if;
  return new;
end $$;

-- いまどこの一言（友達にだけ見える）
create or replace function public.tama_ng_presence()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' and exists (select 1 from public.tama_presence x where x.id::text = new.id::text) then return new; end if;
  if tg_op = 'INSERT' or new.note is distinct from old.note then perform public.tama_ng_raise(new.note, 'dm', 'presence'); end if;
  return new;
end $$;

revoke all on function public.tama_ng_profiles(), public.tama_ng_likes(), public.tama_ng_messages(),
  public.tama_ng_room_messages(), public.tama_ng_rooms(), public.tama_ng_presence() from public, anon, authenticated;

-- トリガーを付ける（表や列が無い時は飛ばす）
do $$
declare
  t record;
begin
  for t in select * from (values
      ('tama_profiles',      'tama_ng_profiles',      'insert or update', 'name'),
      ('tama_likes',         'tama_ng_likes',         'insert or update', 'reason'),
      ('tama_messages',      'tama_ng_messages',      'insert',           'text'),
      ('tama_room_messages', 'tama_ng_room_messages', 'insert',           'text'),
      ('tama_rooms',         'tama_ng_rooms',         'insert or update', 'notice'),
      ('tama_presence',      'tama_ng_presence',      'insert or update', 'note')
    ) as x(tbl, fn, ev, col) loop
    if to_regclass('public.' || t.tbl) is not null
       and exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = t.tbl and column_name = t.col) then
      execute format('drop trigger if exists tama_ng on public.%I', t.tbl);
      execute format('create trigger tama_ng before %s on public.%I for each row execute function public.%I()', t.ev, t.tbl, t.fn);
    else
      raise notice '% が無いので、NGワードの確かめを付けませんでした', t.tbl;
    end if;
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- 5. 回数の上限（足りなかった所）
-- ---------------------------------------------------------------------------
create or replace function public.tama_rate_guard2()
returns trigger language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if tg_table_name = 'tama_friends' then
    select count(*) into n from public.tama_friends x where x.from_id = new.from_id and x.created_at > now() - interval '1 day';
    if n >= 30 then raise exception 'too_many' using hint = '友達の申請は1日30件まで'; end if;
  elsif tg_table_name = 'tama_daily_ideas' then
    select count(*) into n from public.tama_daily_ideas x where x.user_id = new.user_id and x.created_at > now() - interval '1 day';
    if n >= 5 then raise exception 'too_many' using hint = 'お題のアイデアは1日5件まで'; end if;
  end if;
  return new;
end $$;
revoke all on function public.tama_rate_guard2() from public, anon, authenticated;
do $$
declare t text;
begin
  foreach t in array array['tama_friends', 'tama_daily_ideas'] loop
    if to_regclass('public.' || t) is not null
       and exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = t and column_name = 'created_at') then
      execute format('drop trigger if exists tama_rate_guard2 on public.%I', t);
      execute format('create trigger tama_rate_guard2 before insert on public.%I for each row execute function public.tama_rate_guard2()', t);
    end if;
  end loop;
end $$;

notify pgrst, 'reload schema';

-- 参考：前から入っているプロフィールで、いまの決まりに当たるもの（止めはしない。運営が見て、本人に直してもらう）
-- SQL Editor には最後の表しか出ないので、これを見たい時は、この select だけを選んで実行する
select left(id::text, 8) as 参加者番号, name, left(coalesce(bio, ''), 60) as 自己紹介,
       coalesce(public.tama_ng_hit(name, 'public'), public.tama_ng_hit(bio, 'public'), public.tama_ng_hit(fes_attrs->>'xmsg', 'public')) as 当たったもの
  from public.tama_profiles
 where coalesce(public.tama_ng_hit(name, 'public'), public.tama_ng_hit(bio, 'public'), public.tama_ng_hit(fes_attrs->>'xmsg', 'public')) is not null
 limit 50;

-- ---------------------------------------------------------------------------
-- 確認（全部 true・null なら OK）
-- ---------------------------------------------------------------------------
select
  public.tama_ng_hit('し　ね よ', 'dm') is not null            as "「し ね よ」を止める",
  public.tama_ng_hit('ｼﾈﾖ', 'dm') is not null                  as "半角の「ｼﾈﾖ」を止める",
  public.tama_ng_hit('今日かえろう', 'public') is null          as "「かえろう」は止めない",
  public.tama_ng_hit('くずもち食べたい', 'public') is null      as "「くずもち」は止めない",
  public.tama_ng_hit('シネマ行こう', 'public') is null          as "「シネマ」は止めない",
  public.tama_ng_hit('090-1234-5678', 'public') is not null     as "電話番号を止める",
  public.tama_ng_hit('090-1234-5678', 'dm') is null             as "友達には電話番号を送れる",
  public.tama_ng_hit('insta @chikaku_tama', 'public') is not null as "@IDを止める",
  public.tama_ng_hit('彼女募集中です', 'public') is not null    as "出会い目的を止める",
  (select count(*) from pg_trigger where tgname = 'tama_ng')     as "NGワードのトリガーの数（6なら全部）";
