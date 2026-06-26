-- =====================================================================
--  ระบบบริหารโครงการขาย 115 kV LBS — Supabase / PostgreSQL Schema  (v4)
--  โมเดล: Customer (Sales) → Sales Requisition (รวมหลายลูกค้า)
--                          → Project Stock (รวมหลาย SR) → BOM → PO → Service
--  ลำดับเฟส Stock: project → purchasing → service → closed
--  รันใน Supabase → SQL Editor (ทั้งไฟล์ได้เลย / รันซ้ำได้ idempotent)
--  *** โครงสร้างล้วน — ไม่แตะ/ไม่สร้างข้อมูล · ข้อมูลตัวอย่างแยกไป seed-demo.sql ***
-- =====================================================================

DO $$ BEGIN
  CREATE TYPE phase_t         AS ENUM ('sales','project','purchasing','service','closed');
  CREATE TYPE task_status_t   AS ENUM ('Pending','In Progress','Completed');
  CREATE TYPE department_t    AS ENUM ('developer','sales','project','purchasing','service','executive');
  CREATE TYPE bom_status_t    AS ENUM ('Draft','Sent to Purchasing');
  CREATE TYPE po_status_t     AS ENUM ('Awaiting PO','PO Received','Delivered');
  CREATE TYPE po_doc_status_t AS ENUM ('รอออก','ออกแล้ว','กำลังส่ง','รับครบ');
  CREATE TYPE customer_type_t AS ENUM ('ราชการ','เอกชน','รัฐวิสาหกิจ');
  CREATE TYPE work_type_t     AS ENUM ('Supply','Supply & Construction');
  CREATE TYPE currency_t      AS ENUM ('THB','USD');
  CREATE TYPE handoff_act_t   AS ENUM ('create','forward','reject','ack');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- ---------- 1) sales_requisitions (ฝ่ายขายรวบรวมลูกค้า → ส่งฝ่ายโครงการ) ----------
CREATE TABLE IF NOT EXISTS sales_requisitions (
  id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  sr_no           VARCHAR(40) NOT NULL UNIQUE,            -- SR-YYYY-NNN
  cust_po_no      VARCHAR(80),                            -- เลขที่ PO จากลูกค้า (ติดตามภายหลัง)
  contract_status VARCHAR(40) NOT NULL DEFAULT 'รอ PO/สัญญา',
  note            TEXT,
  stock_id        BIGINT,                                 -- ถูกดึงเข้า Project Stock ใบไหน (NULL = รอสร้าง)
  created_at      TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_sr_stock ON sales_requisitions (stock_id);
-- ตีกลับ SR ให้ฝ่ายขายแก้ (reply ขา Project → Sales)
ALTER TABLE sales_requisitions ADD COLUMN IF NOT EXISTS returned    BOOLEAN DEFAULT FALSE;
ALTER TABLE sales_requisitions ADD COLUMN IF NOT EXISTS return_note TEXT;

-- ---------- 2) customers (ฝ่ายขายสร้าง + แยกประเภท) — ผูก SR ผ่าน sr_id ----------
CREATE TABLE IF NOT EXISTS customers (
  id            BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  name          VARCHAR(255) NOT NULL UNIQUE,
  customer_type customer_type_t NOT NULL DEFAULT 'เอกชน',
  work_type     work_type_t     NOT NULL DEFAULT 'Supply',
  contact       VARCHAR(255),
  lbs_qty       INT NOT NULL DEFAULT 0,                   -- จำนวน LBS ที่ต้องการ (ใช้ reconcile กับ BOM)
  desired_date  DATE,
  location      VARCHAR(255),
  scope         TEXT,
  note          TEXT,
  cust_po_no      VARCHAR(80),                             -- เลขที่ PO จากลูกค้า (ติดตามแยก "รายชื่อลูกค้า")
  contract_status VARCHAR(40) NOT NULL DEFAULT 'รอ PO/สัญญา', -- สถานะสัญญาแยกตามลูกค้า
  term_of_payment VARCHAR(120),                            -- เงื่อนไขชำระเงิน (Term of payment)
  sr_id         BIGINT REFERENCES sales_requisitions(id) ON DELETE SET NULL,  -- อยู่ใน SR ใบไหน
  owner         UUID DEFAULT auth.uid(),
  created_at    TIMESTAMPTZ DEFAULT NOW(),
  updated_at    TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_customers_type ON customers (customer_type);
CREATE INDEX IF NOT EXISTS idx_customers_sr   ON customers (sr_id);
-- migration (ฐานข้อมูลเดิม): เพิ่มคอลัมน์ติดตาม PO/สัญญา รายลูกค้า + Term of payment
ALTER TABLE customers ADD COLUMN IF NOT EXISTS cust_po_no      VARCHAR(80);
ALTER TABLE customers ADD COLUMN IF NOT EXISTS contract_status VARCHAR(40) NOT NULL DEFAULT 'รอ PO/สัญญา';
ALTER TABLE customers ADD COLUMN IF NOT EXISTS term_of_payment VARCHAR(120);
ALTER TABLE customers ADD COLUMN IF NOT EXISTS project_name    TEXT;            -- ชื่อโครงการของลูกค้า (ฟอร์มเพิ่มลูกค้า)
ALTER TABLE customers ADD COLUMN IF NOT EXISTS contract_file_url  TEXT;         -- ไฟล์แนบ PO/สัญญา (บังคับเมื่อสถานะ=ได้รับ PO/ทำสัญญา)
ALTER TABLE customers ADD COLUMN IF NOT EXISTS contract_file_name TEXT;

-- ---------- 3) projects (Project Stock — รวมหลาย SR) ----------
CREATE TABLE IF NOT EXISTS projects (
  id                BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  project_stock_no  VARCHAR(40) UNIQUE,
  job_no            VARCHAR(40) UNIQUE,
  bom_no            VARCHAR(40) UNIQUE,                   -- Material List (BOM) No. (1 Stock = 1 BOM)
  bom_status        bom_status_t NOT NULL DEFAULT 'Draft',
  name              VARCHAR(255) NOT NULL,
  current_phase     phase_t      NOT NULL DEFAULT 'project',
  phase_acked       BOOLEAN DEFAULT FALSE,
  target_lbs        INT DEFAULT 0,                      -- จำนวน LBS เป้าหมายของ Stock (ถามตอนสร้าง, ใช้ reconcile กับ BOM)
  total_budget      NUMERIC(14,2) DEFAULT 0,
  margin            NUMERIC(6,2)  DEFAULT 0,
  cash_flow_status  VARCHAR(50)   DEFAULT 'ปกติ',
  delivery_date     DATE,
  do_signed         BOOLEAN DEFAULT FALSE,                -- ลงนาม DO แล้ว (ปิดงานได้)
  created_at        TIMESTAMPTZ DEFAULT NOW(),
  updated_at        TIMESTAMPTZ DEFAULT NOW()
);
ALTER TABLE projects ADD COLUMN IF NOT EXISTS bom_rounds JSONB DEFAULT '{}'::jsonb;   -- เมตาดาต้าราย Material List/ครั้ง: { "1": {cust_id}, ... } (Job No. + Ref ลูกค้า ต่อครั้ง)
CREATE INDEX IF NOT EXISTS idx_projects_phase    ON projects (current_phase);
CREATE INDEX IF NOT EXISTS idx_projects_delivery ON projects (delivery_date);

