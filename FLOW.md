# Flow Work — ระบบบริหารโครงการขาย 115 kV LBS

เอกสารอธิบายกระบวนการทำงาน (workflow) ของระบบ เพื่อใช้อ้างอิงในการพัฒนา/ปรับใช้งานจริง
อ้างอิงโค้ด: [`index.html`](index.html) (React SPA) + [`schema.sql`](schema.sql) (Supabase/PostgreSQL)

---

## 1. ภาพรวม

ระบบนี้เป็น **workflow ข้ามฝ่าย (cross-department pipeline)** โครงการขาย/ติดตั้ง LBS 115kV
แต่ละโครงการจะ "ไหล" ผ่าน 4 ฝ่ายตามลำดับ แล้วปิดงาน:

```
┌─────────┐   ┌──────────┐   ┌─────────────┐   ┌──────────┐   ┌─────────┐
│  SALES  │ → │ PROJECT  │ → │ PURCHASING  │ → │ SERVICE  │ → │ CLOSED  │
│ ฝ่ายขาย │   │ฝ่ายโครงการ│   │ ฝ่ายจัดซื้อ  │   │ฝ่ายบริการ │   │ ปิดงาน  │
└─────────┘   └──────────┘   └─────────────┘   └──────────┘   └─────────┘
     │              │               │                │
     └──────────────┴───────────────┴────────────────┘
                            │
                  ┌───────────────────┐
                  │ EXECUTIVE (มองรวม) │   DEVELOPER (สิทธิ์เต็มทุกฝ่าย)
                  └───────────────────┘
```

- **5 เฟส** (`PHASES`, index.html): `sales → project → purchasing → service → closed`
- **6 บทบาท** (`DEPT`): `developer, sales, project, purchasing, service, executive`

---

## 2. โมเดลข้อมูล

```
projects (โครงการ — entity หลัก)
  ├─ department_tasks   งานของแต่ละฝ่าย (sort_order + status)
  ├─ bom_items          รายการวัสดุในโครงการ ──┐ (material_id)
  └─ purchase_orders    ใบสั่งซื้อ (หลายใบ/โครงการ)
                                                │
materials (Material List กลาง — แชร์ข้ามโครงการ) ◄┘
  └─ material_totals (VIEW: SUM ปริมาณข้ามทุกโครงการ)
```

**หลักการสำคัญ:** `materials` คือทะเบียนกลาง ส่วน `bom_items` คือการ "หยิบ" material มาใส่โครงการ
→ ทำให้รวมยอด LBS/Accessory ข้ามทุกโครงการได้ (ตอบโจทย์ "สั่งซื้อรวมเพื่อต่อรองราคา")

---

## 3. Flow ทีละฝ่าย

### 🟦 เฟส 1 — ฝ่ายขาย (Sales)

| หัวข้อ | รายละเอียด |
|---|---|
| **Input** | ความต้องการลูกค้า / ออกพบหน้างาน |
| **สถานะขาย** | `Interested (สนใจ) → Reserved (สั่งจอง) → Ordered (สั่งซื้อ)` |
| **งานในเฟส** | 1) สำรวจความต้องการ → 2) เสนอขาย + บันทึกข้อมูล → 3) ส่งต่อฝ่ายโครงการ → 4) ติดตาม PO/สัญญา |
| **Output** | โครงการ + ข้อมูลลูกค้า + scope + วันส่งมอบ |
| **UI** | Kanban 3 คอลัมน์ตามสถานะขาย (`SalesPipeline`) |
| **Trigger →** | งานฝ่ายขายครบทุกข้อ → เฟส `project` |

### 🟧 เฟส 2 — ฝ่ายโครงการ (Project)

| หัวข้อ | รายละเอียด |
|---|---|
| **Input** | โครงการที่ฝ่ายขายส่งต่อ |
| **งานในเฟส** | แยกประเภท → สร้าง Project Stock No. → Budget & Flow (+ Job No.) → ทำ BOM → **ออก PR** → กำหนดแผนรับของ |
| **กิจกรรมจริง** | จัดการ Material List + สร้าง BOM (`ProjectBom`) → กด "ออก PR" เปลี่ยน `pr_status: Draft → PR Issued` |
| **Output** | BOM ครบ + งบประมาณ/กำไร/กระแสเงินสด + PR ส่งจัดซื้อ |
| **Trigger →** | งานฝ่ายโครงการครบ → เฟส `purchasing` |

### 🟥 เฟส 3 — ฝ่ายจัดซื้อ (Purchasing)

| หัวข้อ | รายละเอียด |
|---|---|
| **Input** | รายการ BOM ที่ `pr_status != 'Draft'` (`Procurement`) |
| **งานในเฟส** | รับ PR + เปรียบเทียบราคา → ออก PO + ติดตามของเข้า |
| **กิจกรรมจริง** | อัปเดต `po_status: Awaiting PO → PO Received → Delivered`; ดู PO drill-down (`PoModal`) |
| **Output** | PO ออกครบ + ของเข้าครบ |
| **Trigger →** | งานฝ่ายจัดซื้อครบ → เฟส `service` |

### 🟩 เฟส 4 — ฝ่ายบริการ (Service)

| หัวข้อ | รายละเอียด |
|---|---|
| **Input** | เฉพาะโครงการ `status='Ordered'` **และมี** `delivery_date` (`FieldService`) |
| **งานในเฟส** | รับแผนจัดส่ง → จัดทีมงาน → ส่งมอบ + ลงนาม DO ปิดงาน |
| **Output** | งานติดตั้งเสร็จ + เอกสาร DO |
| **Trigger →** | งานฝ่ายบริการครบ (ฝ่ายสุดท้าย) → เฟส `closed` |

