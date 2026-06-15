# ระบบบริหารโครงการขาย 115 kV LBS

เว็บแอปบริหาร workflow ข้ามฝ่าย **Sales → Project → Purchasing → Service → Closed** สำหรับงานขาย/ติดตั้ง LBS 115 kV
Frontend: **static HTML + React (CDN)** · Backend: **Supabase (PostgreSQL + Auth + RLS + Storage)** · Deploy: **GitHub Pages**

> ทำงาน 2 โหมด — **DEMO** (เปิดได้เลย ใช้ข้อมูลจำลองในเครื่อง) และ **LIVE** (ต่อ Supabase จริง) สลับด้วยการใส่/ไม่ใส่คีย์ Supabase ใน `index.html`

---

## 📁 ไฟล์ในโปรเจกต์ (Final)

| ไฟล์ | หน้าที่ | ต้อง deploy? |
|------|---------|:---:|
| **`index.html`** | ทั้งแอป — UI + ตรรกะ + Auth + Data layer (DEMO/LIVE) + ธีมสว่าง/มืด | ✅ |
| **`schema.sql`** | สคีมา Supabase — ตาราง, enum, trigger, RPC (`SECURITY DEFINER`), RLS, seed | ✅ (รันใน SQL Editor) |
| **`reset-clean.sql`** | ล้างข้อมูลตัวอย่างทั้งหมดก่อนใช้งานจริง (เก็บโครงสร้าง + สิทธิ์) | รันตอน go-live |
| **`USER-GUIDE.md`** | **คู่มือใช้งานแยกฝ่าย + Flow เชื่อมโยง** | อ้างอิง |
| **`LIVE-OPS.md`** | คู่มือ LIVE: ตั้ง Storage bucket (PDF), Smoke test RLS/RPC, แจ้งเตือนอัตโนมัติ (pg_cron + Edge Function) | อ้างอิง |
| **`FLOW.md`** | อธิบาย workflow ทีละฝ่าย | อ้างอิง |
| **`LINKAGE-DESIGN.md`** | สเปกการเชื่อมโยงระหว่างฝ่าย + ปุ่มต่าง ๆ | อ้างอิง |
| `*.bak` | สำรองไฟล์เวอร์ชันก่อนหน้า | ❌ ไม่ต้อง push |

**ขั้นต่ำสำหรับ deploy:** `index.html` (GitHub Pages) + `schema.sql` (รันบน Supabase)

---

## 🧭 โครงสร้างเมนู (Sidebar: เมนูแม่ + กิ่งย่อย)

- **Executive Dashboard** — KPI, คอขวดระหว่างฝ่าย, เตือนส่งมอบ ≤15 วัน
- **Sales Department** — ลูกค้าที่ยังไม่รวบรวม → กิ่งย่อย **Sales Requisition & ติดตาม PO**
- **Project Department** — รับ SR สร้าง Stock (Popup ถามจำนวน LBS) → กิ่งย่อย **Stock No.** (กล่อง Budget+BOM พับได้ + Audit timeline)
- **Purchasing Department** — ออก PO ดึงรายการ BOM (ระบุจำนวน/แยกบางส่วน, แนบ PDF) → กิ่งย่อย **BOM Delivered completed**
- **Service Department** — Inbox แผนส่งมอบ + จัดทีม + Scheduling Calendar + ลงนาม DO

---

## 🔄 Flow ใช้งานจริงโดยย่อ

1. **Sales** เพิ่มลูกค้า (มีจำนวน LBS) → ติ๊กเลือกหลายลูกค้า **รวบรวมเป็น Sales Requisition (SR)** ส่งฝ่ายโครงการ → ติดตาม PO/สัญญาในแท็บ SR
2. **Project** เลือกหลาย SR → **สร้าง Project Stock No.** (ตั้งชื่อ + ถามจำนวน LBS เป้าหมาย) → ทำ **BOM** (Epicor Code/Due/IUM/Currency/Phase) → ตรวจ LBS ตรงเป้า → **ส่ง BOM ให้จัดซื้อ** → **ส่งแผนส่งมอบให้ Service**
3. **Purchasing** เลือกรายการ BOM **ออก PO** (ระบุจำนวน/แนบ PDF) → อัปเดตสถานะจน **Delivered** ครบ → ส่งงานต่อ
4. **Service** กด **รับแผน** → จัดทีม (ปฏิทินรายเดือน) → **ลงนาม DO** → **ปิดงาน**

