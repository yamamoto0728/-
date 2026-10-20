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
// 2026-10-14 多摩祭（2026-10-17・18）の分を足した（supabase/tama_tamasai.sql の cron が呼ぶ）:
//   { "kind": "ct" }                         … 土日でも、予定があれば送る（祭りの昼と夕方のちかくタイム）。土日は「今日は授業が無い人」を除かない
//   { "kind": "recap", "day": "2026-10-17" } … その日にキャンパスで開いた人に「今日の多摩祭で◯人とすれ違いました」。day が今日の時だけ
//   { "kind": "fsurvey" }                    … 多摩祭に来た人にアンケートの案内。tama/tamasai.js の surveyUrl が空・期間の外なら送らない
//   { "kind": "shop", "day": "2026-10-17", "slot": "1400" } … 出店・出演している人へ「無料で宣伝しませんか」（2026-10-16。supabase/tama_fes_shop.sql）。
//                                            「出店・出演中」をまだ選んでいない人全員へ。day が今日の時だけ、slot ごとに1回
// 2026-10-20 あおの決定：ちかくタイムは毎週 月・水・木の13:00 に固定（supabase/tama_ct_fixed.sql）。その日は lunch（12:55 のお題）を送らず、ct の通知に一言まとめる
// 2026-10-16 あおの決定「通知をもっとマッチングに生かす」で足したもの（supabase/tama_fes_push.sql）:
//   { "kind": "stage" }                      … 5分ごと。始まる5〜10分前のステージを「👀 見に行く」にした人だけへ、見に行くちかくの人の数つき
//   { "kind": "likes" }                      … 多摩祭の日の16:00。今日届いたいいねを、まだ返していない人だけへ（件数つき）
//   { "kind": "morning", "day": "2026-10-18", "prev": "2026-10-17" } … 2日目の朝。1日目に来た人だけへ、昨日すれ違った人数と今日の予定
//   recap（1日目の夜）は、アンケートの期間ならアンケートの一言も入れる（18:00 のアンケートの通知とまとめて1通に）
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

// 多摩祭の設定（アプリと同じファイルを本番のURLから読む）。読めなければ null
const TAMASAI_URL = "https://chikaku-hosei.vercel.app/tama/tamasai.js";
async function tamasaiConf(): Promise<{ days: string[]; surveyUrl: string; surveyFrom: number; surveyUntil: number; ctTimes: string[] } | null> {
  try {
    const res = await fetch(TAMASAI_URL);
    if (!res.ok) return null;
    const src = await res.text();
    // 行の頭（空白のあと）から探す。コメントの中の「surveyUrl:'…'」に当たらないように（2026-10-15 のレビューで直した）
    const str = (k: string) => (new RegExp(`^[ \\t]*${k}:'([^']*)'`, "m").exec(src) ?? [])[1] ?? "";
    const list = (k: string) => [...((new RegExp(`^[ \\t]*${k}:\\[([^\\]]*)\\]`, "m").exec(src) ?? [])[1] ?? "").matchAll(/'([^']*)'/g)].map((m) => m[1]);
    return { days: list("days"), surveyUrl: str("surveyUrl"), surveyFrom: Date.parse(str("surveyFrom")) || 0, surveyUntil: Date.parse(str("surveyUntil")) || 0, ctTimes: list("ctTimes") };
  } catch {
    return null;
  }
}

