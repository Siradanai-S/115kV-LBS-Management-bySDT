-- =====================================================================
--  reset-clean.sql — ล้างข้อมูลตัวอย่างทั้งหมด ก่อนเริ่มใช้งานจริง (Production)
--  เก็บไว้:  โครงสร้างตาราง · RPC · RLS · trigger · user_roles (สิทธิ์ผู้ใช้)
--  ลบทิ้ง:   ลูกค้า/SR/Stock/BOM/PO/งาน/ทีม/ตารางคิว/แผนส่งมอบ/คลังสินค้า/log
--
--  วิธีใช้: รันใน Supabase → SQL Editor  (หลังรัน schema.sql แล้ว 1 ครั้ง)
--          *** การกระทำนี้ลบข้อมูลถาวร — ใช้ตอนพร้อมเปิดใช้งานจริงเท่านั้น ***
-- =====================================================================

TRUNCATE TABLE
  inventory_moves,
  handoff_log,
  service_plans,
  service_schedule,
  service_team,
  purchase_orders,
  bom_items,
  department_tasks,
  projects,
  sales_requisitions,
  customers
RESTART IDENTITY CASCADE;

-- คง user_roles ไว้ และยืนยันสิทธิ์ Developer ให้ Mr. Siradanai อีกครั้ง
INSERT INTO user_roles (user_id, department, is_developer)
SELECT id, 'developer', TRUE FROM auth.users WHERE email = 'siradanai.s@precise.co.th'
ON CONFLICT (user_id) DO UPDATE SET is_developer = TRUE, department = 'developer';

-- ตรวจผล: ทุกตารางควรเป็น 0 (ยกเว้น user_roles)
SELECT 'customers' t, COUNT(*) n FROM customers
UNION ALL SELECT 'sales_requisitions', COUNT(*) FROM sales_requisitions
UNION ALL SELECT 'projects', COUNT(*) FROM projects
UNION ALL SELECT 'bom_items', COUNT(*) FROM bom_items
UNION ALL SELECT 'purchase_orders', COUNT(*) FROM purchase_orders
UNION ALL SELECT 'inventory_moves', COUNT(*) FROM inventory_moves
UNION ALL SELECT 'user_roles (คงไว้)', COUNT(*) FROM user_roles;