> การส่งงาน/ตีกลับ/รับงาน บังคับสิทธิ์ + gate ฝั่ง server ผ่าน RPC `SECURITY DEFINER` (`create_stock_multi`, `handoff_project`, `reject_project`, `ack_phase`)

---

## 1) ลองใช้แบบ DEMO (ไม่ต้องตั้งค่าอะไร)

เปิด `index.html` ผ่าน HTTP (อย่าเปิดด้วย `file://`):

```bash
npx serve -l 3000          # หรือ
python -m http.server 8000
```

เปิด `http://localhost:3000` → มุมขวาบนขึ้นป้าย **DEMO** พร้อมข้อมูลจำลองครบทุกเฟส · สลับธีมสว่าง/มืดด้วยปุ่ม 🌙/☀️ · สลับบทบาทเพื่อทดสอบสิทธิ์

---

## 2) ตั้งค่า Supabase (โหมด LIVE)

### 2.1 สร้างโปรเจกต์ + รันสคีมา
1. สร้างโปรเจกต์ที่ [supabase.com](https://supabase.com)
2. **SQL Editor** → วางเนื้อหา `schema.sql` ทั้งไฟล์ → **Run** (รันซ้ำได้ idempotent)

### 2.2 เปิด Authentication
- **Authentication → Providers → Email**: เปิดใช้งาน
- เริ่มต้นเร็ว: **ปิด** "Confirm email" เพื่อสมัครแล้วเข้าใช้ได้ทันที

### 2.3 (แนะนำ) ตั้ง Storage สำหรับไฟล์ PDF ของ PO
- **Storage → New bucket** → ชื่อ `po-pdfs` → **Public** → ใส่ policy ตาม [`LIVE-OPS.md`](LIVE-OPS.md) ข้อ #2
- ถ้าไม่ตั้ง: ระบบยังทำงานได้ แต่จะเก็บ PDF เป็น data URL ใน DB (ไม่แนะนำสำหรับ production)

### 2.3.1 🚀 Deploy ใช้งานจริง — ล้างข้อมูลตัวอย่าง
หลังทดสอบเสร็จและพร้อมเปิดใช้จริง ให้รัน **`reset-clean.sql`** ใน SQL Editor → ลบลูกค้า/SR/Stock/BOM/PO/คลัง/ฯลฯ ทั้งหมด (เก็บโครงสร้าง + `user_roles` + สิทธิ์ developer)
> หรือถ้าต้องการฐานข้อมูลว่างตั้งแต่แรก: ลบบล็อก **SEED DATA** (ข้อ 13) ใน `schema.sql` ก่อนรัน

### 2.4 เอาคีย์มาใส่ในแอป
**Project Settings → API** คัดลอก **Project URL** + **anon public key** แล้วแก้บนสุดของ `<script type="text/babel">` ใน `index.html`:

```js
const SUPABASE_URL  = "https://xxxxx.supabase.co";   // Project URL
const SUPABASE_ANON = "eyJhbGciOi...";               // anon public key (ปลอดภัยที่จะ commit — คุมด้วย RLS)
```

> ⚠️ ห้ามใส่ `service_role key` ในไฟล์นี้เด็ดขาด

### 2.5 กำหนดสิทธิ์ผู้ใช้
**Developer คนแรกตั้งไว้ให้แล้ว:** `schema.sql` มีคำสั่ง bootstrap กำหนด **`siradanai.s@precise.co.th`** เป็น `developer` อัตโนมัติ
→ แค่ **สมัครสมาชิกด้วยอีเมลนี้** ผ่านหน้า Login แล้ว **รัน `schema.sql` อีกครั้ง** (idempotent) ก็จะได้สิทธิ์ developer ทันที

เพิ่มผู้ใช้ฝ่ายอื่น (หลังเขาสมัครแล้ว) — รันใน SQL Editor:

```sql
-- ฝ่ายอื่น ๆ (sales | project | purchasing | service | executive)
INSERT INTO user_roles (user_id, department)
SELECT id, 'sales' FROM auth.users WHERE email = 'sales1@example.com';

-- เพิ่ม developer คนอื่น
INSERT INTO user_roles (user_id, department, is_developer)
SELECT id, 'developer', TRUE FROM auth.users WHERE email = 'dev2@example.com'
ON CONFLICT (user_id) DO UPDATE SET is_developer = TRUE, department = 'developer';
```

> **ผู้ใช้ใหม่ที่ยังไม่ถูกกำหนดสิทธิ์** จะเห็นหน้า **"⏳ รอผู้ดูแลอนุมัติสิทธิ์"** และใช้งานไม่ได้จนกว่าจะมี row ใน `user_roles`

### 2.6 (ทางเลือก) Smoke test + แจ้งเตือนอัตโนมัติ
ดู [`LIVE-OPS.md`](LIVE-OPS.md) — #3 สคริปต์ทดสอบ RLS/RPC, #8 ตั้ง pg_cron + Edge Function แจ้งเตือน ≤15 วัน

---

## 3) Deploy ขึ้น GitHub Pages

```bash
git init
git add index.html schema.sql reset-clean.sql README.md USER-GUIDE.md FLOW.md LINKAGE-DESIGN.md LIVE-OPS.md .gitignore
git commit -m "115kV LBS project workflow"
git branch -M main
git remote add origin https://github.com/<user>/<repo>.git
git push -u origin main
```

จากนั้นที่ repo บน GitHub → **Settings → Pages** → Source = **Deploy from a branch** → Branch = `main` / `/ (root)` → **Save**
รอสักครู่ แอปออนไลน์ที่ `https://<user>.github.io/<repo>/`

> ใส่ `SUPABASE_URL` / `SUPABASE_ANON` ใน `index.html` ก่อน push (ไม่งั้นจะเป็นโหมด DEMO) · ไฟล์ `.bak` ไม่ต้อง push

---

## 4) บทบาท & สิทธิ์ (RLS)

| บทบาท | สิทธิ์โดยสรุป |
|-------|--------------|
| `developer` | ทำได้ทุกอย่างทุกตาราง |
| `sales` | จัดการลูกค้า + Sales Requisition + ติดตาม PO/สัญญา |
| `project` | สร้าง Project Stock, BOM, ส่ง BOM, ส่งแผน Service, ส่งงานต่อ |
| `purchasing` | ออก PO (ดึงรายการ BOM) + อัปเดตสถานะการจัดหา |
| `service` | รับแผน + จัดทีม/ตารางคิว + ลงนาม DO + ปิดงาน |
| `executive` | ดูภาพรวม (อ่านอย่างเดียว) |

> โหมด LIVE: บทบาทถูกล็อกตามตาราง `user_roles` (สลับเองไม่ได้) · โหมด DEMO: สลับบทบาทอิสระเพื่อทดสอบ

---

## 5) ฟีเจอร์เด่น

- โมเดล 2 ชั้น: **ลูกค้า → Sales Requisition → Project Stock** (รวมหลาย SR ต่อ Stock)
- **BOM แบบ Epicor** (THB/USD + อัตราแลกเปลี่ยน → Total เป็นบาท) + ตรวจ LBS เทียบเป้าหมาย
- **PO ดึงรายการ BOM** ระบุจำนวนต่อรายการ (แยกบางส่วนได้) + แนบไฟล์ PDF (เปิดดูได้ฝั่ง Project)
- **Audit Timeline** ประวัติส่งงาน/ตีกลับ + **Scheduling Calendar** ทีม Service รายเดือน
- **Export CSV**, **ค้นหา/กรอง**, **ธีมสว่าง/มืด**, **Optimistic update** (UI ตอบสนองไว)

**📖 วิธีใช้งานทีละฝ่าย + Flow เชื่อมโยง → ดู [`USER-GUIDE.md`](USER-GUIDE.md)**
ดูรายละเอียด workflow ใน [`FLOW.md`](FLOW.md) และการเชื่อมโยงใน [`LINKAGE-DESIGN.md`](LINKAGE-DESIGN.md)
