// Supabase ダッシュボード → Edge Functions → 新規関数 "send-match-push" として
// このファイルの内容をそのまま貼り付けてデプロイしてください。
//
// 必要な環境変数（Edge Functions の Secrets に設定）:
//   VAPID_PUBLIC_KEY  … index.html 内の VAPID_PUBLIC_KEY と同じ値
//   VAPID_PRIVATE_KEY … PowerShellで生成した秘密鍵（絶対にクライアント側コードには書かない）
// SUPABASE_URL と SUPABASE_SERVICE_ROLE_KEY は Supabase が自動的に注入します。
//
// 受け取るもの: { to, title, body, url, kind?, tag?, badge? }
//   to・title・body・url だけの呼び方（通常版・学園祭版）は前と同じように動く。
//   kind・tag・badge は多摩キャン版から（2026-10-10、supabase/tama_notify.sql と一緒に）:
//     kind  … 通知の種類（msg・like・friend・nearby・room・test など）。本人がその種類をオフにしていたら送らない。送った記録を tama_push_events に書く
//     tag   … 同じ tag の通知は、前の通知を置きかえる（別の人からのメッセージが消し合わないように、相手ごとに変える）
//     badge … true ならアプリのアイコンの数字を1つ増やす（sw.js）
// 送り先は push_subscriptions（1人1行）と tama_push_devices（端末ごと）の両方。同じ送り先には1回だけ送る。
// 送り先が無効（404・410）なら両方から消す。

import { createClient } from "npm:@supabase/supabase-js@2";
import webpush from "npm:web-push@3.6.7";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};
const reply = (obj: unknown, status = 200) =>
  new Response(JSON.stringify(obj), { status, headers: { ...corsHeaders, "Content-Type": "application/json" } });

const vapidPublicKey = Deno.env.get("VAPID_PUBLIC_KEY") ?? "";
const vapidPrivateKey = Deno.env.get("VAPID_PRIVATE_KEY") ?? "";
const vapidReady = Boolean(vapidPublicKey && vapidPrivateKey);
if (vapidReady) {
  webpush.setVapidDetails("mailto:support@example.com", vapidPublicKey, vapidPrivateKey);
  console.log("[send-match-push] VAPID configured, public key starts with:", vapidPublicKey.slice(0, 8));
} else {
  console.error("[send-match-push] VAPID_PUBLIC_KEY / VAPID_PRIVATE_KEY が Secrets に設定されていません");
}

// 通知を押した時に開く場所は、このサイトの中だけ（よそのページに飛ばされないように。sw.js でも確かめる）
const safeUrl = (u: unknown) => (typeof u === "string" && u.startsWith("/") && !u.startsWith("//") ? u : "./index.html");

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  try {
    if (!vapidReady) {
      console.error("[send-match-push] VAPID未設定のため送信を中止");
      return reply({ ok: false, reason: "vapid not configured" });
    }

    const { to, title, body, url, kind, tag, badge } = await req.json();
    console.log("[send-match-push] request received, to:", to, "kind:", kind ?? "-");
    if (!to) return reply({ error: "to is required" }, 400);
    const k = typeof kind === "string" && /^[a-z]{1,16}$/.test(kind) ? kind : "";

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );
    // 記録（テーブルが無い時＝SQL の実行前は何もしない）
    const log = async (ev: string) => {
      if (!k) return;
      const { error } = await supabase.from("tama_push_events").insert({ user_id: to, kind: k, ev });
      if (error) console.log("[send-match-push] 記録できません（tama_notify.sql の実行前?）:", error.message);
    };

    // 本人がこの種類の通知をオフにしているか（多摩キャン版のマイページ → 通知の種類。テスト通知は止めない）
    if (k && k !== "test") {
      const { data: pf } = await supabase.from("tama_profiles").select("off:fes_attrs->push_off").eq("id", to).maybeSingle();
      if (pf && Array.isArray(pf.off) && pf.off.includes(k)) {
        console.log("[send-match-push] この種類はオフ (to:", to, "kind:", k, ")");
        await log("off");
        return reply({ ok: false, reason: "off" });
      }
    }

    // 送り先を集める
    const subs = new Map<string, webpush.PushSubscription>();
    const { data, error } = await supabase.from("push_subscriptions").select("subscription").eq("id", to).maybeSingle();
    if (error) console.error("[send-match-push] push_subscriptions取得エラー:", error.message);
    if (data?.subscription?.endpoint) subs.set(data.subscription.endpoint, data.subscription);
    const { data: devs, error: dErr } = await supabase.from("tama_push_devices").select("endpoint,subscription").eq("user_id", to);
    if (!dErr) for (const d of devs ?? []) if (d.subscription?.endpoint) subs.set(d.endpoint, d.subscription);

    if (subs.size === 0) {
      console.log("[send-match-push] 購読情報なし (to:", to, ") — このユーザーは通知を有効化していない");
      await log("fail");
      return reply({ ok: false, reason: "no subscription", devices: 0, sent: 0 });
    }

    const payload = JSON.stringify({
      title: title || "マッチしました！",
      body: body || "新しいマッチがあります。アプリを開いて確認しましょう。",
      url: safeUrl(url),
      ...(typeof tag === "string" && tag ? { tag: tag.slice(0, 64) } : {}),
      ...(badge ? { badge: true } : {}),
    });

    let sent = 0;
    const errors: string[] = [];
    await Promise.all([...subs.entries()].map(async ([endpoint, sub]) => {
      try {
        await webpush.sendNotification(sub, payload);
        sent++;
      } catch (err) {
        // 送り先が無効な場合（410 Gone など）は両方から消す。アプリは次に開いた時に作り直す（index.html の syncPushSubscription）
        const statusCode = (err as { statusCode?: number })?.statusCode;
        console.error("[send-match-push] 送信失敗 (to:", to, ") statusCode:", statusCode, "送り先:", endpoint.split("/")[2], "message:", String(err));
        errors.push(String(statusCode ?? err));
        if (statusCode === 404 || statusCode === 410) {
          await supabase.from("push_subscriptions").delete().eq("id", to).eq("subscription->>endpoint", endpoint);
          await supabase.from("tama_push_devices").delete().eq("endpoint", endpoint);
        }
      }
    }));

    console.log("[send-match-push] 送信", sent, "/", subs.size, "(to:", to, ")");
    await log(sent ? "sent" : "fail");
    return reply(sent ? { ok: true, sent, devices: subs.size } : { ok: false, sent, devices: subs.size, error: errors.join(",") });
  } catch (e) {
    console.error("[send-match-push] 想定外エラー:", String(e));
    return reply({ error: String(e) }, 500);
  }
});
