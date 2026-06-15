# Linkage Design — การเชื่อมโยงระหว่างฝ่ายตาม Flow

สเปกการออกแบบ "การส่งต่องานข้ามฝ่าย" + ปุ่มเพิ่ม/ส่งงาน เพื่อนำไปพัฒนาใช้งานจริง
อ้างอิง: [`index.html`](index.html), [`schema.sql`](schema.sql), [`FLOW.md`](FLOW.md)

> **สรุปการตัดสินใจ:** ส่งงานด้วย "ปุ่มมีเงื่อนไข" (เลิก auto-advance) · PR 2 ขั้นรวมเป็นใบเดียว · ฝ่ายขายสร้างโครงการ + ฝ่ายโครงการใส่ Stock No. · มีแจ้งเตือน + ตีกลับ + log

---

## 0. v2 — แยก Customer ออกจาก Project Stock (ใช้แทนโมเดลเดิมในเอกสารนี้) ⭐

โมเดลถูก refactor: **ฝ่ายขายจัดการ "ลูกค้า"** ส่วน **ฝ่ายโครงการสร้าง "Project Stock" โดยเลือกลูกค้า** (1 ลูกค้า → ได้หลาย Stock)

```
customers (Sales)                         projects = Project Stock (Project เลือก customer)
  ├─ customer_type (ราชการ/เอกชน/รัฐฯ)        ├─ customer_id → customers
  ├─ work_type (Supply / S&C)                ├─ project_stock_no, job_no
  ├─ sale_status (สนใจ/สั่งจอง/สั่งซื้อ)        ├─ current_phase: project→purchasing→service→closed
  ├─ งานฝ่ายขาย (department_tasks.customer_id) ├─ งานโครงการ/จัดซื้อ/บริการ (tasks.project_id)
  └─ forwarded (ส่งให้ฝ่ายโครงการแล้ว)          └─ phase_acked, BOM, PR, PO
```

**Flow การเชื่อมโยงใหม่:**
1. **Sales:** สร้างลูกค้า + แยกประเภท (2 ฟิลด์) + ทำงานฝ่ายขาย → ปุ่ม **"ส่งฝ่ายโครงการ"** (enable เมื่องานขายครบ + สถานะ ≥ สั่งจอง)
2. **Project:** เห็นลูกค้าใน inbox "ลูกค้าที่ฝ่ายขายส่งมา" → ปุ่ม **"สร้าง Project Stock No."** (เลือกลูกค้า → gen STK + JOB → เข้าเฟส project)
3. เฟสที่เหลือ (project→purchasing→service) เดินด้วยปุ่ม "ส่งงานต่อ"/"ตีกลับ" บน Stock เหมือน v1
4. **Badge งานเข้าใหม่ (Project)** = ลูกค้า forwarded ที่ยังไม่มี Stock + Stock ที่เพิ่งส่งต่อมายังไม่รับ

**ผลต่อ schema (เฟส 2):** เพิ่มตาราง `customers`; `projects` เพิ่ม `customer_id` + ลบ phase 'sales' (เฟสเริ่มที่ project); `department_tasks` เพิ่ม `customer_id` (nullable, สำหรับงานฝ่ายขาย); ที่เหลือคงเดิม

> ส่วนข้อ 1-9 ด้านล่างคือดีไซน์ v1 (handoff/PR/reject/log) ที่ยังใช้ได้ — ต่างเพียงเฟสเริ่มต้นย้ายมาที่ Stock และฝ่ายขายทำงานที่ระดับลูกค้า

---

## 1. หลักการเชื่อมโยง (เปลี่ยนจากเดิม)

แยก 2 แนวคิดออกจากกันให้ชัด:

| แนวคิด | เดิม | ใหม่ |
|---|---|---|
| **ความคืบหน้าในเฟส** | task status (Pending→Completed) | คงเดิม |
| **การส่งต่อเฟส** | อัตโนมัติเมื่อ task ครบ (`handleTask`) | **ปุ่ม "ส่งงานต่อ" แบบ manual + มีเงื่อนไข** |

