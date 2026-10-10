// Supabase ダッシュボード → Edge Functions → 新規関数 "tama-remind" として
// このファイルの内容をそのまま貼り付けてデプロイしてください（Verify JWT は ON のままでよい）。
//
// 多摩キャン版の決まった時刻の通知。pg_cron が平日の決まった時刻に呼ぶ（supabase/tama_remind.sql・supabase/tama_notify.sql）。
//   { "kind": "period", "period": 1〜5 } … その日最初の授業がこの時限で、友達が1人以上いる人にだけ送る（授業の始まりから5分後）
//   { "kind": "lunch" }                  … 今日のお題にまだ答えていない人にだけ、お題の文面を入れて送る
//   { "kind": "ct" }                     … ちかくタイム。いまの時刻が今週の予定（tama_ct_slots）に入っていれば、お題を送る（入っていなければ何もしない）
// 自動の通知は1人1日2通まで（その日最初の授業の1通＋昼休みの1通）。あおの決定（2026-10-01）。
// ちかくタイムの日だけ3通（2026-10-10 あおの決定。ちかくタイムは週2〜3回）。
// 以前は授業ごと（最大5通）＋昼休みに全員（もう答えた人にも）で、1日最大6通届いていた。
// 通知の数が多いと切られる・使われなくなる（週6〜10通で32%が使うのをやめるという調査がある）ため。
// 授業の通知は「いまどこ？」に教室を入れると友達に見える、という案内なので、友達がいない人には送らない。
//
// 2026-10-10 で足したこと（supabase/tama_notify.sql の実行が前提。実行前でも前と同じように送る）:
//   ・送り先は push_subscriptions と tama_push_devices（端末ごと）の両方。同じ送り先には1回だけ
//   ・本人が「通知の種類」でオフにしたもの（fes_attrs.push_off に class・daily・ct）は送らない
//   ・送った記録を tama_push_events に書く。通知を押すとアプリの該当する所が開く（url の go=）
//   ・昼休みの通知に「いまキャンパスに◯人（共通点のある人◯人）」を入れる（その人に合わせた文のほうが開かれやすいため）
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

