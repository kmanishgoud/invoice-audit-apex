-- =====================================================
-- 00_create_schema.sql
-- Run as SYS in the pluggable database (FREEPDB1).
-- =====================================================

CREATE USER invoice_audit IDENTIFIED BY "<password>"
  DEFAULT TABLESPACE users
  QUOTA UNLIMITED ON users;

-- 23ai/26ai developer role: tables, views, PL/SQL, triggers, sequences, etc.
GRANT DB_DEVELOPER_ROLE TO invoice_audit;

-- Needed for DBMS_SCHEDULER jobs
GRANT CREATE JOB TO invoice_audit;