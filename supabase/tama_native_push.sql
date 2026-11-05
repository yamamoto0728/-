-- Supabase の SQL Editor でこのファイルの内容をそのまま実行してください（2026-11-05）。何度実行しても壊れません。
--
-- あおの依頼「まだ入れてないものは入れて」（2026-11-05）：アプリの通知（要件定義書 v0.1 の目的②「通知を確実に届ける」）。
-- 包んだアプリの通知は、ブラウザの通知（Web Push）とは別の道を通る：
--   Android … Firebase Cloud Messaging（FCM）の端末の番号
--   iPhone  … Apple の通知サーバー（APNs）の端末の番号
-- どちらも、今の送り先の表 tama_push_devices に「fcm:番号」「apns:番号」の形で入れる（送るのは send-match-push）。

create or replace function public.tama_push_register_native(p_platform text, p_token text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if p_platform not in ('fcm', 'apns') then raise exception 'bad platform'; end if;
  if p_token is null or length(p_token) < 20 or length(p_token) > 4096 or p_token !~ '^[A-Za-z0-9:_\-]+$' then raise exception 'bad token'; end if;
  insert into public.tama_push_devices (endpoint, user_id, subscription, updated_at)
  values (p_platform || ':' || p_token, auth.uid(), jsonb_build_object('type', p_platform, 'token', p_token, 'endpoint', p_platform || ':' || p_token), now())
  on conflict (endpoint) do update set user_id = excluded.user_id, subscription = excluded.subscription, updated_at = now();
end $$;
revoke all on function public.tama_push_register_native(text, text) from public, anon;
grant execute on function public.tama_push_register_native(text, text) to authenticated;

notify pgrst, 'reload schema';

select 'tama_push_register_native があるか' as 項目, (to_regprocedure('public.tama_push_register_native(text,text)') is not null)::text as 結果;