-- FK สองทาง: sr.stock_id → projects.id (เพิ่มหลัง projects ถูกสร้าง)
DO $$ BEGIN
  ALTER TABLE sales_requisitions
    ADD CONSTRAINT fk_sr_stock FOREIGN KEY (stock_id) REFERENCES projects(id) ON DELETE SET NULL;
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- ---------- 4) bom_items (คอลัมน์แบบ Epicor) ----------
CREATE TABLE IF NOT EXISTS bom_items (
  id            BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  project_id    BIGINT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  epicor_code   VARCHAR(60),
  description   VARCHAR(255) NOT NULL,
  category      VARCHAR(40)  NOT NULL DEFAULT 'LBS',      -- LBS | Accessory
  serial_lvb    VARCHAR(80),                              -- Serial LVB (กรอกเมื่อ category=LBS)
  serial_om     VARCHAR(80),                              -- Serial OM (กรอกเมื่อ category=LBS)
  due_date      DATE,
  ium           VARCHAR(20)  DEFAULT 'EA',                -- Inventory Unit of Measure
  quantity      INT          NOT NULL DEFAULT 0,
  currency      currency_t   NOT NULL DEFAULT 'THB',
  unit_cost     NUMERIC(14,2) DEFAULT 0,                  -- Cost per unit ในสกุล currency
  fx_rate       NUMERIC(10,4) NOT NULL DEFAULT 1,         -- ฿ ต่อ 1 หน่วยสกุล (THB = 1)
  project_phase VARCHAR(40)  DEFAULT 'Phase 1',
  po_status     po_status_t  NOT NULL DEFAULT 'Awaiting PO',
  po_id         BIGINT,                                   -- ลงใบ PO ใบไหน (NULL = ยังเลือกเข้าใบ PO ได้) — FK เพิ่มหลังสร้าง purchase_orders
  round         INT          NOT NULL DEFAULT 1,          -- "ครั้งที่" ของ Material List (1 Stock สร้าง BOM ได้หลายครั้ง: ครั้ง1/ครั้ง2…)
  is_sent       BOOLEAN      NOT NULL DEFAULT FALSE,      -- ส่งให้จัดซื้อแล้วหรือยัง (ส่งแยกรายครั้ง)
  created_at    TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_bom_project ON bom_items (project_id);
-- migration (ฐานข้อมูลเดิม): เพิ่มคอลัมน์รอบ BOM + Serial LVB/OM ถ้ายังไม่มี
ALTER TABLE bom_items ADD COLUMN IF NOT EXISTS round      INT     NOT NULL DEFAULT 1;
ALTER TABLE bom_items ADD COLUMN IF NOT EXISTS is_sent    BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE bom_items ADD COLUMN IF NOT EXISTS serial_lvb VARCHAR(80);
ALTER TABLE bom_items ADD COLUMN IF NOT EXISTS serial_om  VARCHAR(80);
ALTER TABLE bom_items ADD COLUMN IF NOT EXISTS cust_id    BIGINT REFERENCES customers(id) ON DELETE SET NULL;   -- อ้างลูกค้าของรายการ BOM (จำกัด LBS ต่อลูกค้า)
-- ของเดิมที่ Stock เคยส่งจัดซื้อแล้ว (bom_status) → ตั้ง is_sent=TRUE ให้รายการในนั้น
UPDATE bom_items b SET is_sent=TRUE FROM projects p WHERE b.project_id=p.id AND p.bom_status='Sent to Purchasing' AND b.is_sent=FALSE;

-- Total Cost เป็นบาท (USD คูณ fx_rate)
-- DROP ก่อน (view ใช้ b.* — เพิ่มคอลัมน์ใน bom_items ทำให้ลำดับคอลัมน์เปลี่ยน, CREATE OR REPLACE จะ error)
DROP VIEW IF EXISTS bom_value;
CREATE VIEW bom_value AS
  SELECT b.*, ROUND(b.quantity * b.unit_cost * b.fx_rate, 2) AS total_thb
  FROM bom_items b;

-- ---------- 5) purchase_orders (หลาย PO ต่อ Stock) ----------
CREATE TABLE IF NOT EXISTS purchase_orders (
  id            BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  project_id    BIGINT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  po_no         VARCHAR(40) NOT NULL UNIQUE,
  supplier      VARCHAR(255),
  status        po_doc_status_t NOT NULL DEFAULT 'รอออก',
  expected_date DATE,
  amount        NUMERIC(14,2) DEFAULT 0,
  bom_ids       BIGINT[] DEFAULT '{}',                    -- (legacy) รายการ BOM ในใบ PO
  lines         JSONB DEFAULT '[]',                       -- รายการ+จำนวนต่อรายการ: [{bom_id, qty}] (รองรับแยกบางส่วน)
  pdf_name      TEXT,                                     -- ชื่อไฟล์ PDF ที่แนบ
  pdf_url       TEXT,                                     -- data URL / Storage path ของไฟล์ PDF
  notified      BOOLEAN DEFAULT FALSE,                    -- แจ้งกลับฝ่ายโครงการแล้ว
  created_at    TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_po_project ON purchase_orders (project_id);

-- FK: bom_items.po_id → purchase_orders.id (เพิ่มหลัง purchase_orders ถูกสร้าง)
DO $$ BEGIN
  ALTER TABLE bom_items ADD CONSTRAINT fk_bom_po FOREIGN KEY (po_id) REFERENCES purchase_orders(id) ON DELETE SET NULL;
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- ---------- 6) department_tasks (งานฝ่ายขายผูกลูกค้า / ฝ่ายอื่นผูก Stock) ----------
CREATE TABLE IF NOT EXISTS department_tasks (
  id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  customer_id BIGINT REFERENCES customers(id) ON DELETE CASCADE,
  project_id  BIGINT REFERENCES projects(id)  ON DELETE CASCADE,
  department  department_t NOT NULL,
  task_title  VARCHAR(255) NOT NULL,
  task_detail TEXT,
  sort_order  INT DEFAULT 0,
  status      task_status_t NOT NULL DEFAULT 'Pending',
  updated_by  VARCHAR(120),
  updated_at  TIMESTAMPTZ DEFAULT NOW(),
  CONSTRAINT chk_task_owner CHECK ((customer_id IS NOT NULL) <> (project_id IS NOT NULL))
);
CREATE INDEX IF NOT EXISTS idx_tasks_customer ON department_tasks (customer_id);
CREATE INDEX IF NOT EXISTS idx_tasks_project  ON department_tasks (project_id);

