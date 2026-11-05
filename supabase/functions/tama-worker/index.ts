// 仕事の列（tama_jobs）を片付ける（2026-11-05。supabase/tama_safety.sql と一緒に）。
// Supabase ダッシュボード → Edge Functions → 新規関数 "tama-worker" として、このファイルの内容をそのまま貼り付けてデプロイ。Verify JWT はオンのまま。
// 起こすのは pg_cron（1分ごと・やる仕事がある時だけ。公開の鍵で呼ぶ）。列を片付けるだけなので、だれが起こしても困らない。
//
// 仕事の種類：
//   report … 通報が来た（tama_reports のトリガーが積む）→ 運営にメールで知らせる。
//            Secrets：RESEND_API_KEY（https://resend.com の API キー）・OPS_EMAIL（運営のアドレス）・MAIL_FROM（任意。無ければ Resend の試し用の送り元）
//            Secrets が無い間は送らずに「済み」にする（何度も起こさないため）。中身のやりとりの写しはメールに入れない
//   push   … 通知を送る（閉じている間のすれ違いなど、サーバーが決めた通知）。payload をそのまま send-match-push に渡す（強い鍵で呼ぶ）
// 1回に50件まで。失敗は5回まで（tries）やり直す

import { createClient } from "npm:@supabase/supabase-js@2";

const URL_ = Deno.env.get("SUPABASE_URL")!;
const SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const RESEND = Deno.env.get("RESEND_API_KEY") ?? "";
const OPS = Deno.env.get("OPS_EMAIL") ?? "";
const FROM = Deno.env.get("MAIL_FROM") ?? "ちかく 運営 <onboarding@resend.dev>";
const json = (o: unknown) => new Response(JSON.stringify(o), { headers: { "Content-Type": "application/json" } });

type Job = { id: number; kind: string; payload: Record<string, unknown>; tries: number };

async function doReport(p: Record<string, unknown>): Promise<string | null> {
  if (!RESEND || !OPS) return "メールの設定がありません（RESEND_API_KEY・OPS_EMAIL）";
  const contact = p.contact === true;
  const subject = contact ? "【ちかく】運営への連絡が届きました" : p.hidden ? "【ちかく】通報：3人以上から通報された人を自動で隠しました" : "【ちかく】通報が届きました";
  const text = [
    contact ? "コミュニティの画面から、運営への連絡が届きました。" : "通報が届きました。24時間以内に確かめてください。",
    "",
    `理由：${p.reason ?? ""}`,
    p.detail ? `くわしく：${p.detail}` : "",
    `通報した人の id（先頭8文字）：${p.reporter ?? ""}`,
    p.target ? `通報された人の id（先頭8文字）：${p.target}` : "",
    contact ? "" : `この人への30日の通報：${p.count ?? 0}人`,
    p.hidden ? "→ 3人以上なので、近くの人・地図・すれ違いから自動で隠しました。確かめて、戻す時は select tama_unhide('id'); 止める時は select tama_ban('id', '理由');" : "",
    "",
    "中身（やりとりの写し）は、Supabase の SQL Editor で supabase/tama_admin.sql の一覧を開いて見てください。",
  ].filter((x) => x !== "").join("\n");
  const r = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: { "Authorization": `Bearer ${RESEND}`, "Content-Type": "application/json" },
    body: JSON.stringify({ from: FROM, to: [OPS], subject, text }),
  });
  if (!r.ok) return `メールを送れません（${r.status} ${(await r.text()).slice(0, 120)}）`;
  return null;
}

async function doPush(p: Record<string, unknown>): Promise<string | null> {
  const r = await fetch(`${URL_}/functions/v1/send-match-push`, {
    method: "POST",
    headers: { "Authorization": `Bearer ${SERVICE}`, "Content-Type": "application/json" },
    body: JSON.stringify(p),
  });
  if (!r.ok) return `通知を送れません（${r.status}）`;
  return null;   // 送り先が無い・その種類をオフにしている、は失敗にしない（send-match-push が記録する）
}

Deno.serve(async () => {
  const admin = createClient(URL_, SERVICE, { auth: { persistSession: false, autoRefreshToken: false } });
  const { data: jobs, error } = await admin.from("tama_jobs").select("id,kind,payload,tries").is("done_at", null).lt("tries", 5).order("id").limit(50);
  if (error) return json({ ok: false, error: error.message });
  let done = 0, failed = 0;
  for (const j of (jobs ?? []) as Job[]) {
    // 先に「やっている」印を付ける（1分ごとの呼び出しが重なっても、同じ仕事を2回しない）
    const { data: claimed } = await admin.from("tama_jobs").update({ tries: j.tries + 1 }).eq("id", j.id).eq("tries", j.tries).is("done_at", null).select("id");
    if (!claimed || !claimed.length) continue;
    let err: string | null = null;
    try {
      err = j.kind === "report" ? await doReport(j.payload ?? {}) : j.kind === "push" ? await doPush(j.payload ?? {}) : "知らない種類";
    } catch (e) { err = String(e).slice(0, 200); }
    // メールの設定が無い時は、やり直さずに済みにする
    const finish = !err || /設定がありません|知らない種類/.test(err) || j.tries + 1 >= 5;
    await admin.from("tama_jobs").update({ err, ...(finish ? { done_at: new Date().toISOString() } : {}) }).eq("id", j.id);
    if (err) { failed++; console.warn("[tama-worker]", j.kind, j.id, err); } else done++;
  }
  return json({ ok: true, done, failed });
});
