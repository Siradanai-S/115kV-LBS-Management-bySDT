# HANDOFF — บริบทโครงการครบถ้วน (สำหรับเริ่ม session ใหม่)

> อ่านไฟล์นี้ก่อนแก้งานต่อ — สรุปทุกอย่างที่จำเป็นเพื่อทำงานต่อได้ทันทีโดยไม่ต้องถามซ้ำ

## 1) ภาพรวม
- **ระบบ:** บริหารโครงการขาย/ติดตั้ง **115 kV LBS** — workflow ข้ามฝ่าย Sales → Project → Purchasing → Service → Closed + คลังสินค้าจริง
- **สถาปัตยกรรม:** Single-file **`index.html`** = React 18 (CDN) + Babel standalone + Tailwind (CDN, remap palette) + SheetJS (CDN) · Backend = **Supabase** (Postgres + Auth + RLS + Storage) · Deploy = **GitHub Pages**
- **2 โหมด:** ใส่คีย์ Supabase = **LIVE** / ไม่ใส่ = **DEMO** (ข้อมูลจำลองในตัว `seedDemo()`)
- **Working dir:** `D:\Claude Code.md\6. ระบบการบริหารคลังสินค้าแบบแยกโครงการ`
- **ภาษา UI/สื่อสาร:** ไทย

## 2) Supabase LIVE (ตั้งค่าแล้วใน index.html)
- URL: `https://ptdoaxhjryypjsxeifak.supabase.co`
- Key (publishable, public-safe): `sb_publishable_FKF357m9Egvt1X3gO8eyLQ_oTp92QtD` (อยู่ในตัวแปร `SUPABASE_URL`/`SUPABASE_ANON` บนสุดของ `<script type="text/babel">`)
- **Developer/เจ้าของ:** `siradanai.s@precise.co.th` (bootstrap เป็น developer ใน schema.sql ข้อ 14)
- ก่อนใช้ LIVE: รัน `schema.sql` ทั้งไฟล์บน Supabase นี้ก่อน (idempotent) · ถ้าจะทดสอบ DEMO ให้ตั้งคีย์เป็น `""` ชั่วคราวแล้วใส่คืน

## 3) ไฟล์ในโปรเจกต์
| ไฟล์ | หน้าที่ |
|---|---|
| `index.html` | ทั้งแอป (UI+logic+data layer DEMO/LIVE) — ~205KB |
| `schema.sql` | สคีมา Supabase **โครงสร้างล้วน**: ตาราง/enum/trigger/RPC/RLS/bootstrap dev — **idempotent, ไม่แตะ/ไม่สร้างข้อมูล** (รันซ้ำตอนอัปเดตได้ปลอดภัย) |
| `seed-demo.sql` | **ข้อมูลตัวอย่าง (DEMO เท่านั้น)** — แยกออกจาก schema · รันเฉพาะบน DB เปล่าเพื่อสาธิต · **ห้ามรันบน production** |
| `reset-clean.sql` | TRUNCATE ข้อมูลตัวอย่างก่อน go-live (เก็บโครงสร้าง+user_roles+สิทธิ์ dev) |
| `README.md` | สรุป + วิธี deploy |
| `USER-GUIDE.md` | คู่มือใช้งานแยกฝ่าย + Flow เชื่อมโยง |
| `LIVE-OPS.md` | #2 Storage bucket PDF · #3 smoke-test RLS · #8 pg_cron+Edge Function แจ้งเตือน |
| `FLOW.md`, `LINKAGE-DESIGN.md` | เอกสาร flow เดิม |
| `*.bak` | สำรองเวอร์ชันก่อน (gitignore แล้ว ไม่ push) |
- **Deploy ขั้นต่ำ:** `index.html` (Pages) + `schema.sql` (Supabase)

