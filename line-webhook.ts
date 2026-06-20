// =====================================================================
//  Supabase Edge Function: line-webhook
//  ตัวช่วย "ดัก groupId / userId / roomId" ของ LINE Messaging API แบบง่าย
//  เมื่อบอทถูกเชิญเข้ากลุ่ม หรือมีคนพิมพ์ในกลุ่ม → ฟังก์ชันนี้จะ
//    1) ตอบ id กลับเข้าแชททันที (เห็นใน LINE เลย ไม่ต้องเปิด log)
//    2) console.log ไว้ดูใน Supabase function logs ด้วย
//  เอา groupId (Cxxxx...) ที่ได้ ไปวางในช่อง "ส่งถึง" ของ Setting → การแจ้งเตือน
//
//  Deploy (ใช้ครั้งเดียวเพื่อเอา id ก็พอ แล้วจะปิดทีหลังก็ได้):
//    1) คัดลอกไฟล์นี้ไปที่  supabase/functions/line-webhook/index.ts
//    2) ตั้ง secret ของ channel access token (ตัวเดียวกับที่ใช้ส่งแจ้งเตือน):
//         supabase secrets set LINE_CHANNEL_ACCESS_TOKEN=xxxxx
//    3) supabase functions deploy line-webhook --no-verify-jwt
//    4) เอา URL  https://<project>.supabase.co/functions/v1/line-webhook
//       ไปวางที่ LINE Developers Console → Messaging API → Webhook URL → เปิด "Use webhook"
//    5) เปิดให้บอทเข้ากลุ่มได้ (OA Manager) → เชิญบอทเข้ากลุ่ม → พิมพ์ "id" ในกลุ่ม
//       → บอทจะตอบ groupId กลับมา ✅
//
//  หมายเหตุ: เป็นเครื่องมือชั่วคราว จึงไม่ได้ตรวจ x-line-signature
//            (ถ้าต้องการความปลอดภัยเต็มรูปแบบ ค่อยเพิ่มการ verify ด้วย channel secret)
// =====================================================================

const TOKEN = Deno.env.get("LINE_CHANNEL_ACCESS_TOKEN") || "";

Deno.serve(async (req) => {
  if (req.method === "GET") return new Response("line-webhook ok", { status: 200 });   // ไว้ทดสอบว่า URL ใช้ได้
  if (req.method !== "POST") return new Response("ok", { status: 200 });

  let body: any = {};
  try { body = await req.json(); } catch { /* ignore */ }
  const events: any[] = Array.isArray(body.events) ? body.events : [];

  for (const ev of events) {
    const src = ev.source || {};
    const kind = src.type || "unknown";                       // 'group' | 'room' | 'user'
    const id = src.groupId || src.roomId || src.userId || "(no id)";
    const label = src.groupId ? "groupId" : src.roomId ? "roomId" : "userId";
    console.log(`[LINE ${ev.type}] ${kind} → ${label}: ${id}`);

    // ตอบ id กลับเข้าแชท (ต้องมี replyToken + token) — เห็นใน LINE ทันที
    const replyToken = ev.replyToken;
    if (replyToken && TOKEN) {
      const text = src.groupId
        ? `✅ groupId ของกลุ่มนี้คือ:\n${src.groupId}\n\nนำไปวางในช่อง “ส่งถึง” ที่หน้า Setting → การแจ้งเตือน`
        : src.roomId
        ? `roomId: ${src.roomId}`
        : `userId: ${src.userId}`;
      try {
        await fetch("https://api.line.me/v2/bot/message/reply", {
          method: "POST",
          headers: { "Content-Type": "application/json", Authorization: `Bearer ${TOKEN}` },
          body: JSON.stringify({ replyToken, messages: [{ type: "text", text }] }),
        });
      } catch (e) { console.log("reply error:", String(e)); }
    }
  }

  // LINE ต้องการ HTTP 200 เสมอ
  return new Response(JSON.stringify({ ok: true }), { status: 200, headers: { "Content-Type": "application/json" } });
});