// アプリの normAns と同じそろえ方（全角半角・大文字小文字・ひらがなカタカナ・空白や記号）
const normAns = (s: unknown) =>
  String(s ?? "").normalize("NFKC").toLowerCase().replace(/[\s・,.、。!?！？'"「」『』()（）\-ー]/g, "")
    .replace(/[ぁ-ゖ]/g, (c) => String.fromCharCode(c.charCodeAt(0) + 0x60));
const normCourse = (s: unknown) => String(s ?? "").normalize("NFKC").replace(/[\s　]+/g, "").toLowerCase();
const WEAK = ["まだ考え中"];   // アプリの FA.weak（共通点に数えない答え）
type FA = Record<string, unknown>;
const arr = (v: unknown) => (Array.isArray(v) ? v.map(String) : []);

// 2人に共通点があるか（アプリの commonRaw をかんたんにしたもの。受け取る人 me が「マッチングに使う共通点」で外した項目は数えない）
function hasCommon(me: FA, th: FA, myTT: Record<string, string>, thTT: Record<string, string>): boolean {
  const off = arr(me.match_off);
  const on = (k: string) => !off.includes(k);
  const both = (k: string) => arr(me[k]).some((x) => !WEAK.includes(x) && arr(th[k]).includes(x));
  if (on("pur") && both("purposes")) return true;
  if (on("goal") && both("goals")) return true;
  if (on("aru") && both("aruaru")) return true;
  const a = normAns(me.artist);
  if (on("art") && a && a === normAns(th.artist)) return true;
  const c = normCourse(me.course);
  if (on("crs") && c && c === normCourse(th.course)) return true;
  if (on("cls")) for (const [slot, name] of Object.entries(myTT)) if (normAns(name) && normAns(name) === normAns(thTT[slot])) return true;
  return false;
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

  // 送り先と文面を決める（文面は人ごとに変えられる：textFor）
  let ids: string[] = [];
  let title = "", text = "", url = "/tama/", tag = "chikaku-tama-remind", pref = "";
  let textFor: ((id: string) => string) | null = null;
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
    url = "/tama/?go=where&n=class"; tag = "tama-class"; pref = "class";
  } else if (body.kind === "lunch") {
    const today = await todaysQuestion(jstMs);
    const todayStr = today?.d ?? new Date(jstMs - (jstMs % 86400000)).toISOString().slice(0, 10);
    const { data, error } = await supabase.from("tama_profiles").select("id,fa:fes_attrs,sharing,updated_at,lat");
    if (error) return json({ ok: false, reason: error.message });
    const rows = data ?? [];
    // 今日のお題にまだ答えていない人だけ（答えた人には送らない）
    ids = rows.filter((r) => { const d = (r.fa ?? {}).daily; return !(d && d.d === todayStr && d.a); }).map((r) => String(r.id));
    title = "🎲 今日のお題";
    const qText = today ? `「${today.q}」答えると、同じ答えの人が見られます` : "答えると、みんなの答えと同じ答えの人が見られます";
    text = qText;
    url = "/tama/?go=daily&n=daily"; tag = "tama-daily"; pref = "daily";
    // いまキャンパスにいる人（位置を見せていて、15分以内に位置が更新された人＝アプリを開いている人）。
    // 3人以上いる時だけ、人数と「あなたと共通点のある人」の数を入れる（少ないと寂しく見える・だれか分かるため）
    const now = Date.now();
    const onCampus = rows.filter((r) => r.sharing && r.lat != null && r.updated_at && now - Date.parse(r.updated_at) < 15 * 60000);
    if (onCampus.length >= 3) {
      const { data: tts } = await supabase.from("tama_timetable").select("id,slots");
      const ttOf = new Map<string, Record<string, string>>();
      for (const t of tts ?? []) if (t.slots && typeof t.slots === "object") ttOf.set(String(t.id), t.slots);
      const faOf = new Map(rows.map((r) => [String(r.id), (r.fa ?? {}) as FA]));
      textFor = (id) => {
        const others = onCampus.filter((r) => String(r.id) !== id);
        if (others.length < 3) return qText;
        const me = faOf.get(id) ?? {}, myTT = ttOf.get(id) ?? {};
        const c = others.filter((r) => hasCommon(me, (r.fa ?? {}) as FA, myTT, ttOf.get(String(r.id)) ?? {})).length;
        return `いまキャンパスに${others.length}人${c ? `（あなたと共通点のある人 ${c}人）` : ""}。${qText}`;
      };
    }
  } else if (body.kind === "ct") {
    // いまの時刻（前後4分）に予定があって、まだ送っていないものを1つ取る。先に sent_at を入れて二重に送らないようにする
    const lo = new Date(Date.now() - 4 * 60000).toISOString(), hi = new Date(Date.now() + 4 * 60000).toISOString();
    const { data: slot, error } = await supabase.from("tama_ct_slots").update({ sent_at: new Date().toISOString() })
      .gte("starts_at", lo).lte("starts_at", hi).is("sent_at", null).select("id,q,o1,o2").maybeSingle();
    if (error) return json({ ok: false, reason: error.message });
    if (!slot) return json({ ok: true, skipped: "no slot now" });
    // 送り先：通知を許可している全員。ただし、時間割を入れていて今日は授業が1つもない人には送らない（キャンパスにいないはずなので）
    const { data: tts } = await supabase.from("tama_timetable").select("id,slots");
    const noClassToday = new Set<string>();
    for (const t of tts ?? []) {
      const keys = Object.keys(t.slots ?? {});
      if (keys.length && !keys.some((k) => k.startsWith(`${dow}-`))) noClassToday.add(String(t.id));
    }
    const all = new Set<string>();
    const { data: ps } = await supabase.from("push_subscriptions").select("id");
    for (const p of ps ?? []) all.add(String(p.id));
    const { data: ds } = await supabase.from("tama_push_devices").select("user_id");
    for (const d of ds ?? []) all.add(String(d.user_id));
    // 多摩キャン版のプロフィールがある人だけ（push_subscriptions は通常版・学園祭版と共用のため）
    const { data: prof } = await supabase.from("tama_profiles").select("id");
    const tama = new Set((prof ?? []).map((p) => String(p.id)));
    ids = [...all].filter((id) => tama.has(id) && !noClassToday.has(id));
    title = "⏰ ちかくタイム（10分間）";
    text = `「${slot.q}」${slot.o1}？${slot.o2}？ 10分のあいだに答えた人どうしで、同じ答えの人が見つかります`;
    url = "/tama/?go=ct&n=ct"; tag = "tama-ct"; pref = "ct";
  } else {
    return json({ ok: false, reason: "bad kind" });
  }
  if (ids.length === 0) return json({ ok: true, sent: 0, targets: 0 });

  // 「通知の種類」でオフにした人を除く
  const off = new Set<string>();
  for (let i = 0; i < ids.length; i += 200) {
    const { data } = await supabase.from("tama_profiles").select("id,off:fes_attrs->push_off").in("id", ids.slice(i, i + 200));
    for (const r of data ?? []) if (Array.isArray(r.off) && r.off.includes(pref)) off.add(String(r.id));
  }
  const offIds = ids.filter((id) => off.has(id));
  ids = ids.filter((id) => !off.has(id));

  // 送り先（1人に端末が複数あれば全部。同じ送り先は1回だけ）
  const subs = new Map<string, { id: string; sub: webpush.PushSubscription }>();
  for (let i = 0; i < ids.length; i += 200) {
    const chunk = ids.slice(i, i + 200);
    const { data } = await supabase.from("push_subscriptions").select("id,subscription").in("id", chunk);
    for (const s of data ?? []) if (s.subscription?.endpoint) subs.set(s.subscription.endpoint, { id: String(s.id), sub: s.subscription });
    const { data: devs, error: dErr } = await supabase.from("tama_push_devices").select("user_id,endpoint,subscription").in("user_id", chunk);
    if (!dErr) for (const d of devs ?? []) if (d.subscription?.endpoint) subs.set(d.endpoint, { id: String(d.user_id), sub: d.subscription });
  }

  const ok = new Set<string>(), tried = new Set<string>();
  await Promise.all([...subs.entries()].map(async ([endpoint, s]) => {
    tried.add(s.id);
    const payload = JSON.stringify({ title, body: textFor ? textFor(s.id) : text, url, tag });
    try {
      await webpush.sendNotification(s.sub, payload);
      ok.add(s.id);
    } catch (err) {
      // 送り先が無効な場合（410 Gone など）は両方から消す。アプリは次に開いた時に作り直す
      const statusCode = (err as { statusCode?: number })?.statusCode;
      if (statusCode === 404 || statusCode === 410) {
        await supabase.from("push_subscriptions").delete().eq("id", s.id).eq("subscription->>endpoint", endpoint);
        await supabase.from("tama_push_devices").delete().eq("endpoint", endpoint);
      }
    }
  }));

  // 記録（テーブルが無い時＝tama_notify.sql の実行前は何もしない）
  const events = [
    ...[...tried].map((id) => ({ user_id: id, kind: pref, ev: ok.has(id) ? "sent" : "fail" })),
    ...offIds.map((id) => ({ user_id: id, kind: pref, ev: "off" })),
  ];
  for (let i = 0; i < events.length; i += 500) {
    const { error } = await supabase.from("tama_push_events").insert(events.slice(i, i + 500));
    if (error) { console.log("[tama-remind] 記録できません（tama_notify.sql の実行前?）:", error.message); break; }
  }

  console.log("[tama-remind]", body.kind, body.period ?? "", "届けた人", ok.size, "/", tried.size, "オフ", offIds.length);
  return json({ ok: true, sent: ok.size, targets: tried.size, off: offIds.length });
});
