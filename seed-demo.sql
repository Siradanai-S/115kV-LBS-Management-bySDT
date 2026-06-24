-- =====================================================================
--  seed-demo.sql — ข้อมูลตัวอย่าง (DEMO/ทดสอบเท่านั้น)
--  แยกออกจาก schema.sql แล้ว เพื่อให้การอัปเดต schema ไม่ยัด/แตะข้อมูลจริง
--
--  รันเฉพาะเมื่อต้องการข้อมูลสาธิตบนฐานข้อมูลเปล่า · ห้ามรันบน production
--  (idempotent: ON CONFLICT DO NOTHING / WHERE NOT EXISTS — รันซ้ำไม่ทำข้อมูลซ้ำ
--   แต่ "จะสร้าง" แถวตัวอย่างถ้ายังไม่มี — จึงไม่รวมไว้ใน schema.sql อีกต่อไป)
--  ล้างข้อมูลตัวอย่างทิ้ง: ใช้ reset-clean.sql
-- =====================================================================

-- ---------- 13) SEED DATA (ข้อมูลตัวอย่าง) ----------
-- หมายเหตุ: ใช้สำหรับทดลอง/สาธิต · เมื่อพร้อมใช้งานจริงให้รัน reset-clean.sql เพื่อล้างทิ้ง
--           (หรือจะข้าม/ลบทั้งบล็อก SEED ด้านล่างนี้ก่อนรันก็ได้ หากต้องการฐานข้อมูลว่างตั้งแต่แรก)
-- Sales Requisition
INSERT INTO sales_requisitions (sr_no, cust_po_no, contract_status, note) VALUES
 ('SR-2026-001','CPO-PEA-115/2569','ทำสัญญาแล้ว','งานภาคตะวันออก 2 ราย'),
 ('SR-2026-002','CPO-PTC-008','ได้รับ PO แล้ว','งานปิโตรเคมี ระยอง'),
 ('SR-2026-003','PO-SVI-2569/077','ได้รับ PO แล้ว','งานภาคใต้ + ระยอง — รอฝ่ายโครงการสร้าง Stock'),  -- ยังไม่ผูก Stock (โผล่ใน Inbox ฝ่ายโครงการ)
 ('SR-2026-004','CPO-GULF-441','ทำสัญญาแล้ว','โรงไฟฟ้า SPP สระบุรี'),
 ('SR-2026-005','CPO-GPSC-220','ทำสัญญาแล้ว','งานเปลี่ยน LBS ศรีราชา (ปิดงานแล้ว)')
ON CONFLICT (sr_no) DO NOTHING;

-- ลูกค้า (ผูก SR ด้วย sr_no)
INSERT INTO customers (name, customer_type, work_type, contact, lbs_qty, desired_date, location, scope, sr_id)
SELECT x.name, x.ctype::customer_type_t, x.wtype::work_type_t, x.contact, x.lbs, x.deliv, x.loc, x.scope,
       (SELECT id FROM sales_requisitions WHERE sr_no = x.sr)
FROM (VALUES
  ('การไฟฟ้าส่วนภูมิภาค','ราชการ','Supply & Construction','คุณสมชาย 081-xxx',6, CURRENT_DATE+9,  'บางปะกง ฉะเชิงเทรา','ปรับปรุงสถานีไฟฟ้า','SR-2026-001'),
  ('บ.อมตะ คอร์ปอเรชัน', 'เอกชน', 'Supply & Construction','คุณวิภา 089-xxx', 4, CURRENT_DATE+22, 'นิคมอมตะนคร ชลบุรี','ติดตั้ง LBS','SR-2026-001'),
  ('บ.ปิโตรเคมีไทย',     'เอกชน', 'Supply',                'คุณเอก 086-xxx',  3, CURRENT_DATE+45, 'มาบตาพุด ระยอง','ขยายเขตจ่ายไฟ','SR-2026-002'),
  ('เทศบาลนครนนทบุรี',   'ราชการ','Supply',                'กองช่าง 02-xxx',  2, NULL,            'นนทบุรี','สำรวจงาน LBS', NULL),
  ('บ.สหวิริยาสตีลอินดัสตรี','เอกชน','Supply & Construction','คุณมานพ 088-xxx', 5, CURRENT_DATE+35, 'บางสะพาน ประจวบฯ','ติดตั้ง LBS โรงเหล็ก','SR-2026-003'),
  ('เทศบาลเมืองมาบตาพุด','ราชการ','Supply',                'กองช่าง 038-xxx', 2, CURRENT_DATE+50, 'มาบตาพุด ระยอง','ขยายเขตจ่ายไฟ','SR-2026-003'),
  ('บ.กัลฟ์ เอ็นเนอร์จี','เอกชน','Supply & Construction','คุณปกรณ์ 081-444-xxx', 8, CURRENT_DATE+20, 'หนองแซง สระบุรี','โรงไฟฟ้า SPP LBS 115kV','SR-2026-004'),
  ('บ.โกลบอล เพาเวอร์ ซินเนอร์ยี่','เอกชน','Supply','คุณนภา 089-666-xxx', 4, CURRENT_DATE-3, 'ศรีราชา ชลบุรี','เปลี่ยน LBS เดิม','SR-2026-005')
) AS x(name,ctype,wtype,contact,lbs,deliv,loc,scope,sr)
ON CONFLICT (name) DO NOTHING;

