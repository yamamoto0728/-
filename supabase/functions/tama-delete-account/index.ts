// アカウントの削除（2026-11-03。アプリ化の審査：Apple 5.1.1(v)・Google のアカウント削除。ゲスト（匿名）のアカウントも対象）。
// Supabase ダッシュボード → Edge Functions → 新規関数 "tama-delete-account" として、このファイルの内容をそのまま貼り付けてデプロイ。
// 環境変数は要りません（SUPABASE_URL と SUPABASE_SERVICE_ROLE_KEY は Supabase が自動で入れる）。Verify JWT はオンのまま。
//
// 呼ぶのはアプリ（設定 → アカウントを削除）。アプリは先に leaveAll()（本人の権限でプロフィール・トーク・友達・時間割・コミュニティを消す）を動かしてから呼ぶ。
//   1. 呼んだ人を確かめる
//   2. 本人の権限で消しきれない表の残り（相手が書いた行など）を、強い鍵で消す。表や列が無くても止まらない
//   3. ログインの記録（auth.users）を消す
// 利用停止の記録（tama_bans・tama_ban_devices・tama_devices）は消さない：削除が停止逃れの道具にならないように（プライバシーポリシーに書いてある）
// 返すもの：{ ok: true } か { ok: false, error }（not_signed_in・failed）

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
  const id = me.id;

  // 2. 残りを消す（[表, 列…]。どれか1つでも本人なら消す）。失敗しても次へ進む
  const rest: [string, string[]][] = [
    ["tama_profiles", ["id"]], ["tama_private", ["id"]], ["tama_locs", ["id"]], ["tama_presence", ["id"]],
    ["tama_timetable", ["id"]], ["tama_loc_shares", ["owner_id", "friend_id"]], ["tama_likes", ["from_id", "to_id"]],
    ["tama_encounters", ["owner_id", "other_id"]], ["tama_friends", ["from_id", "to_id"]], ["tama_room_members", ["user_id"]],
    ["tama_checkins", ["user_id"]], ["tama_paywall", ["user_id"]],
  ];
  for (const [table, cols] of rest) {
    for (const col of cols) {
      const { error } = await admin.from(table).delete().eq(col, id);
      if (error && !/does not exist|schema cache/i.test(error.message)) console.warn("[tama-delete-account]", table, col, error.message);
    }
  }

  // 3. ログインの記録
  const { error: e } = await admin.auth.admin.deleteUser(id);
  if (e) { console.error("[tama-delete-account] delete", e.message); return reply({ ok: false, error: "failed" }); }
  console.log("[tama-delete-account] ok", id.slice(0, 8));
  return reply({ ok: true });
});