```
        ┌─ ภายในฝ่าย ─────────────┐        ┌─ ข้ามฝ่าย ──────────┐
แต่ละ task: Pending→In Progress→Completed   ปุ่ม "ส่งงานต่อ →" (gated)
                                            ปุ่ม "ตีกลับ ←" (reject)
```

**กฎปุ่ม "ส่งงานต่อ":**
1. ขึ้นเฉพาะเมื่อ `current_phase === ฝ่ายของฉัน` และ `role` แก้ฝ่ายนี้ได้
2. **enabled** เมื่อผ่าน "เงื่อนไขปิดเฟส" (gate) ของฝ่ายนั้นครบ (ดูตารางข้อ 4)
3. กดแล้ว → เลื่อน `current_phase` ไปฝ่ายถัดไป + เขียน `handoff_log` + สร้าง notification ให้ฝ่ายปลายทาง

> ผลต่อโค้ด: `handleTask` **ตัดส่วน auto-advance ออก** เหลือแค่ update task status; เพิ่ม `handleHandoff()` และ `handleReject()` แยก

---

## 2. Data model ที่ต้องเพิ่ม/แก้

### 2.1 แก้ `projects`
```sql
ALTER TABLE projects ALTER COLUMN project_stock_no DROP NOT NULL;
-- UNIQUE คงไว้ได้ (Postgres ยอมให้ NULL ซ้ำได้หลายแถว)
-- เพิ่มสถานะ "งานเข้าใหม่ยังไม่รับ" ต่อเฟส
ALTER TABLE projects ADD COLUMN phase_acked BOOLEAN DEFAULT FALSE;  -- ฝ่ายปลายทางกด "รับงาน" แล้วหรือยัง
```

### 2.2 ตารางใหม่ — `purchase_requests` (หัว PR ใบเดียว รวมหลายรายการ)
```sql
CREATE TABLE purchase_requests (
  id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  pr_no       VARCHAR(40) NOT NULL UNIQUE,         -- PR-YYYY-NNN
  project_id  BIGINT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  status      VARCHAR(30) NOT NULL DEFAULT 'Sent to Purchasing',
  note        TEXT,
  created_at  TIMESTAMPTZ DEFAULT NOW()
);
ALTER TABLE bom_items ADD COLUMN pr_id BIGINT REFERENCES purchase_requests(id) ON DELETE SET NULL;
```

### 2.3 ตารางใหม่ — `handoff_log` (audit + เป็นแหล่งข้อมูล notification)
```sql
CREATE TABLE handoff_log (
  id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  project_id  BIGINT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  from_phase  phase_t,
  to_phase    phase_t,
  action      VARCHAR(10) NOT NULL,   -- 'forward' | 'reject' | 'create'
  by_dept     department_t,
  by_user     UUID DEFAULT auth.uid(),
  note        TEXT,
  acked       BOOLEAN DEFAULT FALSE,  -- ฝ่ายปลายทางอ่าน/รับแล้ว
  created_at  TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX idx_handoff_project ON handoff_log (project_id);
CREATE INDEX idx_handoff_to ON handoff_log (to_phase, acked);
```

> **Notification = query:** "งานเข้าใหม่ของฝ่ายฉัน" คือ `handoff_log` ที่ `to_phase = myDept AND acked = FALSE` — ไม่ต้องมีตาราง notification แยก

---

## 3. การส่งต่อแบบ Server-side (กันสิทธิ์ + atomic)

ใช้ Postgres function (SECURITY DEFINER) บังคับกฎฝั่ง server แทนเปิด RLS ให้ทุกฝ่ายเขียน `projects`:

```sql
-- ส่งงานไปเฟสถัดไป (เฉพาะฝ่ายที่เป็นเฟสปัจจุบัน)
CREATE OR REPLACE FUNCTION handoff_project(p_id BIGINT, p_note TEXT DEFAULT NULL)
RETURNS phase_t LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE cur phase_t; nxt phase_t; mydept department_t;
DECLARE seq TEXT[] := ARRAY['sales','project','purchasing','service','closed'];
DECLARE i INT;
BEGIN
  SELECT current_phase INTO cur FROM projects WHERE id = p_id;
  mydept := current_department();
  IF NOT (is_developer() OR mydept::text = cur::text) THEN
    RAISE EXCEPTION 'ฝ่ายของคุณไม่ใช่เจ้าของเฟสนี้';
  END IF;
  i := array_position(seq, cur::text);
  nxt := seq[i+1]::phase_t;
  UPDATE projects SET current_phase = nxt, phase_acked = FALSE WHERE id = p_id;
  INSERT INTO handoff_log(project_id, from_phase, to_phase, action, by_dept, note)
    VALUES (p_id, cur, nxt, 'forward', mydept, p_note);
  RETURN nxt;
END $$;

-- ตีกลับไปเฟสก่อนหน้า (ต้องมีเหตุผล)
CREATE OR REPLACE FUNCTION reject_project(p_id BIGINT, p_note TEXT)
RETURNS phase_t LANGUAGE plpgsql SECURITY DEFINER AS $$ ... (ลด index ลง 1, action='reject') $$;
```

ฝั่ง client เรียกผ่าน `sb.rpc('handoff_project', {p_id, p_note})`

---

## 4. เงื่อนไขปิดเฟส (Gate) ต่อฝ่าย — เมื่อไหร่ปุ่ม "ส่งงานต่อ" ถึง enable

| ฝ่าย (เฟส) | Gate (ต้องครบจึงส่งต่อได้) | ส่งไปยัง |
|---|---|---|
| 🟦 Sales | task ฝ่ายขายครบ + `status='Ordered'` (หรือ Reserved ตามนโยบาย) | Project |
| 🟧 Project | task ฝ่ายโครงการครบ + มี `project_stock_no` + มี `job_no` + BOM ≥1 รายการ + **มี PR ส่งจัดซื้อแล้ว** | Purchasing |
| 🟥 Purchasing | task ฝ่ายจัดซื้อครบ + ทุก BOM ของ PR เป็น `po_status='Delivered'` | Service |
| 🟩 Service | task ฝ่ายบริการครบ | (closed) |

ถ้ายังไม่ผ่าน gate → ปุ่ม disabled + tooltip บอกว่าเหลืออะไร

---

## 5. รายการปุ่มทั้งหมด (Button Inventory)

### ปุ่ม "เพิ่ม" (Add)
| ปุ่ม | ที่อยู่ | สิทธิ์ | ผล |
|---|---|---|---|
| **+ เพิ่มโครงการ** | Sales (`SalesPipeline` header) | sales, developer | `db.addProject({name, customer_name, status:'Interested'})` — ไม่มี Stock No. |
| **+ เพิ่มงาน** | ทุกบอร์ด (มีอยู่แล้ว `AddTask`) | ฝ่ายตัวเอง | คงเดิม |
| **+ เพิ่มวัสดุ / + เพิ่มรายการ BOM** | Project (มีอยู่แล้ว) | project, developer | คงเดิม |

### ปุ่ม "ส่งงาน / เชื่อมโยง" (Handoff)
| ปุ่ม | ที่อยู่ | เงื่อนไข | ผล |
|---|---|---|---|
| **ส่งงานต่อ → [ฝ่ายถัดไป]** | `PhaseRibbon` ทุกเฟส | ผ่าน gate ข้อ 4 | `rpc('handoff_project')` + log + แจ้งเตือน |
| **← ตีกลับ** | ทุกเฟส (ยกเว้น sales) | role = เฟสปัจจุบัน | เปิด modal ใส่เหตุผล → `rpc('reject_project')` |
| **รับงาน (ack)** | banner เมื่อมีงานเข้าใหม่ | role = เฟสปัจจุบัน | set `phase_acked=true`, mark handoff_log acked |
| **ออก Stock No.** | Project (banner ถ้ายังไม่มี) | project, developer | gen `STK-YYYY-NNN` → `updateProject` |
| **ออก PR** (รายตัว) | ProjectBom (มีอยู่แล้ว) | project, developer | Draft → PR Issued |
| **ส่ง PR ให้จัดซื้อ** (batch) | ProjectBom header | มี ≥1 รายการ PR Issued | สร้าง `purchase_requests` 1 ใบ + เซ็ตทุกรายการ PR Issued → Sent to Purchasing |