-- Project Stock — ครบทุกเฟส: service / project / purchasing / closed
INSERT INTO projects (project_stock_no, job_no, bom_no, bom_status, name, current_phase, phase_acked, target_lbs, total_budget, margin, cash_flow_status, delivery_date, do_signed)
VALUES
 ('STK-2026-001','JOB-2026-001','BOM-2026-001','Sent to Purchasing','ปรับปรุงสถานี+นิคม (ภาคตะวันออก)','service',    TRUE, 10, 14700000, 18.0, 'ปกติ',     CURRENT_DATE+7,  FALSE),
 ('STK-2026-002','JOB-2026-002','BOM-2026-002','Draft',             'ขยายเขตจ่ายไฟ ปิโตรเคมีระยอง','project',         TRUE, 3,  4100000,  20.0, 'เฝ้าระวัง', CURRENT_DATE+45, FALSE),
 ('STK-2026-003','JOB-2026-003','BOM-2026-003','Sent to Purchasing','โรงไฟฟ้า SPP กัลฟ์ สระบุรี','purchasing',        TRUE, 8,  9800000,  16.5, 'ปกติ',     CURRENT_DATE+20, FALSE),
 ('STK-2026-004','JOB-2026-004','BOM-2026-004','Sent to Purchasing','เปลี่ยน LBS ศรีราชา (ปิดงาน)','closed',           TRUE, 4,  3950000,  22.0, 'ปกติ',     CURRENT_DATE-3,  TRUE)
ON CONFLICT DO NOTHING;   -- ครอบทุก unique (project_stock_no / job_no / bom_no) — รันซ้ำได้ไม่ error

-- ผูก SR → Stock
UPDATE sales_requisitions s SET stock_id = p.id FROM projects p
  WHERE (s.sr_no,p.project_stock_no) IN (('SR-2026-001','STK-2026-001'),('SR-2026-002','STK-2026-002'),('SR-2026-004','STK-2026-003'),('SR-2026-005','STK-2026-004'));

-- ปรับสถานะงานให้สมจริงตามเฟส seed
UPDATE department_tasks d SET status='Completed' FROM customers c
  WHERE d.customer_id=c.id AND d.department='sales' AND c.sr_id IS NOT NULL AND d.sort_order<=1;
UPDATE department_tasks d SET status='In Progress' FROM customers c
  WHERE d.customer_id=c.id AND d.department='sales' AND c.sr_id IS NULL AND d.sort_order=0;
UPDATE department_tasks d SET status='Completed'
  FROM projects p WHERE d.project_id=p.id AND (
       (d.department='project'    AND p.current_phase IN ('purchasing','service','closed'))
    OR (d.department='purchasing' AND p.current_phase IN ('service','closed'))
    OR (d.department='service'    AND p.current_phase='closed'));
UPDATE department_tasks d SET status='In Progress'
  FROM projects p WHERE d.project_id=p.id AND d.department::text=p.current_phase::text AND d.sort_order=0;