-- ---------- 7) service_team + service_schedule (ทีมงาน + คิวงานรายเดือน) ----------
CREATE TABLE IF NOT EXISTS service_team (
  id       BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  emp_code VARCHAR(40),                                 -- รหัสพนักงาน
  name     VARCHAR(120) NOT NULL,
  role     VARCHAR(60),                                 -- ตำแหน่ง (กรอกเอง)
  phone    VARCHAR(40),
  active   BOOLEAN DEFAULT TRUE
);
ALTER TABLE service_team ADD COLUMN IF NOT EXISTS emp_code VARCHAR(40);   -- migration
CREATE TABLE IF NOT EXISTS service_schedule (
  id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  project_id  BIGINT REFERENCES projects(id)    ON DELETE CASCADE,
  member_id   BIGINT REFERENCES service_team(id) ON DELETE CASCADE,
  start_date  DATE NOT NULL,
  end_date    DATE,
  note        TEXT
);
CREATE INDEX IF NOT EXISTS idx_sched_member ON service_schedule (member_id);

-- ใบแผนส่งมอบ (Project → Service) — Service กดรับ (acked)
CREATE TABLE IF NOT EXISTS service_plans (
  id            BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  project_id    BIGINT REFERENCES projects(id) ON DELETE CASCADE,
  wd_no         VARCHAR(40),                              -- เลขใบเบิกติดตั้ง (Project ออก) WD-yyyy-000
  lines         JSONB DEFAULT '[]'::jsonb,                -- รายการเบิก [{bom_id, qty}]
  plan_start    DATE,                                     -- แผนดำเนินการเริ่ม
  plan_end      DATE,                                     -- แผนดำเนินการสิ้นสุด
  team_ids      JSONB DEFAULT '[]'::jsonb,                -- ทีมที่ Service เลือก [member_id]
  sent          BOOLEAN DEFAULT FALSE,                    -- ส่งมอบให้ Service แล้ว (ร่าง=false → ยังไม่ตัดสต็อก/ยังไม่เข้า inbox)
  delivery_date DATE,
  location      VARCHAR(255),
  team_need     VARCHAR(255),
  note          TEXT,
  acked         BOOLEAN DEFAULT FALSE,
  created_at    TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_plans_project ON service_plans (project_id);
-- migration (ฐานข้อมูลเดิม): ใบเบิกติดตั้ง + แผน start/end + ทีม
ALTER TABLE service_plans ADD COLUMN IF NOT EXISTS wd_no      VARCHAR(40);
ALTER TABLE service_plans ADD COLUMN IF NOT EXISTS lines      JSONB DEFAULT '[]'::jsonb;
ALTER TABLE service_plans ADD COLUMN IF NOT EXISTS plan_start DATE;
ALTER TABLE service_plans ADD COLUMN IF NOT EXISTS plan_end   DATE;
ALTER TABLE service_plans ADD COLUMN IF NOT EXISTS team_ids   JSONB DEFAULT '[]'::jsonb;
ALTER TABLE service_plans ADD COLUMN IF NOT EXISTS sent       BOOLEAN DEFAULT FALSE;
UPDATE service_plans SET sent=TRUE WHERE sent IS NOT TRUE;   -- ข้อมูลเดิมถือว่าส่งแล้ว
-- Service flow: เวลาปฏิบัติงานจริง + เอกสารส่งมอบ + สถานะส่งมอบ
ALTER TABLE service_plans ADD COLUMN IF NOT EXISTS actual_start DATE;
ALTER TABLE service_plans ADD COLUMN IF NOT EXISTS actual_end   DATE;
ALTER TABLE service_plans ADD COLUMN IF NOT EXISTS proof_name   TEXT;
ALTER TABLE service_plans ADD COLUMN IF NOT EXISTS proof_url    TEXT;
ALTER TABLE service_plans ADD COLUMN IF NOT EXISTS delivered    BOOLEAN DEFAULT FALSE;
ALTER TABLE service_plans ADD COLUMN IF NOT EXISTS sr_id        BIGINT REFERENCES sales_requisitions(id) ON DELETE SET NULL;   -- เบิกอ้าง SR-No.
ALTER TABLE service_plans ADD COLUMN IF NOT EXISTS cust_id      BIGINT REFERENCES customers(id) ON DELETE SET NULL;            -- เบิกแยกต่อลูกค้า (1 ใบเบิก/ลูกค้า)
ALTER TABLE service_plans ADD COLUMN IF NOT EXISTS checkin_lat  DOUBLE PRECISION;   -- พิกัด Check-in ตอนทีมทำ Report (Map Tracking)
ALTER TABLE service_plans ADD COLUMN IF NOT EXISTS checkin_lng  DOUBLE PRECISION;
ALTER TABLE service_plans ADD COLUMN IF NOT EXISTS checkin_at   TIMESTAMPTZ;
-- Service flow: เช็กลิสต์หน้างาน + ลูกค้าเซ็นรับ + ใบรับประกัน
ALTER TABLE service_plans ADD COLUMN IF NOT EXISTS checklist      JSONB DEFAULT '{}'::jsonb;
ALTER TABLE service_plans ADD COLUMN IF NOT EXISTS received_by    VARCHAR(120);
ALTER TABLE service_plans ADD COLUMN IF NOT EXISTS received_date  DATE;
ALTER TABLE service_plans ADD COLUMN IF NOT EXISTS warranty_no    VARCHAR(60);
ALTER TABLE service_plans ADD COLUMN IF NOT EXISTS warranty_until DATE;
-- เพิ่มสวิตช์แจ้งเตือน event ใบรับประกัน
ALTER TABLE notif_settings ADD COLUMN IF NOT EXISTS ev_warranty BOOLEAN DEFAULT TRUE;

-- คลังสินค้าจริง (Inventory) — บันทึกรับเข้า/เบิกออกด้วยมือ · project_id NULL = สต็อกกลาง
CREATE TABLE IF NOT EXISTS inventory_moves (
  id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  epicor_code VARCHAR(60) NOT NULL,
  description VARCHAR(255),
  project_id  BIGINT REFERENCES projects(id) ON DELETE SET NULL,   -- NULL = คลังกลาง
  type        VARCHAR(3) NOT NULL CHECK (type IN ('IN','OUT')),
  reason      VARCHAR(40),                                          -- รับตาม PO/รับเข้าทั่วไป/รับโอน · ติดตั้งงาน/โอนเข้าโครงการ/คืนผู้ขาย/ชำรุด
  po_no       VARCHAR(40),                                          -- อ้างอิง PO (กรณีรับตาม PO)
  qty         INT NOT NULL DEFAULT 0,
  note        TEXT,
  "by"        VARCHAR(60),                                          -- ฝ่ายที่บันทึก (label เช่น Project/Service) ที่แอปส่งมา
  by_user     UUID DEFAULT auth.uid(),
  created_at  TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_inv_code    ON inventory_moves (epicor_code);
CREATE INDEX IF NOT EXISTS idx_inv_project ON inventory_moves (project_id);
-- migration (ฐานข้อมูลเดิมที่สร้างก่อนคอลัมน์เหล่านี้จะถูกเพิ่ม — CREATE IF NOT EXISTS ไม่เพิ่มให้ตารางเดิม)
ALTER TABLE inventory_moves ADD COLUMN IF NOT EXISTS description VARCHAR(255);
ALTER TABLE inventory_moves ADD COLUMN IF NOT EXISTS reason      VARCHAR(40);
ALTER TABLE inventory_moves ADD COLUMN IF NOT EXISTS po_no       VARCHAR(40);
ALTER TABLE inventory_moves ADD COLUMN IF NOT EXISTS note        TEXT;
ALTER TABLE inventory_moves ADD COLUMN IF NOT EXISTS "by"        VARCHAR(60);

-- migration: ขยายช่องกรอก "อิสระ" เป็น TEXT — กัน error "value too long for type character varying"
-- ปลอดภัย ไม่กระทบข้อมูลเดิม (varchar→text ไม่ตัด/ไม่แปลงค่า) · รันซ้ำได้ (ถ้าเป็น text อยู่แล้ว = no-op)
ALTER TABLE customers       ALTER COLUMN contact         TYPE TEXT;
ALTER TABLE customers       ALTER COLUMN location        TYPE TEXT;
ALTER TABLE customers       ALTER COLUMN cust_po_no      TYPE TEXT;
ALTER TABLE customers       ALTER COLUMN term_of_payment TYPE TEXT;
-- bom_items: view bom_value อ้าง b.* → ต้อง DROP view ก่อนเปลี่ยน type แล้วสร้างใหม่
DROP VIEW IF EXISTS bom_value;
ALTER TABLE bom_items       ALTER COLUMN epicor_code     TYPE TEXT;
ALTER TABLE bom_items       ALTER COLUMN project_phase   TYPE TEXT;
CREATE VIEW bom_value AS
  SELECT b.*, ROUND(b.quantity * b.unit_cost * b.fx_rate, 2) AS total_thb
  FROM bom_items b;
ALTER TABLE service_team    ALTER COLUMN name            TYPE TEXT;
ALTER TABLE service_team    ALTER COLUMN role            TYPE TEXT;
ALTER TABLE service_plans   ALTER COLUMN location        TYPE TEXT;
ALTER TABLE service_plans   ALTER COLUMN received_by     TYPE TEXT;
ALTER TABLE department_tasks ALTER COLUMN updated_by     TYPE TEXT;

-- บล็อกการเบิก/โอนออกเกินยอดคงเหลือ ณ ที่ตั้งนั้น (สต็อกห้ามติดลบ)
CREATE OR REPLACE FUNCTION inv_block_negative()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE onhand INT;
BEGIN
  IF NEW.type = 'OUT' THEN
    SELECT COALESCE(SUM(CASE WHEN type='IN' THEN qty ELSE -qty END),0) INTO onhand
      FROM inventory_moves
      WHERE epicor_code = NEW.epicor_code AND project_id IS NOT DISTINCT FROM NEW.project_id;
    IF onhand - NEW.qty < 0 THEN
      RAISE EXCEPTION 'สต็อกไม่พอ: % ที่ตั้งนี้คงเหลือ % เบิก/โอน %', NEW.epicor_code, onhand, NEW.qty;
    END IF;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_inv_negative ON inventory_moves;
CREATE TRIGGER trg_inv_negative BEFORE INSERT ON inventory_moves FOR EACH ROW EXECUTE FUNCTION inv_block_negative();
-- มุมมองยอดคงเหลือกลางต่อรหัสวัสดุ
CREATE OR REPLACE VIEW inventory_balance AS
  SELECT epicor_code, MAX(description) AS description,
         SUM(CASE WHEN type='IN' THEN qty ELSE 0 END)  AS in_qty,
         SUM(CASE WHEN type='OUT' THEN qty ELSE 0 END) AS out_qty,
         SUM(CASE WHEN type='IN' THEN qty ELSE -qty END) AS on_hand
  FROM inventory_moves GROUP BY epicor_code;

-- ---------- 8) handoff_log (audit + แหล่ง "งานเข้าใหม่") ----------
CREATE TABLE IF NOT EXISTS handoff_log (
  id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  customer_id BIGINT REFERENCES customers(id) ON DELETE CASCADE,
  sr_id       BIGINT REFERENCES sales_requisitions(id) ON DELETE CASCADE,
  project_id  BIGINT REFERENCES projects(id)  ON DELETE CASCADE,
  from_phase  phase_t,
  to_phase    phase_t,
  action      handoff_act_t NOT NULL,
  by_dept     department_t,
  by_user     UUID DEFAULT auth.uid(),
  note        TEXT,
  acked       BOOLEAN DEFAULT FALSE,
  created_at  TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_handoff_to ON handoff_log (to_phase, acked);

-- ---------- 9) user_roles ----------
CREATE TABLE IF NOT EXISTS user_roles (
  user_id      UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  department   department_t NOT NULL DEFAULT 'sales',
  is_developer BOOLEAN DEFAULT FALSE,
  created_at   TIMESTAMPTZ DEFAULT NOW()
);

-- ---------- 10) Helper functions ----------
CREATE OR REPLACE FUNCTION current_department()
RETURNS department_t LANGUAGE sql SECURITY DEFINER STABLE AS $$
  SELECT department FROM user_roles WHERE user_id = auth.uid();
