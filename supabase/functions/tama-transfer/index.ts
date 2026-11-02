// Web 版からアプリへの引き継ぎ（2026-11-02）。supabase/tama_transfer.sql を先に実行してください。
// Supabase ダッシュボード → Edge Functions → 新規関数 "tama-transfer" として、このファイルの内容をそのまま貼り付けてデプロイ。
// 環境変数は要りません（SUPABASE_URL と SUPABASE_SERVICE_ROLE_KEY は Supabase が自動で入れる）。
//
// 呼ぶのはアプリだけ：メールのコードでログインした直後の、まだ何も使っていないアカウントが { code } を送る。
//   1. 呼んだ人を確かめる（メールでログインしていること）
//   2. tama_transfer_check でコードを確かめて「使った」にする → Web 版のアカウントの ID が返る
//   3. 呼んだ人（いまできたばかりのアカウント）を消して、そのメールを Web 版のアカウントに付ける（確認ずみとして）
//   4. Web 版のアカウントに入るための使い捨ての印（token_hash）を返す → アプリが verifyOtp({ token_hash, type: "magiclink" }) でログイン
// 返すもの：{ ok: true, token_hash } か { ok: false, error }（error は tama_transfer.sql の説明と、not_signed_in・need_email・failed・relogin）

import { createClient } from "npm:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};
const reply = (obj: unknown, status = 200) =>
  new Response(JSON.stringify(obj), { status, headers: { ...corsHeaders, "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return reply({ ok: false, error: "failed" }, 405);

  const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  // 1. 呼んだ人
  const jwt = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  const { data: got } = await admin.auth.getUser(jwt);
  const me = got?.user;
  if (!me) return reply({ ok: false, error: "not_signed_in" });
  const email = (me.email ?? "").toLowerCase();
  if (me.is_anonymous || !email || !me.email_confirmed_at) return reply({ ok: false, error: "need_email" });

  let code = "";
  try { code = String((await req.json())?.code ?? "").slice(0, 40); } catch { /* 空のまま */ }
  if (!code) return reply({ ok: false, error: "bad_code" });

  // 2. コードを確かめる（違う・時間切れ・回数オーバー・もう使い始めたアカウント、はここで止まる）
  const { data: chk, error: e1 } = await admin.rpc("tama_transfer_check", { p_code: code, p_new: me.id });
  if (e1) { console.error("[tama-transfer] check", e1.message); return reply({ ok: false, error: "failed" }); }
  if (!chk?.ok) return reply({ ok: false, error: chk?.error ?? "failed" });
  const oldId = String(chk.uid);

  // 3. いまのアカウントを消して、メールを Web 版のアカウントへ（同じメールは2つのアカウントに付けられないので、先に消す）
  const { error: e2 } = await admin.auth.admin.deleteUser(me.id);
  if (e2) {
    console.error("[tama-transfer] delete", e2.message);
    await admin.rpc("tama_transfer_undo", { p_code: code });
    return reply({ ok: false, error: "failed" });
  }
  const { error: e3 } = await admin.auth.admin.updateUserById(oldId, { email, email_confirm: true });
  if (e3) {
    // ここで失敗すると、いまのアカウントは消えている。コードは戻すので、アプリはもう一度メールでログインしてやり直す
    console.error("[tama-transfer] update", e3.message);
    await admin.rpc("tama_transfer_undo", { p_code: code });
    return reply({ ok: false, error: "relogin" });
  }

  // 4. Web 版のアカウントに入るための印（メールは送らない）
  const { data: link, error: e4 } = await admin.auth.admin.generateLink({ type: "magiclink", email });
  const tokenHash = link?.properties?.hashed_token;
  if (e4 || !tokenHash) {
    // メールはもう Web 版のアカウントに付いているので、同じメールでログインし直せば引き継いだアカウントに入れる
    console.error("[tama-transfer] link", e4?.message);
    return reply({ ok: false, error: "relogin" });
  }
  console.log("[tama-transfer] ok", me.id.slice(0, 8), "->", oldId.slice(0, 8));
  return reply({ ok: true, token_hash: tokenHash });
});
