// Supabase ダッシュボード → Edge Functions → 新規関数 "send-match-push" として
// このファイルの内容をそのまま貼り付けてデプロイしてください。
//
// 必要な環境変数（Edge Functions の Secrets に設定）:
//   VAPID_PUBLIC_KEY  … index.html 内の VAPID_PUBLIC_KEY と同じ値
//   VAPID_PRIVATE_KEY … PowerShellで生成した秘密鍵（絶対にクライアント側コードには書かない）
// SUPABASE_URL と SUPABASE_SERVICE_ROLE_KEY は Supabase が自動的に注入します。

import { createClient } from "npm:@supabase/supabase-js@2";
import webpush from "npm:web-push@3.6.7";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const vapidPublicKey = Deno.env.get("VAPID_PUBLIC_KEY") ?? "";
const vapidPrivateKey = Deno.env.get("VAPID_PRIVATE_KEY") ?? "";
if (vapidPublicKey && vapidPrivateKey) {
  webpush.setVapidDetails("mailto:support@example.com", vapidPublicKey, vapidPrivateKey);
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  try {
    const { to, title, body, url } = await req.json();
    if (!to) {
      return new Response(JSON.stringify({ error: "to is required" }), {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );

    const { data, error } = await supabase
      .from("push_subscriptions")
      .select("subscription")
      .eq("id", to)
      .maybeSingle();

    if (error || !data) {
      return new Response(JSON.stringify({ ok: false, reason: "no subscription" }), {
        status: 200,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const payload = JSON.stringify({
      title: title || "マッチしました！",
      body: body || "新しいマッチがあります。アプリを開いて確認しましょう。",
      url: url || "./index.html",
    });

    try {
      await webpush.sendNotification(data.subscription, payload);
      return new Response(JSON.stringify({ ok: true }), {
        status: 200,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    } catch (err) {
      // 購読が失効している場合（410 Gone など）は掃除しておく
      const statusCode = (err as { statusCode?: number })?.statusCode;
      if (statusCode === 404 || statusCode === 410) {
        await supabase.from("push_subscriptions").delete().eq("id", to);
      }
      return new Response(JSON.stringify({ ok: false, error: String(err) }), {
        status: 200,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }
  } catch (e) {
    return new Response(JSON.stringify({ error: String(e) }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