$$;
CREATE OR REPLACE FUNCTION is_developer()
RETURNS BOOLEAN LANGUAGE sql SECURITY DEFINER STABLE AS $$
  SELECT COALESCE((SELECT is_developer FROM user_roles WHERE user_id = auth.uid()), FALSE);
$$;
CREATE OR REPLACE FUNCTION touch_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at = NOW(); RETURN NEW; END $$;
DROP TRIGGER IF EXISTS trg_customers_touch ON customers;
CREATE TRIGGER trg_customers_touch BEFORE UPDATE ON customers FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
DROP TRIGGER IF EXISTS trg_projects_touch ON projects;
CREATE TRIGGER trg_projects_touch BEFORE UPDATE ON projects FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
DROP TRIGGER IF EXISTS trg_tasks_touch ON department_tasks;
CREATE TRIGGER trg_tasks_touch BEFORE UPDATE ON department_tasks FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

-- ลูกค้าใหม่ → สร้างงานฝ่ายขายอัตโนมัติ
CREATE OR REPLACE FUNCTION seed_customer_tasks()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO department_tasks (customer_id, department, task_title, task_detail, sort_order, status)
  SELECT NEW.id, 'sales', t.title, t.detail, t.ord, 'Pending'::task_status_t
  FROM (VALUES
    ('เพิ่ม & บันทึกข้อมูลลูกค้า','ชื่อ ประเภท งาน ผู้ติดต่อ จำนวน LBS วันที่ สถานที่ Scope',0),
    ('รวบรวมส่งฝ่ายโครงการ (ออก SR No.)','เลือกลูกค้ารวบรวมเป็น Sales Requisition',1),
    ('ติดตาม PO & สัญญาซื้อขาย','ติดตาม PO/สัญญาจากลูกค้า อัปเดตใน SR',2)
  ) AS t(title,detail,ord);
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_customer_tasks ON customers;
CREATE TRIGGER trg_customer_tasks AFTER INSERT ON customers FOR EACH ROW EXECUTE FUNCTION seed_customer_tasks();

