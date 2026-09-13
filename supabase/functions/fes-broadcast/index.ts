// Supabase ダッシュボード → Edge Functions → 新規関数 "fes-broadcast" として
// このファイルの内容をそのまま貼り付けてデプロイしてください。
//
// 学園祭版の「時間で全員に送る通知」。fes_scheduled_pushes に登録された通知のうち、
// 送る時刻を過ぎたものを、学園祭版の参加者（fes_profiles）のうち通知を許可している人全員に送る。
// pg_cron が1分ごとにこの関数を呼ぶ（supabase/fes_notifications.sql）。
//
// Secrets は send-match-push と同じ VAPID_PUBLIC_KEY / VAPID_PRIVATE_KEY を使う（プロジェクト共通なので追加設定は不要）。
// 動いているマッチ通知を壊さないよう、send-match-push には一切手を入れず別の関数にしている。

import { createClient } from "npm:@supabase/supabase-js@2";
import webpush from "npm:web-push@3.6.7";

const json = (obj: unknown, status = 200) =>
  new Response(JSON.stringify(obj), { status, headers: { "Content-Type": "application/json" } });

Deno.serve(async () => {
  const vapidPublicKey = Deno.env.get("VAPID_PUBLIC_KEY") ?? "";
  const vapidPrivateKey = Deno.env.get("VAPID_PRIVATE_KEY") ?? "";
  if (!vapidPublicKey || !vapidPrivateKey) {
    console.error("[fes-broadcast] VAPID_PUBLIC_KEY / VAPID_PRIVATE_KEY が Secrets に設定されていません");
    return json({ ok: false, reason: "vapid not configured" });
  }
  webpush.setVapidDetails("mailto:support@example.com", vapidPublicKey, vapidPrivateKey);

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  const { data: due, error } = await supabase
    .from("fes_scheduled_pushes")
    .select("id")
    .is("sent_at", null)
    .lte("send_at", new Date().toISOString())
    .order("send_at");
  if (error) {
    console.error("[fes-broadcast] fes_scheduled_pushes 取得エラー:", error.message);
    return json({ ok: false, reason: error.message });
  }
  if (!due || due.length === 0) return json({ ok: true, sent: 0 });

  // 送り先＝学園祭版に登録した人のうち、通知を許可している人
  const { data: profs } = await supabase.from("fes_profiles").select("id");
  const ids = (profs ?? []).map((p) => p.id);
  const subs: { id: string; subscription: webpush.PushSubscription }[] = [];
  for (let i = 0; i < ids.length; i += 200) {
    const { data } = await supabase
      .from("push_subscriptions")
      .select("id,subscription")
      .in("id", ids.slice(i, i + 200));
    subs.push(...(data ?? []));
  }

  const results = [];
  for (const row of due) {
    // 先に「送信済み」にしてから送る（1分ごとの呼び出しが重なっても、同じ通知を二重に送らないように）
    const { data: claimed } = await supabase
      .from("fes_scheduled_pushes")
      .update({ sent_at: new Date().toISOString() })
      .eq("id", row.id)
      .is("sent_at", null)
      .select("id,title,body,url")
      .maybeSingle();
    if (!claimed) continue;

    const payload = JSON.stringify({
      title: claimed.title,
      body: claimed.body,
      url: claimed.url || "/fes/",
      tag: "chikaku-fes-" + claimed.id,
    });

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

    await supabase.from("fes_scheduled_pushes").update({ sent_count: sent }).eq("id", claimed.id);
    console.log("[fes-broadcast] 送信", claimed.id, sent, "/", subs.length);
    results.push({ id: claimed.id, sent, targets: subs.length });
  }

  return json({ ok: true, results });
});
