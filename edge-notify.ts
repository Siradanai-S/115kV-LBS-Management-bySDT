// =====================================================================
//  Supabase Edge Function: notify
//  รับ JSON จากแอป (Setting → การแจ้งเตือน) แล้วส่งจริงผ่าน LINE Messaging API + Email (Resend)
//
//  Deploy:
//    1) ติดตั้ง Supabase CLI แล้ว login + link โปรเจกต์
//    2) คัดลอกไฟล์นี้ไปที่  supabase/functions/notify/index.ts
//    3) ตั้ง secret สำหรับอีเมล (ถ้าใช้ Email):
//         supabase secrets set RESEND_API_KEY=re_xxx  NOTIFY_EMAIL_FROM="LBS <noreply@yourdomain.com>"
//    4) supabase functions deploy notify --no-verify-jwt
//    5) เอา URL (https://<project>.supabase.co/functions/v1/notify) ไปกรอกใน Setting → Edge Function URL
//
//  หมายเหตุ: LINE channel access token ส่งมาจากแอป (เก็บในตาราง notif_settings ที่อ่านได้เฉพาะ Developer)
//            ถ้าต้องการเก็บฝั่ง server ล้วน ๆ ให้ย้ายไปเป็น secret แล้วอ่านจาก Deno.env แทน body.line.token
// =====================================================================

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST")  return json({ error: "POST only" }, 405);

  let body: any;
  try { body = await req.json(); } catch { return json({ error: "invalid JSON" }, 400); }

  const subject: string = body.subject || "แจ้งเตือนระบบ 115 kV LBS";
  const message: string = body.message || "";
  const text = `${subject}\n${message}`.trim();
  const results: Record<string, unknown> = {};

  // ---- LINE Messaging API (push) ----
  const line = body.line || {};
  if (line.enabled && line.token && Array.isArray(line.to) && line.to.length) {
    results.line = [];
    for (const to of line.to) {
      try {
        const r = await fetch("https://api.line.me/v2/bot/message/push", {
          method: "POST",
          headers: { "Content-Type": "application/json", Authorization: `Bearer ${line.token}` },
          body: JSON.stringify({ to, messages: [{ type: "text", text }] }),
        });
        (results.line as unknown[]).push({ to, status: r.status, ok: r.ok });
      } catch (e) {
        (results.line as unknown[]).push({ to, error: String(e) });
      }
    }
  }

  // ---- Email (Resend) ----
  const email = body.email || {};
  const RESEND = Deno.env.get("RESEND_API_KEY");
  const FROM = Deno.env.get("NOTIFY_EMAIL_FROM") || "LBS <onboarding@resend.dev>";
  if (email.enabled && Array.isArray(email.to) && email.to.length) {
    if (!RESEND) {
      results.email = { error: "RESEND_API_KEY not set (supabase secrets set RESEND_API_KEY=...)" };
    } else {
      try {
        const r = await fetch("https://api.resend.com/emails", {
          method: "POST",
          headers: { "Content-Type": "application/json", Authorization: `Bearer ${RESEND}` },
          body: JSON.stringify({
            from: FROM, to: email.to, subject,
            text: message,
            html: `<div style="font-family:Tahoma,sans-serif"><h3 style="margin:0 0 8px">${escapeHtml(subject)}</h3><pre style="font-family:Tahoma,sans-serif;white-space:pre-wrap;margin:0">${escapeHtml(message)}</pre></div>`,
          }),
        });
        results.email = { status: r.status, ok: r.ok };
      } catch (e) {
        results.email = { error: String(e) };
      }
    }
  }

  return json({ ok: true, event: body.event, results });
});

function json(obj: unknown, status = 200) {
  return new Response(JSON.stringify(obj), { status, headers: { ...CORS, "Content-Type": "application/json" } });
}
function escapeHtml(s: string) {
  return String(s).replace(/[&<>]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" }[c] as string));
}