### 📊 Executive Dashboard

มองทุกเฟสพร้อมกัน: KPI ยอดขาย/กำไร/ความคืบหน้าเฉลี่ย, **คอขวดระหว่างฝ่าย** (นับโครงการค้างต่อเฟส),
แจ้งเตือนส่งมอบ ≤15 วัน

---

## 4. สถานะต่าง ๆ (State Machines)

> ⚠️ ระวังสับสน: PO มี **2 ชุดสถานะ** คนละความหมาย

| ชุด | ฟิลด์ | ค่า | ความหมาย |
|---|---|---|---|
| สถานะขาย | `projects.status` | Interested → Reserved → Ordered | ความคืบหน้าการขาย |
| เฟสโครงการ | `projects.current_phase` | sales → project → purchasing → service → closed | ฝ่ายที่กำลังรับผิดชอบ |
| สถานะงาน | `department_tasks.status` | Pending → In Progress → Completed | งานย่อยแต่ละข้อ |
| PR | `bom_items.pr_status` | Draft → PR Issued → Sent to Purchasing | สถานะใบขอซื้อของรายการ |
| PO (รายการ) | `bom_items.po_status` | Awaiting PO → PO Received → Delivered | สถานะการจัดหาของรายการ BOM |
| PO (เอกสาร) | `purchase_orders.status` | รอออก → ออกแล้ว → กำลังส่ง → รับครบ | สถานะใบ PO รายใบ |

---

## 5. กลไกเลื่อนเฟสอัตโนมัติ ⭐

หัวใจของ flow อยู่ที่ `handleTask` (index.html) — ทุกครั้งที่เปลี่ยนสถานะงาน:

```
กด task → คำนวณงานทั้งฝ่ายของโครงการ → ครบทุกข้อหรือยัง?
   ├─ ครบ + ฝ่ายที่ทำเสร็จ "คือเฟสปัจจุบันพอดี" + ไม่ใช่ฝ่ายสุดท้าย → เลื่อนไปฝ่ายถัดไป
   ├─ ครบ + เป็นฝ่าย service (ฝ่ายสุดท้าย)                          → current_phase = 'closed'
   └─ ไม่ครบ / ไม่ใช่เฟสปัจจุบัน                                    → ไม่ขยับ
```

**กฎสำคัญ (แก้แล้ว):** เลื่อนเฟสเฉพาะเมื่อ `di === cur` (ฝ่ายที่ทำเสร็จ = เฟสปัจจุบัน)
ป้องกัน **การกระโดดข้ามเฟส** (เดิมใช้ `<=` ทำให้ทำงานฝ่ายถัดไปเสร็จแล้วเฟสกระโดดข้ามได้)

| เฟสปัจจุบัน | ฝ่ายที่ทำเสร็จครบ | ผลลัพธ์ |
|---|---|---|
| sales | sales | → project ✅ |
| sales | project | คงอยู่ sales (ไม่กระโดด) ✅ |
| project | project | → purchasing ✅ |
| purchasing | purchasing | → service ✅ |
| service | service | → closed ✅ |
| purchasing | sales (เสร็จไปแล้ว) | คงอยู่ purchasing (ไม่ย้อน) ✅ |

---

## 6. ระบบสิทธิ์ (2 ชั้น)

| ชั้น | ที่อยู่ | กฎ |
|---|---|---|
| **Client** | `canDept(role, dep)` (index.html) | แก้ได้เฉพาะคอลัมน์ฝ่ายตัวเอง · developer แก้ได้หมด |
| **Server (RLS)** | policies ใน schema.sql | อ่าน: ทุกฝ่ายที่ login · เขียน: จำกัดตามฝ่าย ผ่าน `current_department()` / `is_developer()` |

---

## 7. โหมดทำงาน

| โหมด | เงื่อนไข | ข้อมูล |
|---|---|---|
| **DEMO** | `SUPABASE_URL`/`SUPABASE_ANON` ว่าง | seed data ในเครื่อง (`seedDemo`) — ทดสอบ flow ได้ครบ |
| **LIVE** | ใส่ค่า Supabase ครบ (index.html:33-34) | ต่อ Supabase จริง ผ่าน `db` layer เดียวกัน |

---

## 8. สิ่งที่ควรทำต่อก่อนขึ้นใช้จริง (สรุป)

1. **Build step (Vite)** แทน in-browser Babel — เลิกคอมไพล์ JSX ทุกครั้งที่เปิดหน้า
2. **Optimistic update** แทน `reload()` ที่ refetch ทั้ง 5 ตารางทุก action
3. **อุด RLS DELETE** — ปัจจุบัน sales/project ลบโครงการได้ + `ON DELETE CASCADE` → เสี่ยงข้อมูลหาย
4. **Supabase Realtime** ให้หลายฝ่ายเห็นอัปเดตสดพร้อมกัน
5. **Error/Toast** เมื่อ save ล้มเหลว (ปัจจุบันเงียบ)
6. **ย้าย keys ไป env var** แยก dev/prod
7. **Pagination/filter ฝั่ง server** เมื่อข้อมูลโต
8. **แจ้งเตือนอัตโนมัติ** (pg_cron/Edge Function ยิง Line Notify ≤15 วัน) ตาม comment ในโค้ด

---
_อัปเดต: 2026-06-10_
