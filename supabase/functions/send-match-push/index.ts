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
// 2026-11-05 安全の見直し：呼んだ人（ログイン必須）と送り先の間に、その種類を送る理由があるかを確かめる。
//   msg＝5分以内にその人とのトークに書いた／like＝その人にいいねした／friend＝友達か申請がある／nearby＝tama_push_claim で記録した／
//   room＝同じコミュニティに入っている／test＝自分あて。kind が無い・ほかの種類は断る（学園祭版を使う時は kind を付ける）。
//   10分あたり、呼んだ人ごとに60通・同じ相手に20通まで。止められた人・相手にブロックされている人からは送らない。
//   ⚠️ supabase/tama_safety.sql を実行してからデプロイする（実行前は「近くの人」の通知が断られる）
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

// ---- 📱 アプリの通知（2026-11-05。supabase/tama_native_push.sql） ----
// tama_push_devices の subscription が {type:'fcm'|'apns', token} の行は、ブラウザの通知ではなく、それぞれの通知サーバーに送る。
// Secrets（入れるまでは、その端末には送らない）：
//   Android … FCM_SERVICE_ACCOUNT（Firebase → プロジェクトの設定 → サービス アカウント → 新しい秘密鍵 の JSON をそのまま）
//   iPhone  … APNS_KEY（.p8 の中身）・APNS_KEY_ID・APNS_TEAM_ID・APNS_TOPIC（jp.chikaku.tama）・APNS_PROD（TestFlight・ストアは 1、Xcode から入れた版は空）
const b64u = (b: ArrayBuffer | Uint8Array | string) => {
  const s = typeof b === "string" ? b : String.fromCharCode(...new Uint8Array(b instanceof Uint8Array ? b : new Uint8Array(b)));
  return btoa(typeof b === "string" ? unescape(encodeURIComponent(s)) : s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
};
const pemBytes = (pem: string) => Uint8Array.from(atob(pem.replace(/-----[^-]+-----/g, "").replace(/\s+/g, "")), (c) => c.charCodeAt(0));
async function signJwt(header: Record<string, unknown>, claims: Record<string, unknown>, pem: string, alg: "RS256" | "ES256") {
  const key = await crypto.subtle.importKey("pkcs8", pemBytes(pem),
    alg === "RS256" ? { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" } : { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const data = `${b64u(JSON.stringify(header))}.${b64u(JSON.stringify(claims))}`;
  const sig = await crypto.subtle.sign(alg === "RS256" ? { name: "RSASSA-PKCS1-v1_5" } : { name: "ECDSA", hash: "SHA-256" }, key, new TextEncoder().encode(data));
  return `${data}.${b64u(sig)}`;
}
let fcmTok: { t: string; exp: number } | null = null;
async function fcmAccess(sa: { client_email: string; private_key: string; token_uri?: string }) {
  if (fcmTok && fcmTok.exp > Date.now() + 60000) return fcmTok.t;
  const now = Math.floor(Date.now() / 1000), aud = sa.token_uri || "https://oauth2.googleapis.com/token";
  const jwt = await signJwt({ alg: "RS256", typ: "JWT" }, { iss: sa.client_email, scope: "https://www.googleapis.com/auth/firebase.messaging", aud, iat: now, exp: now + 3600 }, sa.private_key, "RS256");
  const r = await fetch(aud, { method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded" }, body: `grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion=${jwt}` });
  const j = await r.json();
  if (!j.access_token) throw new Error("FCM の鍵を受け取れません: " + JSON.stringify(j).slice(0, 120));
  fcmTok = { t: j.access_token, exp: Date.now() + (j.expires_in ?? 3600) * 1000 };
  return fcmTok.t;
}
let apnsJwt: { t: string; at: number } | null = null;
// 返り値：'sent' | 'gone'（端末の番号が無効。表から消す）| 'off'（Secrets が無い）| 'fail'
async function sendNative(type: string, token: string, msg: { title: string; body: string; url: string; tag?: string }): Promise<string> {
  try {
    if (type === "fcm") {
      const raw = Deno.env.get("FCM_SERVICE_ACCOUNT"); if (!raw) return "off";
      const sa = JSON.parse(raw);
      const r = await fetch(`https://fcm.googleapis.com/v1/projects/${sa.project_id}/messages:send`, {
        method: "POST", headers: { "Authorization": `Bearer ${await fcmAccess(sa)}`, "Content-Type": "application/json" },
        body: JSON.stringify({ message: { token, notification: { title: msg.title, body: msg.body }, data: { url: msg.url },
          android: { notification: { ...(msg.tag ? { tag: msg.tag } : {}) } } } }),
      });
      if (r.ok) return "sent";
      const t = await r.text();
      if (r.status === 404 || /UNREGISTERED|INVALID_ARGUMENT.*token/i.test(t)) return "gone";
      console.error("[send-match-push] FCM", r.status, t.slice(0, 160)); return "fail";
    }
    if (type === "apns") {
      const key = Deno.env.get("APNS_KEY"), kid = Deno.env.get("APNS_KEY_ID"), team = Deno.env.get("APNS_TEAM_ID"), topic = Deno.env.get("APNS_TOPIC") || "jp.chikaku.tama";
      if (!key || !kid || !team) return "off";
      // Apple の決まり：通知の鍵（JWT）は20分〜1時間ごとに作り直す
      if (!apnsJwt || Date.now() - apnsJwt.at > 40 * 60000) apnsJwt = { t: await signJwt({ alg: "ES256", kid }, { iss: team, iat: Math.floor(Date.now() / 1000) }, key, "ES256"), at: Date.now() };
      const host = Deno.env.get("APNS_PROD") === "1" ? "api.push.apple.com" : "api.sandbox.push.apple.com";
      const r = await fetch(`https://${host}/3/device/${token}`, {
        method: "POST", headers: { "authorization": `bearer ${apnsJwt.t}`, "apns-topic": topic, "apns-push-type": "alert", "apns-priority": "10", "Content-Type": "application/json" },
        body: JSON.stringify({ aps: { alert: { title: msg.title, body: msg.body }, sound: "default", ...(msg.tag ? { "thread-id": msg.tag } : {}) }, url: msg.url }),
      });
      if (r.ok) return "sent";
      const t = await r.text();
      if (r.status === 410 || /BadDeviceToken|Unregistered|DeviceTokenNotForTopic/.test(t)) return "gone";
      console.error("[send-match-push] APNs", r.status, t.slice(0, 160)); return "fail";
    }
  } catch (e) { console.error("[send-match-push] アプリの通知", type, String(e).slice(0, 160)); }
  return "fail";
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  try {

    const { to, title: rawTitle, body: rawBody, url, kind, tag, badge } = await req.json();
    console.log("[send-match-push] request received, to:", to, "kind:", kind ?? "-");
    if (!to || typeof to !== "string" || !/^[0-9a-f-]{36}$/i.test(to)) return reply({ error: "to is required" }, 400);
    const k = typeof kind === "string" && /^[a-z]{1,16}$/.test(kind) ? kind : "";
    // 長すぎる文は切る（通知の画面に入る長さ）
    const title = typeof rawTitle === "string" ? rawTitle.slice(0, 60) : "";
    const body = typeof rawBody === "string" ? rawBody.slice(0, 200) : "";

    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const supabase = createClient(Deno.env.get("SUPABASE_URL")!, serviceKey);

    // ---- だれが送らせているか（2026-11-05 安全の見直し） ----
    // 前は、ログインした人ならだれでも、だれにでも、好きな文で通知を送れた。
    // いまは「呼んだ人」と「送り先」の間に、その種類の通知を送る理由（トークを送った・いいねした・友達・同じコミュニティ など）が
    // あるかをここで確かめ、10分あたりの回数にも上限をつける。サーバーの中の呼び出し（強い鍵）は確かめない
    const jwt = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
    const internal = !!jwt && jwt === serviceKey;
    let sender: string | null = null;
    if (!internal) {
      const { data: got } = await supabase.auth.getUser(jwt);
      sender = got?.user?.id ?? null;
      if (!sender) return reply({ ok: false, reason: "not signed in" }, 401);
      const deny = async (why: string) => { console.log("[send-match-push] 送らない:", why, "(from:", sender!.slice(0, 8), "to:", to.slice(0, 8), "kind:", k || "-", ")"); return reply({ ok: false, reason: why }); };
      const one = async (q: PromiseLike<{ data: unknown[] | null; error: unknown }>) => { const { data, error } = await q; return !error && Array.isArray(data) && data.length > 0; };
      const since = (min: number) => new Date(Date.now() - min * 60000).toISOString();
      if (await one(supabase.from("tama_bans").select("user_id").eq("user_id", sender).limit(1))) return deny("banned");
      if (await one(supabase.from("tama_blocks").select("blocker_id").eq("blocker_id", to).eq("blocked_id", sender).limit(1))) return deny("blocked");
      // その種類を送る理由があるか
      let why = false;
      if (k === "test") why = to === sender;
      else if (to === sender) why = false;
      else if (k === "msg") why = await one(supabase.from("tama_messages").select("id").eq("from_id", sender).in("match_key", [[sender, to].sort().join("__")]).gt("created_at", since(5)).limit(1));
      else if (k === "like") why = await one(supabase.from("tama_likes").select("to_id").eq("from_id", sender).eq("to_id", to).limit(1));
      else if (k === "friend") why = await one(supabase.from("tama_friends").select("id").or(`and(from_id.eq.${sender},to_id.eq.${to}),and(from_id.eq.${to},to_id.eq.${sender})`).limit(1));
      else if (k === "nearby") why = await one(supabase.from("tama_push_log").select("id").eq("sender_id", sender).eq("recipient_id", to).gt("created_at", since(5)).limit(1));
      else if (k === "room") {
        const { data: mine } = await supabase.from("tama_room_members").select("room_id").eq("user_id", sender).limit(200);
        const ids = (mine ?? []).map((r) => r.room_id);
        why = ids.length > 0 && await one(supabase.from("tama_room_members").select("room_id").eq("user_id", to).in("room_id", ids).limit(1));
      }
      if (!why) return deny("no relation");
      // 通知の文も、使えない言葉を確かめる（2026-11-07 安全の総点検。トークに書けない文を、通知の文にして送れないように）。
      // 関数 tama_ng_hit（supabase/tama_moderation.sql）がまだ無い時は確かめない
      if (k !== "test") {
        const { data: ng, error: ngErr } = await supabase.rpc("tama_ng_hit", { p: `${title} ${body}`, p_scope: k === "msg" || k === "friend" ? "dm" : "public" });
        if (!ngErr && ng) return deny("ng_word");
      }
      // 回数の上限：呼んだ人ごとに10分で60通・同じ相手には10分で20通
      const { count: nAll } = await supabase.from("tama_push_events").select("id", { count: "exact", head: true }).eq("sender_id", sender).gt("created_at", since(10));
      if ((nAll ?? 0) >= 60) return deny("too many");
      const { count: nPair } = await supabase.from("tama_push_events").select("id", { count: "exact", head: true }).eq("sender_id", sender).eq("user_id", to).gt("created_at", since(10));
      if ((nPair ?? 0) >= 20) return deny("too many to one");
    }

    // 記録（テーブルが無い時＝SQL の実行前は何もしない）
    const log = async (ev: string) => {
      if (!k) return;
      let { error } = await supabase.from("tama_push_events").insert({ user_id: to, kind: k, ev, sender_id: sender });
      if (error && /sender_id/.test(error.message)) ({ error } = await supabase.from("tama_push_events").insert({ user_id: to, kind: k, ev }));   // tama_safety.sql の実行前
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
    // 📱 アプリの端末（fcm・apns）は別に集める
    const natives: { endpoint: string; type: string; token: string }[] = [];
    if (!dErr) for (const d of devs ?? []) {
      const t = d.subscription?.type;
      if ((t === "fcm" || t === "apns") && d.subscription?.token) natives.push({ endpoint: d.endpoint, type: t, token: d.subscription.token });
      else if (d.subscription?.endpoint) subs.set(d.endpoint, d.subscription);
    }
    if (!vapidReady) { if (subs.size) console.error("[send-match-push] VAPID未設定のため、ブラウザの通知は送らない"); subs.clear(); }

    if (subs.size === 0 && natives.length === 0) {
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
    // 📱 アプリの端末
    const msg = { title: title || "ちかく", body: body || "", url: safeUrl(url), tag: typeof tag === "string" && tag ? tag.slice(0, 64) : undefined };
    await Promise.all(natives.map(async (n) => {
      const r = await sendNative(n.type, n.token, msg);
      if (r === "sent") sent++;
      else { errors.push(n.type + ":" + r); if (r === "gone") await supabase.from("tama_push_devices").delete().eq("endpoint", n.endpoint); }
    }));

    const devices = subs.size + natives.length;
    console.log("[send-match-push] 送信", sent, "/", devices, "(to:", to, ")");
    await log(sent ? "sent" : "fail");
    return reply(sent ? { ok: true, sent, devices } : { ok: false, sent, devices, error: errors.join(",") });
  } catch (e) {
    console.error("[send-match-push] 想定外エラー:", String(e));
    return reply({ error: String(e) }, 500);
  }
});