## 4) โมเดลข้อมูล (ความสัมพันธ์)
```
customers (มี lbs_qty)  --sr_id-->  sales_requisitions  --stock_id-->  projects (Project Stock)
projects 1—* bom_items (คอลัมน์ Epicor: epicor_code/description/category/due_date/ium/qty/currency/unit_cost/fx_rate/project_phase/po_status)
projects 1—* purchase_orders (po.lines = jsonb [{bom_id, qty}] · pdf_url · status)
projects 1—* department_tasks (ฝ่ายขายผูก customer_id) · 1—* service_plans · *—* service_schedule(member)
service_team · handoff_log(audit) · user_roles · inventory_moves(epicor_code, project_id=null คือคลังกลาง, type IN/OUT, reason, po_no, qty)
```
- **1 SR = หลายลูกค้า · 1 Project Stock = หลาย SR** (รวม 2 ชั้น)
- **target_lbs** บน projects = จำนวน LBS เป้าหมาย (ถามตอนสร้าง) ใช้ reconcile กับยอด LBS ใน BOM
- **PO/สัญญา ติดตามราย "ลูกค้า"** — `customers.cust_po_no` + `customers.contract_status` (ย้ายจากระดับ SR เดิม → แก้รายลูกค้าในตารางเส้นเทาที่หน้า Sales Requisition) · `customers.term_of_payment` (เงื่อนไขชำระเงิน) · ฟอร์มเพิ่มลูกค้า: **สถานที่ติดตั้งกดเพิ่มได้หลายแห่ง** (เก็บใน `location` คั่นด้วย " / ")
- **BOM หลายครั้ง/รอบต่อ Stock** — `bom_items.round` (int, ครั้งที่) + `bom_items.is_sent` (bool ส่งจัดซื้อแยกรายครั้ง) · ชื่อแสดง (review v3) = `BOM-{project_stock_no} (ครั้งN)` (`roundName`) · การ์ด `BomRoundCard` **พับได้ เริ่มต้นซ่อน** (state `show`) · `project.bom_status` เลิกเป็นแหล่งจริง → derive ด้วย `bomSent()`/`bomStatusOf()`; gate project→purchasing = ทุก bom_items.is_sent=true
- **Currency BOM (review v3):** `CURRENCY=['THB','USD','EUR']` · `lineTHB`/แสดงผลรองรับ EUR (`curSym`) · เลือก USD/EUR → **auto-fetch เรตปัจจุบัน** `fetchFxToTHB()` (open.er-api.com, ไม่ใช้ key) เติมช่อง FX + ปุ่ม 🔄 ดึงซ้ำ + แก้มือทับได้ · ล่ม/CORS → `FX_FALLBACK`
- **Budget card (review v3):** หัวข้อ = `Project Budget {stock_no}` · ลบช่อง Margin%/กำไรเป็นเงิน/กระแสเงินสด (คอลัมน์ DB ยังอยู่) เหลือ งบประมาณรวม + มูลค่าวัสดุ BOM
- **Sales SR (review v3):** 2 กล่อง (รอสร้าง/สร้างแล้ว) พับได้ เริ่มต้นซ่อน · **ProjectInventory** การ์ดคลังต่อ Stock เริ่มต้นซ่อน
- **Purchasing PO (review v3):** ฟอร์มออก PO เริ่มเลข PO **ว่าง** (เลิก auto-gen) → บังคับกรอกเลข PO เองก่อนบันทึก (ปุ่ม disabled ถ้าว่าง)
- **(fix) จอขาวตอนเบิก SR:** commit ลบ dead code เผลอลบ `WithdrawSR`+`PLAN_STATUS` (ProjectInventory ใช้อยู่) → กู้กลับแล้ว
- **WithdrawSR แยกต่อลูกค้า (review v4):** popup ใหญ่ (max-w-5xl) · เลือกลูกค้าใน SR ได้หลายเจ้า → กรอกจำนวนเบิกแยกต่อลูกค้า (cap = onhand − ที่ลูกค้าอื่นจอง) → กดบันทึก = สร้างใบเบิก **1 ใบ/ลูกค้า** (`service_plans.cust_id` ใหม่ใน schema) wd_no = `WD-...-i` ถ้าหลายเจ้า · `handleWithdrawSR` รับ `payload.allocations[]` · `ServiceJob` โชว์ลูกค้าเฉพาะใบ (`pl.cust_id`)
- **UI อื่น (review v4):** BomRoundCard คอลัมน์ PO โชว์ PO No. จาก `posCovering` · ทุก modal ใหญ่ขึ้น (PoModal 4xl · create-stock/RowEditor 2xl · day-view xl)
- **LINE webhook (review v3):** `line-webhook.ts` ยกเลิกการตอบ groupId กลับเข้าแชท (ได้ id แล้ว: `C30dde10e5b1d4ce984a85016b79204cd`) เหลือ log เงียบ ๆ + ตอบ 200
- **Serial LVB/OM ของ BOM** — `bom_items.serial_lvb` + `serial_om` (กรอกในฟอร์ม BOM **เฉพาะเมื่อ Category=LBS**)