// 多摩祭のステージの一覧（tama/tamasai.js の stages。1行に1つ {d:'日付',s:'始まり',e:'終わり',n:'名前',g:'団体',p:'場所'}）。
// 番号 i はアプリの fesStageKey と同じ（並び順）。見に行く人の fes_attrs.fes26go には `${d}_${s から : を取ったもの}_${i}` が入る
async function tamasaiStages(): Promise<{ key: string; d: string; s: string; n: string; p: string }[]> {
  try {
    const res = await fetch(TAMASAI_URL);
    if (!res.ok) return [];
    const src = await res.text();
    const at = src.search(/^[ \t]*stages:\[/m);
    if (at < 0) return [];
    const block = src.slice(at, src.indexOf("\n  ]", at));
    const out: { key: string; d: string; s: string; n: string; p: string }[] = [];
    for (const m of block.matchAll(/\{d:'([^']+)',s:'([^']+)',e:'[^']*',n:'([^']*)'(?:,g:'[^']*')?(?:,p:'([^']*)')?/g)) {
      out.push({ key: `${m[1]}_${m[2].replace(":", "")}_${out.length}`, d: m[1], s: m[2], n: m[3], p: m[4] ?? "" });
    }
    return out;
  } catch {
    return [];
  }
}

// その日（day）に、それぞれの人が何人とすれ違ったか（同じ人は1人）。1回に返るのは1000行までなので、5人ずつ読む
// deno-lint-ignore no-explicit-any
async function metCounts(supabase: any, ids: string[], day: string): Promise<Map<string, number>> {
  const start = new Date(Date.parse(`${day}T00:00:00+09:00`)).toISOString(), end = new Date(Date.parse(`${day}T00:00:00+09:00`) + 86400000).toISOString();
  const met = new Map<string, Set<string>>();
  for (let i = 0; i < ids.length; i += 5) {
    const { data: logs } = await supabase.from("tama_encounter_log").select("owner_id,other_id").in("owner_id", ids.slice(i, i + 5)).gte("at", start).lt("at", end).limit(1000);
    for (const l of logs ?? []) { const k = String(l.owner_id); if (!met.has(k)) met.set(k, new Set()); met.get(k)!.add(String(l.other_id)); }
  }
  return new Map([...met].map(([k, v]) => [k, v.size]));
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
  let body: { kind?: string; period?: number; day?: string; slot?: string; prev?: string } = {};
  try { body = await req.json(); } catch { /* 空のまま */ }

  // 日本時間（cron でも平日に絞っているが、念のためここでも確かめる）。ちかくタイム・多摩祭の通知は土日も送る
  const jstMs = Date.now() + 9 * 3600_000;
  const dow = new Date(jstMs).getUTCDay();
  const weekend = dow < 1 || dow > 5;
  if (weekend && (body.kind === "period" || body.kind === "lunch")) return json({ ok: true, skipped: "weekend" });
  const todayJst = new Date(jstMs).toISOString().slice(0, 10);

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
  let titleFor: ((id: string) => string) | null = null;
  let onceKey = "";   // 多摩祭の通知を1回だけにする鍵（tama_fes_sent）。空なら確かめない
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
    // ちかくタイムのある日（月・水・木の13:00。supabase/tama_ct_fixed.sql）は、12:55 のこの通知を送らない。
    // 13:00 のちかくタイムの通知に「今日のお題も」と一言入れて、昼の通知を1通にする（2026-10-20 あおの決定）
    const dayStart = new Date(Date.parse(`${todayJst}T00:00:00+09:00`)).toISOString(), dayEnd = new Date(Date.parse(`${todayJst}T00:00:00+09:00`) + 86400000).toISOString();
    const { data: ctToday } = await supabase.from("tama_ct_slots").select("id").gte("starts_at", dayStart).lt("starts_at", dayEnd).limit(1);
    if (ctToday && ctToday.length) return json({ ok: true, skipped: "chikaku time today" });
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
      .gte("starts_at", lo).lte("starts_at", hi).is("sent_at", null).select("*").maybeSingle();
    if (error) return json({ ok: false, reason: error.message });
    if (!slot) return json({ ok: true, skipped: "no slot now" });
    // 送り先：通知を許可している全員。ただし平日は、時間割を入れていて今日は授業が1つもない人には送らない（キャンパスにいないはずなので）。
    // 土日（多摩祭）は授業が無いので、この絞り込みはしない
    const noClassToday = new Set<string>();
    if (!weekend) {
      const { data: tts } = await supabase.from("tama_timetable").select("id,slots");
      for (const t of tts ?? []) {
        const keys = Object.keys(t.slots ?? {});
        if (keys.length && !keys.some((k) => k.startsWith(`${dow}-`))) noClassToday.add(String(t.id));
      }
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
    // 土日（多摩祭）は、その日にキャンパスでアプリを開いた人だけ（2026-10-15 のレビュー：祭りに来ていない人に土日で5通届いて、通知を切られるため）
    if (weekend) {
      const { data: vs } = await supabase.from("tama_visits").select("user_id").eq("day", todayJst).eq("on_campus", true);
      const came = new Set((vs ?? []).map((v) => String(v.user_id)));
      ids = ids.filter((id) => came.has(id));
    }
    // 回ごとに文を変えたい時は push_title・push_body（多摩祭の花火の回。2026-10-15）
    title = slot.push_title || "⏰ ちかくタイム（10分間）";
    text = slot.push_body || `「${slot.q}」${slot.o1}？${slot.o2}？ 10分のあいだに答えた人どうしで、同じ答えの人が見つかります`;
    if (!weekend && !slot.push_body) text += "（今日のお題も出ています）";   // 平日は 12:55 のお題の通知をまとめたので（2026-10-20）
    url = "/tama/?go=ct&n=ct"; tag = "tama-ct"; pref = "ct";
  } else if (body.kind === "recap") {
    // 多摩祭1日目の夜：その日にキャンパスで開いた人に、その日すれ違った人数を（2日目に開く理由。チームの意見）
    const day = String(body.day ?? "");
    if (day !== todayJst) return json({ ok: true, skipped: "not the day" });   // cron は毎年動くので、指定の日だけ
    const conf = await tamasaiConf();
    const { data: vs, error } = await supabase.from("tama_visits").select("user_id").eq("day", day).eq("on_campus", true);
    if (error) return json({ ok: false, reason: error.message });
    ids = [...new Set((vs ?? []).map((v) => String(v.user_id)))];
    // 1人が1日に200回以上すれ違うことはまず無い（2026-10-15 のレビューで5人ずつ読むようにした。metCounts）
    const met = await metCounts(supabase, ids, day);
    const times = conf?.ctTimes?.length ? `明日も ${conf.ctTimes.join("・")} にちかくタイム。` : "";
    // 2026-10-16 あおの決定：1日目の夜は 18:00 のアンケートとこの通知を1通にまとめる（同じ人に30分で2通届いていたため）。
    // アンケートの期間に入っていれば、アンケートの一言を足し、押した先をアンケートのある🎪カードにする
    const sv = !!conf && !!conf.surveyUrl && Date.now() >= conf.surveyFrom && Date.now() < conf.surveyUntil;
    const svText = sv ? "1分のアンケートに答えると限定バッジ📝。" : "";
    title = "🎪 今日は多摩祭に来てくれてありがとう";
    textFor = (id) => {
      const n = met.get(id) ?? 0;
      return n ? `今日は ${n}人とすれ違いました。${svText}明日も来ると、もう一度すれ違えるかも。${times}` : `${svText}${times}アプリを開いたまま歩くと、すれ違った人が記録されます`;
    };
    url = sv ? "/tama/?go=tamasai&n=tamasai" : "/tama/?go=cross&n=tamasai"; tag = "tama-recap"; pref = "tamasai";
  } else if (body.kind === "fsurvey") {
    // 多摩祭のアンケート：URL があって、期間の中の時だけ。多摩祭の日にキャンパスで開いた人のうち、まだアンケートを押していない人へ
    const conf = await tamasaiConf();
    const now = Date.now();
    if (!conf || !conf.surveyUrl || now < conf.surveyFrom || now >= conf.surveyUntil || !conf.days.length) return json({ ok: true, skipped: "no survey" });
    const { data: vs, error } = await supabase.from("tama_visits").select("user_id").in("day", conf.days).eq("on_campus", true);
    if (error) return json({ ok: false, reason: error.message });
    const cand = [...new Set((vs ?? []).map((v) => String(v.user_id)))];
    // 2026-10-16：案内するのはアプリの中の「多摩祭アンケート」（1分）。もう答えた人（fes_attrs.fes26sv2）には送らない。
    // いつものアンケート（Googleフォーム）はマイページに常設のまま。答えた人にも、多摩祭アンケートは別なので送る
    const done = new Set<string>();
    for (let i = 0; i < cand.length; i += 200) {
      const { data } = await supabase.from("tama_profiles").select("id,sv:fes_attrs->fes26sv2").in("id", cand.slice(i, i + 200));
      for (const r of data ?? []) if (r.sv) done.add(String(r.id));
    }
    ids = cand.filter((id) => !done.has(id));
    title = "📝 多摩祭アンケート（1分）";
    text = "多摩祭に来てくれてありがとう。タップだけの1分のアンケートに答えると、限定バッジ「📝 多摩祭の声」とみんなの答えが見られます";
    url = "/tama/?go=tamasai&n=tamasai"; tag = "tama-fsurvey"; pref = "tamasai";
  } else if (body.kind === "shop") {
    // 出店・出演している人へ「アプリで無料で宣伝しませんか」（2026-10-16 あおの決定：1日目の 14:00 と 16:30）。
    // だれが出店者かはアプリから分からないので、「出店・出演中」をまだ選んでいない人全員に、文で呼びかける。day が今日の時だけ
    const day = String(body.day ?? "");
    if (day !== todayJst) return json({ ok: true, skipped: "not the day" });
    const { data: ps, error } = await supabase.from("tama_profiles").select("id,role:fes_attrs->fes26role").limit(5000);
    if (error) return json({ ok: false, reason: error.message });
    ids = (ps ?? []).filter((p) => !p.role).map((p) => String(p.id));
    title = "🏮 出店・出演している方へ";
    text = "「ちかく」で、あなたのお店・ステージを無料で宣伝しませんか？店と場所を選ぶだけで、一覧とプロフィールに「🏮 出店中・📍 場所」が出て、近くの人に見つけてもらえます";
    url = "/tama/?go=role&n=shop"; tag = "tama-shop"; pref = "tamasai";
  } else if (body.kind === "stage") {
    // 👀 ステージの10分前（2026-10-16 あおの決定）：「見に行く」を押した人だけに、始まる5〜10分前に1回。見に行くちかくの人の数つき。
    // cron は多摩祭の日の 11:00〜18:55 に5分ごと。同じステージは1回だけ（tama_fes_sent の stage:鍵）
    const now = Date.now();
    const soon = (await tamasaiStages()).filter((s) => {
      if (s.d !== todayJst) return false;
      const left = Date.parse(`${s.d}T${s.s}:00+09:00`) - now;
      return left > 5 * 60000 && left <= 10 * 60000;
    });
    if (!soon.length) return json({ ok: true, skipped: "no stage soon" });
    const fresh: typeof soon = [];
    for (const s of soon) {
      const { error: e } = await supabase.from("tama_fes_sent").insert({ key: `stage:${s.key}` });
      if (!(e && (e.code === "23505" || /duplicate/i.test(e.message)))) fresh.push(s);
    }
    if (!fresh.length) return json({ ok: true, skipped: "already sent" });
    const { data: ps, error } = await supabase.from("tama_profiles").select("id,go:fes_attrs->fes26go").limit(5000);
    if (error) return json({ ok: false, reason: error.message });
    const goers = new Map<string, string[]>();   // ステージの鍵 → 見に行く人
    for (const p of ps ?? []) for (const k of (Array.isArray(p.go) ? p.go : [])) {
      if (!fresh.some((s) => s.key === k)) continue;
      if (!goers.has(k)) goers.set(k, []);
      goers.get(k)!.push(String(p.id));
    }
    const stageOf = new Map<string, (typeof fresh)[number]>();   // 人 → そのステージ（同じ時刻に2つ押していたら先のもの）
    for (const s of fresh) for (const id of goers.get(s.key) ?? []) if (!stageOf.has(id)) stageOf.set(id, s);
    ids = [...stageOf.keys()];
    titleFor = (id) => { const s = stageOf.get(id)!; return `👀 まもなく ${s.s}〜「${s.n}」`; };
    textFor = (id) => {
      const s = stageOf.get(id)!, n = (goers.get(s.key)?.length ?? 1) - 1;
      return `${s.p ? s.p + "で始まります。" : ""}${n > 0 ? `見に行くちかくの人があなたのほかに ${n}人。同じステージの人は、今日だけ共通点に出ます` : "同じステージを見に行く人は、今日だけ共通点に出ます"}`;
    };
    url = "/tama/?go=tamasai&n=stage"; tag = "tama-stage"; pref = "tamasai";
  } else if (body.kind === "likes") {
    // 👋 返事待ちのいいね（2026-10-16 あおの決定：多摩祭の両日 16:00）：今日届いたいいねを、まだ返していない人だけに。件数つき
    const conf = await tamasaiConf();
    if (!conf || !conf.days.includes(todayJst)) return json({ ok: true, skipped: "not a festival day" });
    onceKey = `likes:${todayJst}`;
    // 1回に返るのは1000行までなので、今日のいいねだけ読み、返したか・ブロックしたかは、届いた人ごとに200人ずつ読む
    const start = new Date(Date.parse(`${todayJst}T00:00:00+09:00`)).toISOString();
    const { data: lk, error } = await supabase.from("tama_likes").select("from_id,to_id").gte("created_at", start).limit(1000);
    if (error) return json({ ok: false, reason: error.message });
    const pair = (a: unknown, b: unknown) => `${a}>${b}`;
    const sent = new Set<string>(), blocked = new Set<string>();
    const tos = [...new Set((lk ?? []).map((r) => String(r.to_id)))];
    for (let i = 0; i < tos.length; i += 200) {
      const chunk = tos.slice(i, i + 200);
      const { data: back } = await supabase.from("tama_likes").select("from_id,to_id").in("from_id", chunk).limit(1000);
      for (const r of back ?? []) sent.add(pair(r.from_id, r.to_id));
      const { data: bl } = await supabase.from("tama_blocks").select("blocker_id,blocked_id").in("blocker_id", chunk).limit(1000);
      for (const r of bl ?? []) blocked.add(pair(r.blocker_id, r.blocked_id));
    }
    const pending = new Map<string, number>();
    for (const r of lk ?? []) {
      const to = String(r.to_id);
      if (sent.has(pair(r.to_id, r.from_id)) || blocked.has(pair(r.to_id, r.from_id))) continue;   // もう返した・ブロックした
      pending.set(to, (pending.get(to) ?? 0) + 1);
    }
    ids = [...pending.keys()];
    title = "👋 いいねが届いています";
    textFor = (id) => `今日いいねが ${pending.get(id)}件届いています。共通点を見て、いいねを返すとトークが始まります`;
    url = "/tama/?go=talk&n=like"; tag = "tama-likes"; pref = "like";
  } else if (body.kind === "morning") {
    // 🌅 2日目の朝（2026-10-16 あおの決定：18日 11:45）：1日目（prev）にキャンパスで開いた人だけに、昨日すれ違った人数と今日の予定
    const day = String(body.day ?? ""), prev = String(body.prev ?? "");
    if (day !== todayJst || !prev) return json({ ok: true, skipped: "not the day" });
    onceKey = `morning:${todayJst}`;
    const conf = await tamasaiConf();
    const { data: vs, error } = await supabase.from("tama_visits").select("user_id").eq("day", prev).eq("on_campus", true);
    if (error) return json({ ok: false, reason: error.message });
    ids = [...new Set((vs ?? []).map((v) => String(v.user_id)))];
    const met = await metCounts(supabase, ids, prev);
    const plan = [conf?.ctTimes?.length ? `${conf.ctTimes.join("・")} にちかくタイム` : "", "18:00 に花火"].filter(Boolean).join("、");
    title = "🌅 多摩祭2日目、はじまります";
    textFor = (id) => {
      const n = met.get(id) ?? 0;
      return `${n ? `昨日は ${n}人とすれ違いました。今日もう一度すれ違えるかも。` : ""}今日も ${plan}。アプリを開いたまま回ってみてね`;
    };
    url = "/tama/?go=tamasai&n=tamasai"; tag = "tama-morning"; pref = "tamasai";
  } else {
    return json({ ok: false, reason: "bad kind" });
  }
  if (ids.length === 0) return json({ ok: true, sent: 0, targets: 0 });

  // 多摩祭の通知（recap・fsurvey）は、その日に1回だけ（公開の鍵で外から何度も呼ばれても、全員に何度も送らないように。2026-10-15 のレビューで直した）。
  // 記録の表（tama_fes_sent。tama_tamasai.sql）が無い時は、そのまま送る
  // 出店者向け（shop）は1日に2回あるので、回ごと（slot）に1回だけ
  if (body.kind === "recap" || body.kind === "fsurvey" || body.kind === "shop") onceKey = `${body.kind}:${todayJst}${body.slot ? ":" + body.slot : ""}`;
  if (onceKey) {
    const { error: onceErr } = await supabase.from("tama_fes_sent").insert({ key: onceKey });
    if (onceErr && (onceErr.code === "23505" || /duplicate/i.test(onceErr.message))) return json({ ok: true, skipped: "already sent today" });
  }

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
    const payload = JSON.stringify({ title: titleFor ? titleFor(s.id) : title, body: textFor ? textFor(s.id) : text, url, tag });
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
