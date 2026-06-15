# LIVE Operations — Storage, Smoke Test, Automation

คู่มือสำหรับสามงานที่ต้องรัน/ตั้งค่าบน Supabase จริง (ทดสอบในโหมด DEMO ไม่ได้)

---

## #2 — เก็บไฟล์ PDF ใน Supabase Storage (แทน data URL ใน DB)

โค้ดฝั่ง client พร้อมแล้ว (`uploadPdfIfNeeded()` ใน `index.html`) — เหลือตั้งค่า bucket:

1. Supabase → **Storage → New bucket** → ชื่อ `po-pdfs` → ตั้งเป็น **Public**
2. ใส่ Policy ให้ผู้ล็อกอินอัปโหลดได้ (Storage → po-pdfs → Policies):

```sql
-- อ่านไฟล์ได้ทุกคน (bucket public อยู่แล้ว) · อัปโหลด/แก้ได้เฉพาะผู้ล็อกอิน
CREATE POLICY "po_pdfs_read"   ON storage.objects FOR SELECT TO public        USING (bucket_id = 'po-pdfs');
CREATE POLICY "po_pdfs_write"  ON storage.objects FOR INSERT TO authenticated  WITH CHECK (bucket_id = 'po-pdfs');
CREATE POLICY "po_pdfs_update" ON storage.objects FOR UPDATE TO authenticated  USING (bucket_id = 'po-pdfs');
```

เมื่อออก PO + แนบ PDF ในโหมด LIVE ระบบจะอัปโหลดไฟล์ขึ้น bucket แล้วเก็บแค่ **public URL** ในคอลัมน์ `purchase_orders.pdf_url` (DB ไม่บวมจาก base64)

---

## #3 — Smoke Test RLS / RPC (รันใน SQL Editor)

> เทคนิค: จำลองผู้ใช้แต่ละฝ่ายด้วย `SET LOCAL role authenticated` + `request.jwt.claims` แล้วยืนยันว่า policy/RPC ทำงานถูก
> เปลี่ยน `<UID_xxx>` เป็น `user_id` จริงจากตาราง `user_roles` (สมัครผู้ใช้ทดสอบ 1 คนต่อฝ่ายก่อน)

```sql
-- ===== เตรียม: ดู uid ของผู้ใช้ทดสอบ =====
SELECT u.email, r.department, r.is_developer FROM auth.users u JOIN user_roles r ON r.user_id=u.id;

-- ===== TEST 1: ฝ่ายขายแก้ลูกค้าได้ / ฝ่ายจัดซื้อแก้ไม่ได้ =====
BEGIN;
  SET LOCAL role authenticated;
  SET LOCAL request.jwt.claims = '{"sub":"<UID_SALES>","role":"authenticated"}';
  INSERT INTO customers(name,lbs_qty) VALUES ('TEST ลูกค้า',1);            -- ✅ ควรสำเร็จ
ROLLBACK;

BEGIN;
  SET LOCAL role authenticated;
  SET LOCAL request.jwt.claims = '{"sub":"<UID_PURCHASING>","role":"authenticated"}';
  INSERT INTO customers(name,lbs_qty) VALUES ('TEST 2',1);                 -- ❌ ควร error: new row violates row-level security
ROLLBACK;

-- ===== TEST 2: gate ของ handoff_project (ฝ่ายเจ้าของเฟส + เงื่อนไขครบ) =====
BEGIN;
  SET LOCAL role authenticated;
  SET LOCAL request.jwt.claims = '{"sub":"<UID_PURCHASING>","role":"authenticated"}';
  -- เลือก stock ที่อยู่เฟส project → ควร error เพราะ purchasing ไม่ใช่เจ้าของเฟส
  SELECT handoff_project((SELECT id FROM projects WHERE current_phase='project' LIMIT 1));  -- ❌ ควร RAISE EXCEPTION
ROLLBACK;

-- ===== TEST 3: create_stock_multi เฉพาะฝ่ายโครงการ =====
BEGIN;
  SET LOCAL role authenticated;
  SET LOCAL request.jwt.claims = '{"sub":"<UID_SALES>","role":"authenticated"}';
  SELECT create_stock_multi(ARRAY[]::bigint[], 'STK-TEST','JOB-TEST','BOM-TEST','test', 5);  -- ❌ ควร error: เฉพาะฝ่ายโครงการ
ROLLBACK;

-- ===== TEST 4: developer ทำได้ทุกอย่าง =====
BEGIN;
  SET LOCAL role authenticated;
  SET LOCAL request.jwt.claims = '{"sub":"<UID_DEV>","role":"authenticated"}';
  UPDATE projects SET cash_flow_status='ทดสอบ' WHERE id=(SELECT id FROM projects LIMIT 1);  -- ✅ ควรสำเร็จ
ROLLBACK;
```

ผลที่คาดหวังเขียนไว้ท้ายแต่ละบรรทัด (✅ สำเร็จ / ❌ ต้อง error) — ถ้าผลตรงทุกข้อ = RLS/RPC ทำงานถูก

---

## #8 — แจ้งเตือนอัตโนมัติเมื่อใกล้ครบกำหนดส่งมอบ ≤ 15 วัน

### 8.1 Edge Function (`supabase/functions/notify-delivery/index.ts`)
ส่งเข้า Line Notify (เปลี่ยนเป็น email/Slack ได้)

```ts
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

Deno.serve(async () => {
  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const { data: due } = await sb.from("projects")
    .select("project_stock_no,name,delivery_date,current_phase")
    .neq("current_phase", "closed")
    .gte("delivery_date", new Date().toISOString().slice(0,10))
    .lte("delivery_date", new Date(Date.now()+15*864e5).toISOString().slice(0,10));
  if (!due?.length) return new Response("no alerts");

  const msg = "⚠️ ใกล้ครบกำหนดส่งมอบ (≤15 วัน):\n" +
    due.map(p => `• ${p.project_stock_no} ${p.name} — ส่ง ${p.delivery_date}`).join("\n");

  await fetch("https://notify-api.line.me/api/notify", {
    method: "POST",
    headers: { Authorization: `Bearer ${Deno.env.get("LINE_TOKEN")}`, "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ message: msg }),
  });
  return new Response(JSON.stringify({ sent: due.length }));
});
```

Deploy: `supabase functions deploy notify-delivery` + ตั้ง secret `LINE_TOKEN`

### 8.2 ตั้ง pg_cron ให้ยิงทุกเช้า 08:00 (รันใน SQL Editor)

```sql
CREATE EXTENSION IF NOT EXISTS pg_cron;
CREATE EXTENSION IF NOT EXISTS pg_net;

SELECT cron.schedule('notify-delivery-daily', '0 1 * * *',  -- 01:00 UTC = 08:00 ไทย
  $$ SELECT net.http_post(
       url := 'https://<PROJECT_REF>.functions.supabase.co/notify-delivery',
       headers := jsonb_build_object('Authorization', 'Bearer <ANON_OR_SERVICE_KEY>')
     ); $$);

-- ดู/ลบ cron: SELECT * FROM cron.job;  /  SELECT cron.unschedule('notify-delivery-daily');
```

> หน้า Dashboard ในแอปแสดง "เตือนส่งมอบ ≤ 15 วัน" อยู่แล้ว — ส่วนนี้เพิ่มการ **แจ้งเตือนเชิงรุก** (push) นอกแอป