## 5) ฟีเจอร์ที่ทำเสร็จแล้ว (ทั้งหมด)
- Sidebar เมนูแม่ + **กิ่งย่อย**: Sales→[SR & ติดตาม PO] · Project→[Stock No.] · Purchasing→[BOM Delivered completed] · + Inventory + Setting(dev)
- **Sales:** เพิ่มลูกค้า(จัดกลุ่มตามประเภท, หน้าหลักโชว์เฉพาะที่ยังไม่รวบรวม) → ติ๊กรวบรวมเป็น SR → แท็บติดตาม **PO/สัญญารายลูกค้า** (2 กล่อง · ตารางเส้นกริดเทา แก้ `cust_po_no`/`contract_status` ราย row)
- **Project:** Inbox SR → Popup สร้าง Stock (ตั้งชื่อ+เลขเอง + **ถาม LBS เป้าหมาย**) → แท็บ Stock No. การ์ดพับได้ (Budget/LBS reconcile/**BOM หลายครั้ง**/ส่ง BOM รายครั้ง/ส่งแผน Service/**Audit timeline**) · ปุ่ม "เพิ่ม Material List (BOM) ครั้งใหม่" → การ์ด `BomRoundCard` ต่อครั้ง (ครั้ง1/ครั้ง2…) ส่งจัดซื้อแยกครั้ง
- **Purchasing:** การ์ด BOM พับได้ แสดงคอลัมน์ครบ → ออก PO **เลือกรายการ+ระบุจำนวน(แยกบางส่วน)**+เลขที่ PO เอง+**แนบ PDF** → po_status แจ้งกลับ · แท็บ Delivered completed
- **Service:** Inbox แผนส่งมอบ(กดรับ) · เช็กลิสต์+**ลงนาม DO** · ทีม+**Scheduling Calendar** รายเดือน(คลิกดู event)
- **Inventory (#3):** 2 ระดับ คลังกลาง↔Project Stock · **รับตาม PO**(รับบางส่วน→อัปเดต po_status Delivered) · บันทึกเอง(รับ/เบิกมีประเภท/**โอนกลาง→โครงการ**) · **บล็อกติดลบ**(client + DB trigger `inv_block_negative`)
- **Branding:** โลโก้ PRECISE (SVG ริบบิ้นสาน `BrandMark`/`Brand`) · ชื่อ "115 kV Load Break Switch / Project Management / Dev Mr. Siradanai Sirisunthorn" (Sidebar + Login)
- **Service flow แบบขั้นตอน (auto-advance) [end-to-end]:** `ServiceJob` 3 ขั้น + ใบรับประกัน · โชว์ลูกค้าใน SR (`pl.sr_id`) — (1) **รับงาน** `handleSvcReceive` + ปริ้น `printServiceDoc('wd'|'do'|'handover'|'warranty')` (2) **ปฏิบัติงาน**: ทีม 1-2 + actual Start/End + **เช็กลิสต์ `SVC_CHECK`** (ตรวจรับวัสดุ/ติดตั้ง/Commissioning) → `handleSvcAssign(...,checklist)` (ติ๊กครบจึงส่งมอบ) (3) **ส่งมอบ+ลูกค้าเซ็นรับ** (`received_by`/`received_date`) + แนบไฟล์ → `handleSvcDeliver` (ลงนาม DO + notify('do')) · DONE: **ออกใบรับประกัน** (`warranty_no`/`warranty_until`) → `handleSvcWarranty` (notify('warranty')) + ปริ้นใบรับประกัน · plan fields เพิ่ม: checklist(jsonb)/received_by/received_date/warranty_no/warranty_until · notif event `ev_warranty` · auto-complete service task (`completeSvcTask`) · เพิ่มสมาชิก: `emp_code` + role กรอกเอง
- **Project → คลังสินค้า (Inventory) [ปรับใหม่]:** ลบ tab "เตรียมส่งมอบ Service" + ลบเมนู Inventory top-level → รวมเป็น tab `project-inventory` ใต้ Project (`ProjectInventory`) · **รับเข้าอัตโนมัติ**: เมื่อ `handleUpdateBom` ตั้ง po_status='Delivered' → addMovement IN เข้า project_id (เต็มจำนวน BOM, กันซ้ำด้วย note `BOM#id`) · **เบิกอ้าง SR-No.** (`WithdrawSR` + `handleWithdrawSR`): เลือก SR → โชว์ลูกค้าทั้งใบ → เลือกรายการ/จำนวนจาก onhand + plan start/end → ตัดสต็อก OUT 'ติดตั้งงาน' + `addPlan(sr_id, sent:true)` = รอส่งมอบ Service (เบิกซ้ำได้หลายครั้งต่อ SR) · `service_plans.sr_id` (schema) · helper `PLAN_STATUS` · **(cleanup)** component `Inventory`/`HandoverSlip` + helper `installedQty`/`installSummary`/`poReceivedQty` (dead code) ลบออกแล้ว
- **ใบเบิกติดตั้ง (เดิม) — แยก บันทึก/ส่ง:** Tab "เตรียมส่งมอบ Service" (`project-handover`) → `HandoverSlip` เลือก BOM+จำนวน+แผน start/end · **(1) บันทึกใบเบิก (ร่าง)** `handleSaveSlip` = สร้าง `service_plans` (sent:false) ยังไม่ตัดสต็อก/ไม่เข้า inbox · **(2) ส่งมอบ Service** `handleSendSlip` = ตัดสต็อก OUT 'ติดตั้งงาน' ตาม lines + ตั้ง sent:true (ลบร่างได้ด้วย `handleDeleteSlip`) · Service inbox (เฉพาะ `sent && !acked`): เลือก Job/ทีมที่ว่าง (`memberBusy`) → `handleAckPlan(id, teamIds)` ack + ลงคิวปฏิทิน · `printWithdrawal()` ปริ้นใบเบิกไปตรวจ WH · DO ลงนามที่ Service · **คลัง = รับเข้าตาม PO + โอนข้าม Stock เท่านั้น** · `service_plans.sent` (schema)
- **Setting (เฉพาะ developer):** อนุมัติ/ยกเลิกสิทธิ์ผู้ใช้ (RPC admin_list_users/set_role/revoke) + คอนโซล **ดู / แก้ไข ✎ / ลบ** ข้อมูลทุกฝ่าย + **ปุ่ม Reset Data** (DEMO=reseed · LIVE=ป้องกัน ให้ใช้ reset-clean.sql) ผ่าน `db.resetData()`
- **แจ้งเตือน LINE/Email (ใหม่):** Setting → `NotifSettings` ตั้งค่า LINE Messaging API (token+to) / Email (recipients) / Edge Function URL + สวิตช์ 6 เหตุการณ์ (sr/stock/bom/po/handover/do) เก็บใน `notif_settings` (singleton id=1, RLS dev) · `notify(event,subject,msg,force)` ใน App ยิง fire-and-forget ไป Edge Function + เก็บ log ใน `notifLog` (session) · trigger จาก handler: createSR/createStock/sendBom/createPO+updateBom(Delivered)+receivePO/sendSlip/signDO · โค้ดฟังก์ชัน = `edge-notify.ts` (LINE push + Resend email · deploy ตาม comment ในไฟล์) · `line-webhook.ts` = Edge Function ตัวช่วยดัก **groupId** ของ LINE (ตอบ id กลับเข้าแชท — ใช้ครั้งเดียวเพื่อเอา id ไปวางช่อง "ส่งถึง") · ปุ่ม **Refresh all** บน TopBar = `handleRefreshAll`→reload() — ปุ่มดินสอเปิด `RowEditor` modal (field meta ต่อ entity ใน DATA_ENTITIES → text/num/date/sel/bool) ส่งเฉพาะ field ที่เปลี่ยน ผ่าน `db.updateRow` (generic update ทุกตาราง · LIVE ใช้สิทธิ์ developer ใน RLS เดียวกับ delete)
- **Dashboard:** KPI + คอขวด + เตือนส่งมอบ + ตารางภาพรวม Stock (เอากราฟ S-Curve/รายเดือนออกแล้วตามคำขอ — **(cleanup)** ลบ `SCurveChart`/`MonthlyBars`/`scurveData`/`monthlyInvData`/`PHASE_WEIGHT` + ym helpers ที่ไม่ถูกเรียกออกแล้ว) · `phaseGate` (เต็ม) ก็ลบ เหลือ `phaseDataGate` ที่ใช้จริง
- **เบิกตามงานติดตั้ง (ใหม่):** ปุ่ม "🔧 เบิกตามงานติดตั้ง (BOM)" ในฝ่ายบริการ → modal ดึงรายการจาก BOM แสดง BOM/เบิกแล้ว/คงเหลือคลังโครงการ → ตัดสต็อก OUT reason 'ติดตั้งงาน' (บล็อกเกินคงเหลือ) + แถบความคืบหน้า "ติดตั้งแล้ว X/Y · n/m รายการครบ" บนการ์ด (ครบ→ไฮไลต์เขียว)
- **อื่น ๆ:** Toggle ธีมสว่าง/มืด(remap slate ramp + CSS var, เก็บ localStorage) · กระดิ่งแจ้งเตือน(งานเข้า/ตีกลับ/ใกล้ครบ) · Export **Excel(.xlsx)** + พิมพ์ PDF · ค้นหา/กรอง · Optimistic update · หน้า "รอผู้ดูแลอนุมัติ" สำหรับผู้ใช้ใหม่ที่ยังไม่มี role

## 6) สิทธิ์ (RLS) — แนวคิด "ดูข้ามฝ่าย read-only + แก้เฉพาะของตน"
- roles: developer / sales / project / purchasing / service / executive
- ทุกฝ่ายอ่านได้หมด · แก้เฉพาะของฝ่ายตน (มีแบนเนอร์ 👁 โหมดดูอย่างเดียวเมื่อเปิดหน้าฝ่ายอื่น) · executive อ่านอย่างเดียว · developer ทำได้ทุกอย่าง
- LIVE: บังคับจริงด้วย RLS + RPC SECURITY DEFINER · role ล็อกตาม `user_roles` · DEMO: สลับ role อิสระเพื่อทดสอบ
- ผู้ใช้ใหม่ไม่มี role → หน้า Pending จนกว่า dev อนุมัติในแท็บ Setting

## 7) Workflow เฟส + Gate (บังคับฝั่ง server ใน RPC)
`project → purchasing → service → closed`
- **ปุ่มเดียวจบ "เสร็จ & ส่งต่อ" / "ปิดงานโครงการ"** (review v2): กดครั้งเดียว → ระบบ **ปิดงาน task ที่เหลือของเฟสให้อัตโนมัติ** + ตรวจ gate ข้อมูล + ส่งต่อ ใน RPC `complete_and_handoff` (atomic; gate ไม่ผ่าน → rollback ทั้งหมด ไม่ค้างงานที่ mark เสร็จ)
- ปุ่มเปิด/ปิดด้วย **`phaseDataGate`** (เงื่อนไขข้อมูลล้วน ไม่นับ task) · `phaseGate` = ข้อมูล+งานครบ (ใช้ตรวจสถานะรวม)
- project→purchasing: Job No. + มี BOM + ทุก bom_items.is_sent + **bomLBS = target_lbs**
- purchasing→service: ทุก bom_items.po_status='Delivered'
- service→closed: **do_signed** · ปุ่ม **"🏁 ปิดงานโครงการ"** โผล่ทั้งใน PhaseRibbon และในการ์ด Service (`ServiceJob` stage 4 เมื่อ phase=service + do_signed) — `onClose=handleHandoff`
- ใบเบิก (Project→Service): **ไม่มี reject plan** — แก้ส่วนต่างที่ Service ตอนจัดทีม (Actual: เวลาจริง start/end + เช็กลิสต์)
- reject (ตีกลับเฟส): ต้องมีเหตุผล · ack (รับงาน): **คงปุ่มไว้** เคลียร์ badge · ทุกอย่างลง `handoff_log`
- **(review v3) ย้าย handoff มาบนการ์ด Stock:** ลบปุ่ม "Workflow →" ออกจากการ์ด `ProjectStocks` → ฝัง `<PhaseRibbon>` (ปุ่มเสร็จ&ส่งต่อ/ปิดงาน/ตีกลับ/รับงาน) ในส่วนกางของการ์ดโดยตรง · หน้า Workflow Board (`page==='workflow'`) ยังเข้าได้ผ่านกระดิ่งแจ้งเตือน (secondary)

## 8) Deploy (สรุป)
1. Supabase: รัน `schema.sql` (โครงสร้างล้วน) → เปิด Email Auth (ปิด Confirm email) → (แนะนำ) สร้าง bucket `po-pdfs` public (ดู LIVE-OPS.md #2)
2. สมัคร `siradanai.s@precise.co.th` → รัน `schema.sql` ซ้ำ (ได้ dev)
3. (ออปชัน) อยากได้ข้อมูลสาธิตบน DB เปล่า → รัน `seed-demo.sql` · **production ข้ามขั้นนี้**
4. **อัปเดต schema ภายหลัง:** รัน `schema.sql` ซ้ำได้เลย — idempotent, **ไม่แตะข้อมูลจริง, ไม่สร้าง sample** (ห้ามรัน seed-demo.sql)
5. GitHub Pages: push `index.html`+`schema.sql`+เอกสาร → Settings→Pages→branch main/root
- คีย์ publishable commit ได้ · ห้าม service_role

## 9) คำตอบดีไซน์ที่ผู้ใช้ยืนยันแล้ว (อย่าถามซ้ำ)
- SR: 1 ใบ = หลายลูกค้า · Project Stock รวมหลาย SR
- สกุลเงิน BOM: THB + USD (กรอก FX) → Total เป็นบาท
- Popup LBS ตอนสร้าง Stock = จำนวนเป้าหมายของ Stock (ใช้ reconcile)
- Service: จัดทีมได้ + ปฏิทินรายเดือน · ส่งแผน = ใบแผน + Inbox ให้ Service กดรับ
- สิทธิ์: กฎสำเร็จรูป (ดูข้ามฝ่าย read-only + แก้เฉพาะตน)
- Inventory: 2 ระดับ(กลาง+ต่อ stock) · เคลื่อนไหว = Manual + ปุ่มดึง(รับตาม PO) · IN อ้าง PO รับบางส่วนได้ · OUT มีประเภท + โอนกลาง→โครงการ · **บล็อกติดลบ**
- ธีม: สว่าง (น้ำเงิน/เขียว/ส้มอ่อน) เป็นค่าเริ่มต้น + toggle มืด · บทบาท developer label = "Mr. Siradanai (Dev)"

## 10) งานที่ยังเสนอไว้ (ยังไม่ทำ) — ถ้าจะทำต่อ
- #2 อัปโหลด PDF จริงผ่าน Supabase Storage (โค้ด `uploadPdfIfNeeded` พร้อม ต้องสร้าง bucket)
- #3 smoke-test RLS จริง + #8 pg_cron/Edge Function แจ้งเตือน (สคริปต์ใน LIVE-OPS.md, ยังไม่ deploy)
- Realtime sync · lot/serial ของ LBS · pre-compile (เลิก CDN Babel/Tailwind)
- ~~Dashboard กราฟ S-curve/รายเดือน~~ ✅ เสร็จ (ข้อ 5) · ~~ปุ่มเบิกตามงานติดตั้ง (ดึงจาก BOM)~~ ✅ เสร็จ (ข้อ 5)

## 11) ทดสอบในเครื่อง
- มี static server (เช่น `npx serve` / `python -m http.server`) แล้วเปิด `index.html` ผ่าน HTTP (อย่าเปิด file://)
- ทดสอบ DEMO: ตั้งคีย์ Supabase = "" ชั่วคราว → เห็นข้อมูลจำลองครบทุกเฟส (4 Stock ครบทุก phase, คลังมี movement) → ใส่คีย์คืนหลังเทสต์

## 12) Component / Function Map ของ `index.html` (เลขบรรทัดโดยประมาณ — อาจคลาดถ้าแก้ไฟล์)

**ส่วนหัว / โครงสร้าง**
| บรรทัด | สิ่งที่อยู่ |
|---|---|
| ~45 | CONFIG — `SUPABASE_URL`/`SUPABASE_ANON` (ใส่คีย์ตรงนี้), `LIVE`, `ok()`, `uploadPdfIfNeeded()` (#2 Storage) |
| ~62 | CONSTANTS — DEPT(สี/ป้ายฝ่าย), PHASES, TASK_TEMPLATE, CURRENCY, OUT_REASONS ฯลฯ |
| ~114 | HELPERS — `baht/bahtShort/daysUntil/num/nextSeq`, `downloadCSV`(128), `exportXLSX`(134, SheetJS) |
| ~146 | `seedDemo()` — ข้อมูลจำลองทั้งหมด (customers/srs/projects/tasks/bom/pos/team/schedule/plans/handoffs/users/inventory) |
| ~299 | `const db = {…}` — **data layer DEMO/LIVE ทุก method** (loadAll 300, createSR 337, createStock 354, createPO 379, addMovements 413, markBomDelivered 415, setUserRole 407, handoff/completeAndHandoff/reject/ackPhase 418-440 ฯลฯ) |

**Atoms / Logic helpers**
| บรรทัด | สิ่งที่อยู่ |
|---|---|
| ~431 | ICONS (`Ic`, `Icon.*` รวม `gear`) |
| ~457 | UI ATOMS — Card, Pill, Lbl, Inp, Sel, **EditText**(479 commit-on-blur), Empty, `projProgress` |
| ~490 | Linkage helpers — nextPhase/prevPhase, `stockCustomers`/`requestedLBS`/`bomLBS`/`targetLBS`(495-498), `poOrderedQty`/`bomRemaining`(500-501), `invCodes`/`invBalance`/`invOnhand`/`poReceivedQty`(503-), **`phaseGate`**(518) |

**Components (ตามฝ่าย)**
| บรรทัด | Component | หน้า/ใช้ที่ |
|---|---|---|
| ~564 | `Sidebar` | เมนูแม่+กิ่งย่อย (NAV ~551, PAGE_GROUP/PAGE_DEP) |
| ~605/616 | `buildNotifs`/`NotifBell` | กระดิ่ง (#2) |
| ~638 | `TopBar` | หัวบน (role, theme toggle, bell) |
| ~670 | `PoModal` | ดู PO ราย Stock (Project เปิดดู+PDF) |
| ~706 | `PHASE_WEIGHT`/`scurveData`/`SCurveChart` · `monthlyInvData`/`MonthlyBars` | กราฟ Dashboard (SVG) — helper ym* (ymOf/ymAdd/ymList/ymLabel/monthsBetween) |
| ~707 | `Dashboard` | page `dashboard` (KPI, bottleneck, alerts, **2 กราฟ SVG**, ปุ่ม Excel/Print) |
| ~794 | `AddTask` | ปุ่มเพิ่มงาน inline |
| ~809/858 | `WorkflowBoard`/`PhaseRibbon` | page `workflow` (ส่งงาน/ตีกลับ/รับงาน + gate) |
| ~914/947/1018 | `SrTrackTable`/`SalesPipeline`/`SalesSR` | page `sales` + `sales-sr` |
| ~1019/1051 | `SrTrackTable`/`SalesSR` | page `sales-sr` — **ตารางเส้นเทา + แก้ PO/สัญญารายลูกค้า** (`onUpdateCustomer`) · helper `contractColor` |
| ~1213/1217 | `Field`/`ProjectDept` | page `project` (Inbox SR + Popup สร้าง Stock+LBS) |
| ~1299/1353 | `ProjectBom`/**`BomRoundCard`** | page `project-stocks` — **BOM หลายครั้ง** · helper `roundOf`/`roundName`/`projBomRounds`/`roundItems`/`roundIsSent`/`bomSent`/`bomStatusOf` (ก่อน `phaseGate`) · `db.sendBom(projectId, roundN)` |
| (ใกล้ InstallSummary) | `HandoverSlip`/`ProjectHandover` | page `project-handover` — ออกใบเบิก+แผน · helper `memberBusy`/`printWithdrawal` · `genWdNo` · `handleSendHandover`/`handleAckPlan(id,teamIds)` |
| ~1231/1248 | `HandoffTimeline`/`ProjectStocks` | timeline + การ์ดพับ Stock |
| ~1307/1416 | `Procurement`/`PurchasingDone` | page `purchasing` + `purchasing-done` (PurchasingDone = **กลุ่มตาม Stock No. · การ์ดพับซ่อนได้ · badge ครบทุกรายการ · ยอดรวมราย Stock + ค้นหา/ย่อทั้งหมด**) |
| ~1449/~1510 | `InstallDraw`/`FieldService`/`ServiceTeam` | page `service` (Inbox แผน, **เบิกตามงานติดตั้ง BOM modal**, DO, ปฏิทินคิว) · helper `installedQty`/`installSummary` (~516) · handler `handleInstallDraw` ใน App |
| ~1670 | `Login` | LIVE ยังไม่ล็อกอิน |
| ~1706 | `Inventory` | page `inventory` (รับตาม PO/บันทึกเอง/โอน/บล็อกติดลบ) |
| ~1855 | `RowEditor`/`Settings` | page `settings` (อนุมัติสิทธิ์ + **ดู/แก้ไข/ลบ** ข้อมูล) — DATA_ENTITIES(+`fields` meta, helper `f()`) · handler `handleUpdateRow`/`db.updateRow` |
| ~1923 | `Pending` | ผู้ใช้ใหม่รออนุมัติ |
| ~1938 | **`App`** | state(1939) · useEffect auth/load · `run(fn,optimistic)`(~1958) · gen* เลขเอกสาร · **handlers ทุกตัว** · `<main>` routing ตาม `page` (~2030+) |

**ค้นโค้ดเร็ว:** ค้น `function ชื่อComponent` หรือ comment แถบ `=====` ของแต่ละ section · routing ของ page อยู่ใน `App` (`{page==='...' && <Component .../>}`)