-- BOM (คอลัมน์ Epicor)
INSERT INTO bom_items (project_id, epicor_code, description, category, due_date, ium, quantity, currency, unit_cost, fx_rate, project_phase, po_status)
SELECT p.id, x.code, x.descr, x.cat, x.due, x.ium, x.qty, x.cur::currency_t, x.cost, x.fx, x.phase, x.po::po_status_t
FROM (VALUES
  ('STK-2026-001','LBS-115-MOT','LBS 115kV 3-Pole Motorized','LBS',       CURRENT_DATE-15,'EA',6, 'USD',24500,36.5,'Phase 1','Delivered'),
  ('STK-2026-001','LBS-115-MAN','LBS 115kV 3-Pole Manual',   'LBS',       CURRENT_DATE-10,'EA',4, 'USD',20000,36.5,'Phase 1','Delivered'),
  ('STK-2026-001','ACC-SA-115', 'Surge Arrester 115kV',       'Accessory', CURRENT_DATE-8, 'EA',30,'THB',42000,1,   'Phase 1','Delivered'),
  ('STK-2026-002','LBS-115-MOT','LBS 115kV 3-Pole Motorized','LBS',       CURRENT_DATE+40,'EA',3, 'USD',24500,36.5,'Phase 1','Awaiting PO'),
  ('STK-2026-002','ACC-CC-01',  'Control Cabinet',            'Accessory', CURRENT_DATE+40,'EA',3, 'THB',95000,1,   'Phase 1','Awaiting PO'),
  ('STK-2026-003','LBS-115-MOT','LBS 115kV 3-Pole Motorized','LBS',       CURRENT_DATE+15,'EA',8, 'USD',24500,36.2,'Phase 1','Awaiting PO'),
  ('STK-2026-003','ACC-SA-115', 'Surge Arrester 115kV',       'Accessory', CURRENT_DATE+12,'EA',24,'THB',42000,1,   'Phase 1','Awaiting PO'),
  ('STK-2026-004','LBS-115-MAN','LBS 115kV 3-Pole Manual',   'LBS',       CURRENT_DATE-30,'EA',4, 'USD',20000,35.8,'Phase 1','Delivered'),
  ('STK-2026-004','ACC-CC-01',  'Control Cabinet',            'Accessory', CURRENT_DATE-28,'EA',4, 'THB',95000,1,   'Phase 1','Delivered')
) AS x(stock_no, code, descr, cat, due, ium, qty, cur, cost, fx, phase, po)
JOIN projects p ON p.project_stock_no = x.stock_no
WHERE NOT EXISTS (SELECT 1 FROM bom_items b WHERE b.project_id=p.id AND b.epicor_code=x.code);

-- PO
INSERT INTO purchase_orders (project_id, po_no, supplier, status, expected_date, amount, notified)
SELECT p.id, x.po_no, x.supplier, x.status::po_doc_status_t, x.exp, x.amt, TRUE
FROM (VALUES
  ('STK-2026-001','PO-2026-1001','ABB (Thailand)','รับครบ', CURRENT_DATE-20, 9300000),
  ('STK-2026-001','PO-2026-1002','Schneider Electric','รับครบ', CURRENT_DATE-12, 1260000),
  ('STK-2026-004','PO-2026-1005','ABB (Thailand)','รับครบ', CURRENT_DATE-35, 3260000)
) AS x(stock_no, po_no, supplier, status, exp, amt)
JOIN projects p ON p.project_stock_no = x.stock_no
ON CONFLICT (po_no) DO NOTHING;

-- seed: ผูกรายการ BOM ที่ออก PO แล้ว เข้ากับ PO แรกของแต่ละ Stock (po_id) แล้วรวมกลับเป็น bom_ids
WITH firstpo AS (
  SELECT DISTINCT ON (project_id) project_id, id AS po_id FROM purchase_orders ORDER BY project_id, id
)
UPDATE bom_items b SET po_id = f.po_id
  FROM firstpo f WHERE b.project_id = f.project_id AND b.po_status <> 'Awaiting PO' AND b.po_id IS NULL;
UPDATE purchase_orders o SET bom_ids = COALESCE((SELECT array_agg(b.id) FROM bom_items b WHERE b.po_id = o.id), '{}');
-- lines = [{bom_id, qty}] (เดโม seed: ลงเต็มจำนวน)
UPDATE purchase_orders o SET lines = COALESCE((SELECT jsonb_agg(jsonb_build_object('bom_id', b.id, 'qty', b.quantity)) FROM bom_items b WHERE b.po_id = o.id), '[]');

-- ใบแผนส่งมอบ (seed: STK-001 รอ Service รับ, STK-004 รับแล้ว)
INSERT INTO service_plans (project_id, delivery_date, location, team_need, note, acked)
SELECT p.id, p.delivery_date, x.loc, x.team, x.note, x.acked
FROM (VALUES
  ('STK-2026-001','บางปะกง ฉะเชิงเทรา / นิคมอมตะนคร','ทีมติดตั้ง 4-5 คน','ส่งมอบ+ติดตั้ง LBS 10 ชุด ตามแผน PEA', FALSE),
  ('STK-2026-004','ศรีราชา ชลบุรี','ทีม 2 คน','เปลี่ยน LBS เดิม — ปิดงานแล้ว', TRUE)
) AS x(stock_no, loc, team, note, acked)
JOIN projects p ON p.project_stock_no = x.stock_no
WHERE NOT EXISTS (SELECT 1 FROM service_plans s WHERE s.project_id=p.id);

-- ทีม Service
INSERT INTO service_team (name, role, phone) VALUES
 ('อนุชา (หัวหน้าทีม)','Site Supervisor','081-111-1111'),
 ('ธีรพงษ์ ทองดี','Technician','081-222-2222'),
 ('กิตติ ศรีสุข','Technician','081-333-3333'),
 ('สุริยา แดงเดช','Electrician','081-444-4444'),
 ('ประพันธ์ ใจกล้า','Helper','081-555-5555')
ON CONFLICT DO NOTHING;