-- Project Stock ใหม่ → สร้างงานฝ่ายโครงการ/จัดซื้อ/บริการอัตโนมัติ
CREATE OR REPLACE FUNCTION seed_project_tasks()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO department_tasks (project_id, department, task_title, task_detail, sort_order, status)
  SELECT NEW.id, x.dep::department_t, x.title, x.detail, x.ord, 'Pending'::task_status_t
  FROM (VALUES
    ('project','ทบทวน Sales Requisition ที่รับเข้า','ตรวจ SR: จำนวน LBS, ประเภทงาน, วันที่, สถานที่',0),
    ('project','สร้าง Project Stock & งบประมาณ','รวม SR เป็น Stock No. · ออก Job No. · ต้นทุน/กำไร',1),
    ('project','จัดทำ Material List (BOM)','LBS & Accessory: Epicor Code, Due Date, IUM, Cost, Phase',2),
    ('project','ตรวจสอบจำนวน LBS เทียบ SR','ยอด LBS ใน BOM ต้องตรงกับที่ลูกค้าต้องการ',3),
    ('project','ส่ง Material List (BOM) ให้จัดซื้อ','ส่ง BOM No. ไปฝ่ายจัดซื้อ',4),
    ('project','แจ้งแผนส่งมอบให้ฝ่ายบริการ','ส่งแผนวันส่ง/ติดตั้งให้ฝ่ายบริการ',5),
    ('purchasing','รับ BOM & ออก PO','ออก PO ตาม Material List (BOM) No.',0),
    ('purchasing','อัปเดต PO แจ้งกลับฝ่ายโครงการ','อัปเดตสถานะ PO ราย BOM',1),
    ('purchasing','ติดตามวันส่งมอบ แจ้งกลับฝ่ายโครงการ','ติดตามของเข้า/วันส่ง',2),
    ('service','รับแผนวันส่ง/ติดตั้ง','รับแผนส่งมอบจากฝ่ายโครงการ',0),
    ('service','จัดทีมงาน','มอบหมายทีม + จัดตารางคิวงานรายเดือน',1),
    ('service','ส่งมอบ & ลงนาม DO','ส่งมอบ/ติดตั้ง ลงนาม DO ปิดงาน',2)
  ) AS x(dep, title, detail, ord);
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_project_tasks ON projects;
CREATE TRIGGER trg_project_tasks AFTER INSERT ON projects FOR EACH ROW EXECUTE FUNCTION seed_project_tasks();

-- ---------- 11) Linkage RPC (บังคับสิทธิ์ + business gate ฝั่ง server) ----------
-- สร้าง Project Stock จากหลาย SR (Project)
CREATE OR REPLACE FUNCTION create_stock_multi(sr_ids BIGINT[], p_stock_no TEXT, p_job_no TEXT, p_bom_no TEXT, p_name TEXT, p_target_lbs INT DEFAULT 0)
RETURNS BIGINT LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE new_id BIGINT; mydept department_t; deliv DATE;
BEGIN
  mydept := current_department();
  IF NOT (is_developer() OR mydept = 'project') THEN RAISE EXCEPTION 'เฉพาะฝ่ายโครงการสร้าง Stock ได้'; END IF;
  -- วันส่งมอบ = วันที่ต้องการเร็วสุดของลูกค้าใน SR ที่รวมเข้ามา
  SELECT MIN(c.desired_date) INTO deliv FROM customers c WHERE c.sr_id = ANY(sr_ids);
  INSERT INTO projects (project_stock_no, job_no, bom_no, name, current_phase, phase_acked, delivery_date, target_lbs)
    VALUES (p_stock_no, p_job_no, p_bom_no, p_name, 'project', FALSE, deliv, COALESCE(p_target_lbs,0))
    RETURNING id INTO new_id;
  UPDATE sales_requisitions SET stock_id = new_id WHERE id = ANY(sr_ids);
  INSERT INTO handoff_log(project_id, from_phase, to_phase, action, by_dept)
    VALUES (new_id, 'sales', 'project', 'create', mydept);
  RETURN new_id;
END $$;

-- ส่งงานต่อ (พร้อมตรวจ gate ตามเฟส — review fix: ไม่ให้ข้าม gate ผ่าน RPC)
CREATE OR REPLACE FUNCTION handoff_project(p_id BIGINT)
RETURNS phase_t LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE cur phase_t; nxt phase_t; mydept department_t; bs bom_status_t;
        req INT; got INT; pending INT;
        seq TEXT[] := ARRAY['project','purchasing','service','closed']; i INT;
BEGIN
  SELECT current_phase, bom_status INTO cur, bs FROM projects WHERE id = p_id;
  mydept := current_department();
  IF NOT (is_developer() OR mydept::text = cur::text) THEN
    RAISE EXCEPTION 'ฝ่ายของคุณไม่ใช่เจ้าของเฟสปัจจุบัน (%)', cur;
  END IF;
  -- ทุกงานในเฟสต้องเสร็จ
  IF EXISTS (SELECT 1 FROM department_tasks WHERE project_id=p_id AND department::text=cur::text AND status<>'Completed')
     OR NOT EXISTS (SELECT 1 FROM department_tasks WHERE project_id=p_id AND department::text=cur::text)
  THEN RAISE EXCEPTION 'งานในเฟสนี้ยังไม่ครบทุกข้อ'; END IF;
  -- gate เฉพาะเฟส
  IF cur = 'project' THEN
    IF (SELECT job_no FROM projects WHERE id=p_id) IS NULL THEN RAISE EXCEPTION 'ยังไม่มี Job No.'; END IF;
    IF NOT EXISTS (SELECT 1 FROM bom_items WHERE project_id=p_id) THEN RAISE EXCEPTION 'ยังไม่มีรายการ BOM'; END IF;
    IF EXISTS (SELECT 1 FROM bom_items WHERE project_id=p_id AND is_sent=FALSE) THEN RAISE EXCEPTION 'ยังส่ง BOM ให้จัดซื้อไม่ครบทุกครั้ง (ครั้ง/รอบ)'; END IF;
    SELECT COALESCE(target_lbs,0) INTO req FROM projects WHERE id=p_id;        -- เป้าหมาย LBS ของ Stock
    SELECT COALESCE(SUM(quantity),0) INTO got FROM bom_items WHERE project_id=p_id AND category='LBS';
    IF req <> got THEN RAISE EXCEPTION 'จำนวน LBS ใน BOM (%) ไม่ตรงกับเป้าหมาย Stock (%)', got, req; END IF;
  ELSIF cur = 'purchasing' THEN
    SELECT COUNT(*) INTO pending FROM bom_items WHERE project_id=p_id AND po_status<>'Delivered';
    IF pending > 0 THEN RAISE EXCEPTION 'ของยังเข้าไม่ครบ (ต้อง Delivered ทุกรายการ)'; END IF;
  ELSIF cur = 'service' THEN
    IF NOT (SELECT do_signed FROM projects WHERE id=p_id) THEN RAISE EXCEPTION 'ยังไม่ได้ลงนาม DO'; END IF;
    -- ปิดงานได้เมื่อทุกใบเบิก (sent) ส่งมอบครบ (กันปิดก่อนกำหนดเมื่อมีหลายใบเบิก/ลูกค้า)
    SELECT COUNT(*) INTO pending FROM service_plans WHERE project_id=p_id AND sent=TRUE AND delivered IS NOT TRUE;
    IF pending > 0 THEN RAISE EXCEPTION 'ยังส่งมอบใบเบิกไม่ครบ (เหลือ % ใบ)', pending; END IF;
  END IF;
  i := array_position(seq, cur::text);
  IF i IS NULL OR i >= array_length(seq,1) THEN RAISE EXCEPTION 'ไม่มีเฟสถัดไป'; END IF;
  nxt := seq[i+1]::phase_t;
  UPDATE projects SET current_phase = nxt, phase_acked = FALSE WHERE id = p_id;
  INSERT INTO handoff_log(project_id, from_phase, to_phase, action, by_dept)
    VALUES (p_id, cur, nxt, 'forward', mydept);
  RETURN nxt;
