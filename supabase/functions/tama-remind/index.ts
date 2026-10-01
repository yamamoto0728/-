// Supabase ダッシュボード → Edge Functions → 新規関数 "tama-remind" として
// このファイルの内容をそのまま貼り付けてデプロイしてください（Verify JWT は ON のままでよい）。
//
// 多摩キャン版の決まった時刻の通知。pg_cron が平日の決まった時刻に呼ぶ（supabase/tama_remind.sql）。
//   { "kind": "period", "period": 1〜5 } … その日最初の授業がこの時限で、友達が1人以上いる人にだけ送る（授業の始まりから5分後）
//   { "kind": "lunch" }                  … 今日のお題にまだ答えていない人にだけ、お題の文面を入れて送る
// 自動の通知は1人1日2通まで（その日最初の授業の1通＋昼休みの1通）。あおの決定（2026-10-01）。
// 以前は授業ごと（最大5通）＋昼休みに全員（もう答えた人にも）で、1日最大6通届いていた。
// 通知の数が多いと切られる・使われなくなる（週6〜10通で32%が使うのをやめるという調査がある）ため。
// 授業の通知は「いまどこ？」に教室を入れると友達に見える、という案内なので、友達がいない人には送らない。
//
// Secrets は send-match-push と同じ VAPID_PUBLIC_KEY / VAPID_PRIVATE_KEY を使う（プロジェクト共通なので追加設定は不要）。

import { createClient } from "npm:@supabase/supabase-js@2";
import webpush from "npm:web-push@3.6.7";

const json = (obj: unknown, status = 200) =>
  new Response(JSON.stringify(obj), { status, headers: { "Content-Type": "application/json" } });

// 今日のお題の一覧はアプリと同じファイルを本番のURLから読む（2つに分けて書くと、片方だけ直して食い違うため）
const DAILY_QS_URL = "https://chikaku-hosei.vercel.app/tama/daily-qs.js";
// 今日のお題の文面。読めなかった時は null（その時は文面なしの通知にする）
async function todaysQuestion(jstMs: number): Promise<{ d: string; q: string } | null> {
  try {
    const res = await fetch(DAILY_QS_URL);
    if (!res.ok) return null;
    const src = await res.text();
    const start = src.indexOf("DAILY_QS=[");
    const epoch = /DAILY_EPOCH=Date\.parse\('([^']+)'\)/.exec(src);
    if (start < 0 || !epoch) return null;
    const qs = [...src.slice(start).matchAll(/\{q:'([^']*)'/g)].map((m) => m[1]);
    if (!qs.length) return null;
    // アプリの dailyToday() と同じ数え方（日本時間の0時どうしの日数で順番に出す）
    const dayStart = jstMs - (jstMs % 86400000);   // 日本時間の今日0時（9時間ずらした時刻のまま）
    const epochJst = Date.parse(epoch[1]) + 9 * 3600_000;
    const n = ((Math.floor((dayStart - epochJst) / 86400000) % qs.length) + qs.length) % qs.length;
    return { d: new Date(dayStart).toISOString().slice(0, 10), q: qs[n] };
  } catch {
    return null;
  }
}

Deno.serve(async (req) => {
  let body: { kind?: string; period?: number } = {};
  try { body = await req.json(); } catch { /* 空のまま */ }

  // 日本時間（cron でも平日に絞っているが、念のためここでも確かめる）
  const jstMs = Date.now() + 9 * 3600_000;
  const dow = new Date(jstMs).getUTCDay();
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
    const key = (p: number) => `${dow}-${p}`;
    const { data, error } = await supabase.from("tama_timetable").select("id,slots");
    if (error) return json({ ok: false, reason: error.message });
    // この時限に授業があり、それより前の時限には授業がない人（＝その日最初の授業）
    const first = (data ?? []).filter((r) => {
      const s = r.slots ?? {};
      if (!Object.prototype.hasOwnProperty.call(s, key(period))) return false;
      for (let p = 1; p < period; p++) if (Object.prototype.hasOwnProperty.call(s, key(p))) return false;
      return true;
    }).map((r) => String(r.id));
    if (first.length) {
      // そのうち、承認済みの友達が1人以上いる人
      const { data: fr, error: frErr } = await supabase.from("tama_friends").select("from_id,to_id").eq("status", "accepted");
      if (frErr) return json({ ok: false, reason: frErr.message });
      const hasFriend = new Set<string>();
      for (const f of fr ?? []) { hasFriend.add(String(f.from_id)); hasFriend.add(String(f.to_id)); }
      ids = first.filter((id) => hasFriend.has(id));
    }
    title = `📍 ${period}限が始まりました`;
    text = "「いまどこ？」に教室を入れると、友達に表示されます";
  } else if (body.kind === "lunch") {
    const today = await todaysQuestion(jstMs);
    const todayStr = today?.d ?? new Date(jstMs - (jstMs % 86400000)).toISOString().slice(0, 10);
    const { data, error } = await supabase.from("tama_profiles").select("id,daily:fes_attrs->daily");
    if (error) return json({ ok: false, reason: error.message });
    // 今日のお題にまだ答えていない人だけ（答えた人には送らない）
    ids = (data ?? []).filter((r) => !(r.daily && r.daily.d === todayStr && r.daily.a)).map((r) => String(r.id));
    title = "🎲 今日のお題";
    text = today
      ? `「${today.q}」答えると、みんなの答えと同じ答えの人が見られます`
      : "答えると、みんなの答えと同じ答えの人が見られます";
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
