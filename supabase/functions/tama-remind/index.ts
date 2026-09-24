// Supabase ダッシュボード → Edge Functions → 新規関数 "tama-remind" として
// このファイルの内容をそのまま貼り付けてデプロイしてください（Verify JWT は ON のままでよい）。
//
// 多摩キャン版の「いまどこ？を入れよう」の通知。pg_cron が平日の決まった時刻に呼ぶ（supabase/tama_remind.sql）。
//   { "kind": "period", "period": 1〜5 } … その時限に授業がある人（tama_timetable に登録した人）にだけ送る。授業の始まりから5分後
//   { "kind": "lunch" }                  … 多摩キャン版の参加者全員に送る（時間割を登録していない人に届くのはこの1回だけ）
// 通知がうるさくて切られないよう、授業のない時間・全休の日には送らない（あおの判断、2026-09-24）。
//
// Secrets は send-match-push と同じ VAPID_PUBLIC_KEY / VAPID_PRIVATE_KEY を使う（プロジェクト共通なので追加設定は不要）。

import { createClient } from "npm:@supabase/supabase-js@2";
import webpush from "npm:web-push@3.6.7";

const json = (obj: unknown, status = 200) =>
  new Response(JSON.stringify(obj), { status, headers: { "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  let body: { kind?: string; period?: number } = {};
  try { body = await req.json(); } catch { /* 空のまま */ }

  // 日本時間の曜日（cron でも平日に絞っているが、念のためここでも確かめる）
  const dow = new Date(Date.now() + 9 * 3600_000).getUTCDay();
  if (dow < 1 || dow > 5) return json({ ok: true, skipped: "weekend" });

  const vapidPublicKey = Deno.env.get("VAPID_PUBLIC_KEY") ?? "";
  const vapidPrivateKey = Deno.env.get("VAPID_PRIVATE_KEY") ?? "";
  if (!vapidPublicKey || !vapidPrivateKey) {
    console.error("[tama-remind] VAPID_PUBLIC_KEY / VAPID_PRIVATE_KEY が Secrets に設定されていません");
    return json({ ok: false, reason: "vapid not configured" });
  }
  webpush.setVapidDetails("mailto:support@example.com", vapidPublicKey, vapidPrivateKey);

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  // 送り先と文面を決める
  let ids: string[] = [];
  let title = "", text = "";
  if (body.kind === "period") {
    const period = Number(body.period);
    if (!(period >= 1 && period <= 5)) return json({ ok: false, reason: "bad period" });
    const key = `${dow}-${period}`;
    const { data, error } = await supabase.from("tama_timetable").select("id,slots");
    if (error) return json({ ok: false, reason: error.message });
    ids = (data ?? []).filter((r) => r.slots && Object.prototype.hasOwnProperty.call(r.slots, key)).map((r) => r.id);
    title = `📍 ${period}限が始まりました`;
    text = "「いまどこ？」に教室を入れると、友達に表示されます";
  } else if (body.kind === "lunch") {
    const { data, error } = await supabase.from("tama_profiles").select("id");
    if (error) return json({ ok: false, reason: error.message });
    ids = (data ?? []).map((r) => r.id);
    // 今日のお題（アプリの DAILY_QS）の中身はアプリ側にあるので、ここでは誘うだけにする
    title = "🎲 今日のお題、もう答えた？";
    text = "昼休み、同じ答えの人が近くにいるかも。「いまどこ？」も更新しよう";
  } else {
    return json({ ok: false, reason: "bad kind" });
  }
  if (ids.length === 0) return json({ ok: true, sent: 0, targets: 0 });

  // 通知を許可している人の購読
  const subs: { id: string; subscription: webpush.PushSubscription }[] = [];
  for (let i = 0; i < ids.length; i += 200) {
    const { data } = await supabase
      .from("push_subscriptions")
      .select("id,subscription")
      .in("id", ids.slice(i, i + 200));
    subs.push(...(data ?? []));
  }

  const payload = JSON.stringify({ title, body: text, url: "/tama/", tag: "chikaku-tama-remind" });
  let sent = 0;
  await Promise.all(subs.map(async (s) => {
    try {
      await webpush.sendNotification(s.subscription, payload);
      sent++;
    } catch (err) {
      // 購読が失効している場合（410 Gone など）は掃除しておく
      const statusCode = (err as { statusCode?: number })?.statusCode;
      if (statusCode === 404 || statusCode === 410) {
        await supabase.from("push_subscriptions").delete().eq("id", s.id);
      }
    }
  }));

  console.log("[tama-remind]", body.kind, body.period ?? "", "送信", sent, "/", subs.length);
  return json({ ok: true, sent, targets: subs.length });
});