END $$;

-- เสร็จ & ส่งต่อ (ปุ่มเดียวจบ) — ปิดงานที่เหลือของเฟสปัจจุบันให้อัตโนมัติ แล้วส่งต่อผ่าน gate เดิม
-- atomic: ถ้า gate ข้อมูลไม่ผ่าน (เช่น LBS/Delivered/DO) → ทั้งธุรกรรม rollback (งานไม่ถูก mark เสร็จค้าง)
CREATE OR REPLACE FUNCTION complete_and_handoff(p_id BIGINT)
RETURNS phase_t LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE cur phase_t; mydept department_t;
BEGIN
  SELECT current_phase INTO cur FROM projects WHERE id = p_id;
  mydept := current_department();
  IF NOT (is_developer() OR mydept::text = cur::text) THEN
    RAISE EXCEPTION 'ฝ่ายของคุณไม่ใช่เจ้าของเฟสปัจจุบัน (%)', cur;
  END IF;
  -- ปิดงานที่เหลือของเฟสนี้ให้เสร็จทั้งหมด (แทนการติ๊กทีละข้อ)
  UPDATE department_tasks SET status='Completed'
    WHERE project_id = p_id AND department::text = cur::text AND status <> 'Completed';
  -- ส่งต่อด้วย logic+gate เดิม (ตรวจ Job/BOM/LBS/Delivered/DO ครบ)
  RETURN handoff_project(p_id);
END $$;

CREATE OR REPLACE FUNCTION reject_project(p_id BIGINT, p_note TEXT)
RETURNS phase_t LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE cur phase_t; prv phase_t; mydept department_t;
        seq TEXT[] := ARRAY['project','purchasing','service','closed']; i INT;
BEGIN
  IF p_note IS NULL OR length(trim(p_note))=0 THEN RAISE EXCEPTION 'ต้องระบุเหตุผลการตีกลับ'; END IF;
  SELECT current_phase INTO cur FROM projects WHERE id = p_id;
  mydept := current_department();
  IF NOT (is_developer() OR mydept::text = cur::text) THEN
    RAISE EXCEPTION 'ฝ่ายของคุณไม่ใช่เจ้าของเฟสปัจจุบัน (%)', cur;
  END IF;
  i := array_position(seq, cur::text);
  IF i IS NULL OR i <= 1 THEN RAISE EXCEPTION 'ตีกลับไม่ได้ (เฟสแรกสุด)'; END IF;
  prv := seq[i-1]::phase_t;
  UPDATE projects SET current_phase = prv, phase_acked = FALSE WHERE id = p_id;
  INSERT INTO handoff_log(project_id, from_phase, to_phase, action, by_dept, note)
    VALUES (p_id, cur, prv, 'reject', mydept, p_note);
  RETURN prv;
END $$;

CREATE OR REPLACE FUNCTION ack_phase(p_id BIGINT)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE cur phase_t; mydept department_t;
BEGIN
  SELECT current_phase INTO cur FROM projects WHERE id = p_id;
  mydept := current_department();
  IF NOT (is_developer() OR mydept::text = cur::text) THEN
    RAISE EXCEPTION 'รับงานได้เฉพาะฝ่ายเจ้าของเฟส (%)', cur;
  END IF;
  UPDATE projects SET phase_acked = TRUE WHERE id = p_id;
  UPDATE handoff_log SET acked = TRUE WHERE project_id = p_id AND to_phase = cur AND acked = FALSE;
END $$;

-- ---------- 11b) Admin RPC (แท็บ Setting — เฉพาะ developer) ----------
-- รายชื่อผู้ใช้ทั้งหมด + บทบาท (อ่าน auth.users ได้เพราะ SECURITY DEFINER)
CREATE OR REPLACE FUNCTION admin_list_users()
RETURNS TABLE(user_id UUID, email TEXT, department department_t, is_developer BOOLEAN, created_at TIMESTAMPTZ)
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF NOT is_developer() THEN RAISE EXCEPTION 'เฉพาะผู้ดูแล (developer)'; END IF;
  RETURN QUERY
    SELECT u.id, u.email::text, r.department, COALESCE(r.is_developer,FALSE), u.created_at
    FROM auth.users u LEFT JOIN user_roles r ON r.user_id = u.id
    ORDER BY u.created_at;
END $$;

-- อนุมัติ/แก้สิทธิ์ผู้ใช้
CREATE OR REPLACE FUNCTION admin_set_role(p_uid UUID, p_dept department_t, p_dev BOOLEAN)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF NOT is_developer() THEN RAISE EXCEPTION 'เฉพาะผู้ดูแล (developer)'; END IF;
  INSERT INTO user_roles(user_id, department, is_developer)
    VALUES (p_uid, COALESCE(p_dept,'sales'), COALESCE(p_dev,FALSE))
    ON CONFLICT (user_id) DO UPDATE SET department = EXCLUDED.department, is_developer = EXCLUDED.is_developer;
END $$;

-- ยกเลิกสิทธิ์ (กลับเป็น "รออนุมัติ")
CREATE OR REPLACE FUNCTION admin_revoke(p_uid UUID)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF NOT is_developer() THEN RAISE EXCEPTION 'เฉพาะผู้ดูแล (developer)'; END IF;
  DELETE FROM user_roles WHERE user_id = p_uid;
END $$;