---

## 6. โฟกัส: ฝ่ายโครงการ (Project) — 5 ขั้นตามที่ระบุ

| ขั้น | การเชื่อมโยง / ปุ่ม | สถานะข้อมูล |
|---|---|---|
| **1. รับงานจากฝ่ายขาย** | งานเด้งเข้า (current_phase=project, acked=false) → banner "งานเข้าใหม่จากฝ่ายขาย" + ปุ่ม **รับงาน** | `phase_acked: false→true` |
| **2. แยกประเภท → สร้าง Stock No.** | banner "ยังไม่มี Stock No." + ปุ่ม **ออก Stock No.** (gen STK-YYYY-NNN) | `project_stock_no: null→STK-...` |
| **3. ทำ BOM → เตรียมฟอร์ม PR** | เพิ่มรายการ BOM + ปุ่ม **ออก PR** รายตัว (Draft→PR Issued) | `bom.pr_status: Draft→PR Issued` |
| **4. BOM ครบ + งบ/กำไร/กระแสเงินสด** | Budget card คำนวณอัตโนมัติจาก BOM; gate ตรวจครบ | (อ่านค่า) |
| **5. กด "ส่ง PR ให้จัดซื้อ" → กำหนดแผนรับของ** | ปุ่ม **ส่ง PR** (batch) สร้าง PR ใบเดียว → จากนั้นปุ่ม **ส่งงานต่อ → จัดซื้อ** enable | `pr_status: PR Issued→Sent to Purchasing`; สร้าง `purchase_requests` |

ลำดับปุ่มในหน้า Project:
```
[รับงาน] → [ออก Stock No.] → (ทำ BOM + ออก PR รายตัว) → [ส่ง PR ให้จัดซื้อ] → [ส่งงานต่อ → จัดซื้อ]
   ขั้น1        ขั้น2                ขั้น3                      ขั้น5(ก)            ขั้น5(ข)
```

---

## 7. แจ้งเตือน (งานเข้าใหม่) — UI

- **Sidebar:** badge ตัวเลขข้างชื่อฝ่าย = จำนวนโครงการที่ `current_phase=ฝ่ายนั้น AND phase_acked=false`
- **Dashboard:** การ์ด "งานเข้าใหม่รอรับ" แยกตามฝ่าย
- **หน้าฝ่าย:** banner ด้านบน + ปุ่ม "รับงาน"

---

## 8. สถานะใหม่ (อัปเดตจาก FLOW.md ข้อ 4)

- `bom_items.pr_status`: `Draft → PR Issued → Sent to Purchasing` (ครบทั้ง 3 ขั้นแล้ว ✅ เดิมขาดขั้นสุดท้าย)
- เพิ่ม `purchase_requests.status` และ `projects.phase_acked`
- `handoff_log.action`: `create | forward | reject`

---

## 9. ผลกระทบต่อโค้ดเดิม (สรุป diff ที่ต้องทำ)

| ไฟล์/ส่วน | การเปลี่ยน |
|---|---|
| `handleTask` (index.html) | ตัด auto-advance phase ออก เหลือแค่ update task |
| เพิ่ม `handleHandoff / handleReject / handleAckPhase / handleAddProject / handleAssignStockNo / handleSendPR` | ฟังก์ชันใหม่ใน `App` |
| `db` layer | เพิ่ม `addProject`, `assignStockNo`, `sendPR`, `handoff`, `reject`, `ackPhase` (DEMO + LIVE) |
| `PhaseRibbon` | เพิ่มปุ่ม "ส่งงานต่อ"/"ตีกลับ" + แสดง gate |
| `SalesPipeline` | เพิ่มปุ่ม "+ เพิ่มโครงการ" + ฟอร์ม |
| `ProjectBom` | เพิ่มปุ่ม "ส่ง PR ให้จัดซื้อ" (batch) + banner Stock No. |
| `Sidebar` | badge งานเข้าใหม่ |
| `schema.sql` | stock_no nullable, ตาราง `purchase_requests`/`handoff_log`, function `handoff_project`/`reject_project`, RLS |

---
_อัปเดต: 2026-06-10_
