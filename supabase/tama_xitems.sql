-- Supabase の SQL Editor でこのファイルの内容をそのまま実行してください（2026-11-07）。
-- ⚠️ 先に supabase/tama_bg_cross.sql を実行済みであること（tama_norm・tama_simple_common がある）。
-- 何度実行しても同じ結果になるように書いてあります（再実行しても壊れません）。
--
-- 2026-11-07 あおの依頼「すれ違いを強みに。もっと面白い項目を、あとでプロフィールから足せるように」：
--   プロフィールの「すれ違いの項目」（駅・バス／出身地／好きな学食メニュー／好きなジャンル／MBTI／サークル）を、サーバーの共通点にも入れる。
--   使う所：①閉じている間にすれ違った時の通知の文 ②すれ違いの設定が「共通点がある人だけ」の人の判定（アプリの中と同じ決まりにする）
--   「学食はあまり使わない」はだれとでも一致してしまうので数えない（アプリの中と同じ）

create or replace function public.tama_simple_common(me jsonb, other jsonb)
returns text language plpgsql immutable set search_path = public as $$
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
  -- ここから、すれ違いの項目（2026-11-07）
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
  -- ここまで
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