-- ---------- 12) Row Level Security ----------
ALTER TABLE sales_requisitions ENABLE ROW LEVEL SECURITY;
ALTER TABLE customers          ENABLE ROW LEVEL SECURITY;
ALTER TABLE projects           ENABLE ROW LEVEL SECURITY;
ALTER TABLE bom_items          ENABLE ROW LEVEL SECURITY;
ALTER TABLE purchase_orders    ENABLE ROW LEVEL SECURITY;
ALTER TABLE department_tasks   ENABLE ROW LEVEL SECURITY;
ALTER TABLE service_team       ENABLE ROW LEVEL SECURITY;
ALTER TABLE service_schedule   ENABLE ROW LEVEL SECURITY;
ALTER TABLE handoff_log        ENABLE ROW LEVEL SECURITY;
ALTER TABLE user_roles         ENABLE ROW LEVEL SECURITY;

-- READ: ทุกฝ่ายที่ล็อกอินอ่านได้หมด
DROP POLICY IF EXISTS p_sr_read ON sales_requisitions;   CREATE POLICY p_sr_read   ON sales_requisitions FOR SELECT TO authenticated USING (TRUE);
DROP POLICY IF EXISTS p_cust_read ON customers;          CREATE POLICY p_cust_read ON customers        FOR SELECT TO authenticated USING (TRUE);
DROP POLICY IF EXISTS p_proj_read ON projects;           CREATE POLICY p_proj_read ON projects         FOR SELECT TO authenticated USING (TRUE);
DROP POLICY IF EXISTS p_bom_read ON bom_items;           CREATE POLICY p_bom_read  ON bom_items        FOR SELECT TO authenticated USING (TRUE);
DROP POLICY IF EXISTS p_po_read ON purchase_orders;      CREATE POLICY p_po_read   ON purchase_orders  FOR SELECT TO authenticated USING (TRUE);
DROP POLICY IF EXISTS p_task_read ON department_tasks;   CREATE POLICY p_task_read ON department_tasks  FOR SELECT TO authenticated USING (TRUE);
DROP POLICY IF EXISTS p_team_read ON service_team;       CREATE POLICY p_team_read ON service_team     FOR SELECT TO authenticated USING (TRUE);
DROP POLICY IF EXISTS p_sched_read ON service_schedule;  CREATE POLICY p_sched_read ON service_schedule FOR SELECT TO authenticated USING (TRUE);
DROP POLICY IF EXISTS p_handoff_read ON handoff_log;     CREATE POLICY p_handoff_read ON handoff_log   FOR SELECT TO authenticated USING (TRUE);

-- WRITE customers + sales_requisitions: ฝ่ายขาย + developer
DROP POLICY IF EXISTS p_cust_write ON customers;
CREATE POLICY p_cust_write ON customers FOR ALL TO authenticated
  USING (is_developer() OR current_department() = 'sales')
  WITH CHECK (is_developer() OR current_department() = 'sales');
DROP POLICY IF EXISTS p_sr_write ON sales_requisitions;
CREATE POLICY p_sr_write ON sales_requisitions FOR ALL TO authenticated
  USING (is_developer() OR current_department() = 'sales')
  WITH CHECK (is_developer() OR current_department() = 'sales');

-- WRITE projects: insert/update ฝ่ายโครงการ + ฝ่ายเจ้าของเฟส; ลบเฉพาะ developer
DROP POLICY IF EXISTS p_proj_ins ON projects;
CREATE POLICY p_proj_ins ON projects FOR INSERT TO authenticated
  WITH CHECK (is_developer() OR current_department() = 'project');
DROP POLICY IF EXISTS p_proj_upd ON projects;
CREATE POLICY p_proj_upd ON projects FOR UPDATE TO authenticated
  USING (is_developer() OR current_department() = 'project' OR current_department()::text = current_phase::text)
  WITH CHECK (is_developer() OR current_department() = 'project' OR current_department()::text = current_phase::text);
DROP POLICY IF EXISTS p_proj_del ON projects;
-- ฝ่ายโครงการลบ Project ของฝ่ายตนได้ (CRUD ฝ่ายตน) · developer ลบได้ทุกอัน
CREATE POLICY p_proj_del ON projects FOR DELETE TO authenticated USING (is_developer() OR current_department() = 'project');

-- WRITE bom_items: ฝ่ายโครงการ (สร้าง/แก้ BOM) + ฝ่ายจัดซื้อ (อัปเดต po_status) + developer
DROP POLICY IF EXISTS p_bom_write ON bom_items;
CREATE POLICY p_bom_write ON bom_items FOR ALL TO authenticated
  USING (is_developer() OR current_department() IN ('project','purchasing'))
  WITH CHECK (is_developer() OR current_department() IN ('project','purchasing'));

-- WRITE purchase_orders: ฝ่ายจัดซื้อ + developer
DROP POLICY IF EXISTS p_po_write ON purchase_orders;
CREATE POLICY p_po_write ON purchase_orders FOR ALL TO authenticated
  USING (is_developer() OR current_department() = 'purchasing')
  WITH CHECK (is_developer() OR current_department() = 'purchasing');

-- WRITE department_tasks: เฉพาะงานของฝ่ายตนเอง
DROP POLICY IF EXISTS p_task_upd ON department_tasks;
CREATE POLICY p_task_upd ON department_tasks FOR UPDATE TO authenticated
  USING (is_developer() OR department = current_department())
  WITH CHECK (is_developer() OR department = current_department());
DROP POLICY IF EXISTS p_task_ins ON department_tasks;
CREATE POLICY p_task_ins ON department_tasks FOR INSERT TO authenticated
  WITH CHECK (is_developer() OR department = current_department());
DROP POLICY IF EXISTS p_task_del ON department_tasks;
CREATE POLICY p_task_del ON department_tasks FOR DELETE TO authenticated
  USING (is_developer() OR department = current_department());

-- WRITE service_team + service_schedule: ฝ่ายบริการ + developer
DROP POLICY IF EXISTS p_team_write ON service_team;
CREATE POLICY p_team_write ON service_team FOR ALL TO authenticated
  USING (is_developer() OR current_department() = 'service')
  WITH CHECK (is_developer() OR current_department() = 'service');
DROP POLICY IF EXISTS p_sched_write ON service_schedule;
CREATE POLICY p_sched_write ON service_schedule FOR ALL TO authenticated
  USING (is_developer() OR current_department() = 'service')
  WITH CHECK (is_developer() OR current_department() = 'service');

-- ใบแผนส่งมอบ: อ่านได้ทุกฝ่าย · สร้างโดยฝ่ายโครงการ (ส่งแผน) · ฝ่ายบริการกดรับ (update acked)
ALTER TABLE service_plans ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS p_plans_read ON service_plans;   CREATE POLICY p_plans_read   ON service_plans FOR SELECT TO authenticated USING (TRUE);
DROP POLICY IF EXISTS p_plans_ins ON service_plans;    CREATE POLICY p_plans_ins    ON service_plans FOR INSERT TO authenticated WITH CHECK (is_developer() OR current_department() = 'project');
-- UPDATE: project (ตั้ง sent ตอนส่งมอบ) + service (กดรับ acked/team) + dev
DROP POLICY IF EXISTS p_plans_upd ON service_plans;    CREATE POLICY p_plans_upd    ON service_plans FOR UPDATE TO authenticated USING (is_developer() OR current_department() IN ('service','project')) WITH CHECK (is_developer() OR current_department() IN ('service','project'));
-- DELETE: ฝ่ายโครงการลบร่างใบเบิกได้ + dev
DROP POLICY IF EXISTS p_plans_del ON service_plans;    CREATE POLICY p_plans_del    ON service_plans FOR DELETE TO authenticated USING (is_developer() OR current_department() = 'project');

-- ---------- ตั้งค่าการแจ้งเตือน (LINE/Email) — แถวเดียว (id=1) จัดการโดย Developer ----------
CREATE TABLE IF NOT EXISTS notif_settings (
  id            INT PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  line_enabled  BOOLEAN DEFAULT FALSE,
  line_token    TEXT,                                     -- LINE channel access token (อ่านได้เฉพาะ developer)
  line_to       TEXT,                                     -- userId/groupId คั่นด้วย ,
  email_enabled BOOLEAN DEFAULT FALSE,
  email_to      TEXT,                                     -- อีเมลผู้รับ คั่นด้วย ,
  function_url  TEXT,                                     -- Edge Function endpoint
  ev_sr BOOLEAN DEFAULT TRUE, ev_stock BOOLEAN DEFAULT TRUE, ev_bom BOOLEAN DEFAULT TRUE,
  ev_po BOOLEAN DEFAULT TRUE, ev_handover BOOLEAN DEFAULT TRUE, ev_do BOOLEAN DEFAULT TRUE, ev_warranty BOOLEAN DEFAULT TRUE,
  updated_at    TIMESTAMPTZ DEFAULT NOW()
);
INSERT INTO notif_settings (id) VALUES (1) ON CONFLICT (id) DO NOTHING;
-- อ่านได้ทุกฝ่ายที่ล็อกอิน (ให้ notify() ของทุก role ส่งแจ้งเตือนได้ ไม่ใช่เฉพาะ dev) · แก้ไขเฉพาะ developer
-- หมายเหตุความปลอดภัย: line_token อยู่ในตารางนี้ → พนักงานที่ล็อกอินอ่านได้ · ถ้าต้องการซ่อน token
--   ให้ย้ายไปเป็น Edge secret (supabase secrets set LINE_CHANNEL_ACCESS_TOKEN=...) แล้วเว้นช่อง token ว่าง
ALTER TABLE notif_settings ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS p_notif_all ON notif_settings;
DROP POLICY IF EXISTS p_notif_read ON notif_settings;
CREATE POLICY p_notif_read  ON notif_settings FOR SELECT TO authenticated USING (TRUE);
DROP POLICY IF EXISTS p_notif_write ON notif_settings;
CREATE POLICY p_notif_write ON notif_settings FOR ALL TO authenticated USING (is_developer()) WITH CHECK (is_developer());

-- คลังสินค้า: อ่านได้ทุกฝ่าย · บันทึกรับ/เบิกได้ developer + purchasing/project/service
ALTER TABLE inventory_moves ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS p_inv_read ON inventory_moves;   CREATE POLICY p_inv_read  ON inventory_moves FOR SELECT TO authenticated USING (TRUE);
DROP POLICY IF EXISTS p_inv_write ON inventory_moves;  CREATE POLICY p_inv_write ON inventory_moves FOR ALL TO authenticated
  USING (is_developer() OR current_department() IN ('purchasing','project','service'))
  WITH CHECK (is_developer() OR current_department() IN ('purchasing','project','service'));

-- handoff_log: เขียนผ่าน RPC (SECURITY DEFINER) เท่านั้น — ปิด insert ตรงจาก client (กัน log ปลอม)
DROP POLICY IF EXISTS p_handoff_insert ON handoff_log;

DROP POLICY IF EXISTS p_roles_self ON user_roles;
CREATE POLICY p_roles_self ON user_roles FOR SELECT TO authenticated USING (user_id = auth.uid() OR is_developer());

-- ---------- 13) SEED DATA (ข้อมูลตัวอย่าง) — แยกออกไปแล้ว ----------
-- ไฟล์นี้ (schema.sql) เป็น "โครงสร้างล้วน": ปลอดภัยรันซ้ำได้ทุกเมื่อ ไม่แตะ/ไม่สร้างข้อมูล
--   (ทุกอย่างเป็น CREATE ... IF NOT EXISTS / ADD COLUMN IF NOT EXISTS / CREATE OR REPLACE)
-- ต้องการข้อมูลสาธิตบนฐานข้อมูลเปล่า → รัน  seed-demo.sql  แยกต่างหาก (อย่ารันบน production)

-- ---------- 14) Bootstrap Developer ----------
-- กำหนด siradanai.s@precise.co.th เป็น Developer อัตโนมัติ (รันได้เลย · ถ้ายังไม่สมัคร = no-op, สมัครแล้วรันซ้ำได้)
INSERT INTO user_roles (user_id, department, is_developer)
SELECT id, 'developer', TRUE FROM auth.users WHERE email = 'siradanai.s@precise.co.th'
ON CONFLICT (user_id) DO UPDATE SET is_developer = TRUE, department = 'developer';

-- =====================================================================
--  Bootstrap หลังสมัครผู้ใช้ผ่านเว็บ:
--    -- Developer คนอื่น ๆ:
--    INSERT INTO user_roles (user_id, department, is_developer)
--    SELECT id, 'developer', TRUE FROM auth.users WHERE email = 'YOUR_DEV_EMAIL'
--    ON CONFLICT (user_id) DO UPDATE SET is_developer = TRUE, department = 'developer';
--    -- ฝ่ายอื่น ๆ: INSERT INTO user_roles (user_id, department) SELECT id,'sales' FROM auth.users WHERE email='...';
--
--  การเชื่อมกับ client (index.html):
--    - createStock → RPC create_stock_multi(sr_ids[], stock_no, job_no, bom_no, name)
--    - ส่งงาน/ตีกลับ/รับงาน → RPC handoff_project / reject_project / ack_phase (มี gate ครบฝั่ง server)
--    - ปุ่มเดียวจบ "เสร็จ & ส่งต่อ" / "ปิดงานโครงการ" → RPC complete_and_handoff (ปิดงานเฟส auto + ส่งต่อ atomic)
--
--  (ออปชัน) เปิด Realtime ให้ทุกฝ่ายเห็นงานเข้าสด — แอป subscribe postgres_changes แล้ว reload อัตโนมัติ:
--    Dashboard → Database → Replication → เปิดตาราง (projects, sales_requisitions, customers, bom_items,
--      purchase_orders, department_tasks, service_plans, inventory_moves, handoff_log) เข้า publication supabase_realtime
--    หรือ SQL: ALTER PUBLICATION supabase_realtime ADD TABLE <table>;  (ถ้าซ้ำจะ error — ข้ามได้)
--    ถ้าไม่เปิด: แอปยังทำงานปกติ เพียงต้อง refresh เองเพื่อเห็นงานเข้า
--    - createSR / sendBom / PO / team / schedule → table ops (RLS ครอบคลุม)
-- =====================================================================
