-- =====================================================
-- 03_audit.sql  Audit package and triggers
-- =====================================================

CREATE OR REPLACE PACKAGE audit_pkg AS
  -- Null-safe change detection, overloaded per data type
  FUNCTION is_changed (p_old VARCHAR2, p_new VARCHAR2) RETURN BOOLEAN;
  FUNCTION is_changed (p_old NUMBER,   p_new NUMBER)   RETURN BOOLEAN;
  FUNCTION is_changed (p_old DATE,     p_new DATE)     RETURN BOOLEAN;

  -- Data changes: runs in the CALLER's transaction (rolls back with it)
  PROCEDURE log_change (p_table_name  VARCHAR2,
                        p_record_id   NUMBER,
                        p_action      VARCHAR2,
                        p_old_values  CLOB DEFAULT NULL,
                        p_new_values  CLOB DEFAULT NULL);

  -- Events and errors: AUTONOMOUS (survive a rollback)
  PROCEDURE log_event (p_table_name  VARCHAR2,
                       p_record_id   NUMBER,
                       p_action      VARCHAR2,
                       p_message     VARCHAR2,
                       p_new_values  CLOB DEFAULT NULL);

  PROCEDURE log_error (p_context     VARCHAR2,
                       p_table_name  VARCHAR2 DEFAULT 'N/A',
                       p_record_id   NUMBER   DEFAULT NULL);
END audit_pkg;
/

CREATE OR REPLACE PACKAGE BODY audit_pkg AS

  FUNCTION is_changed (p_old VARCHAR2, p_new VARCHAR2) RETURN BOOLEAN IS
  BEGIN
    RETURN CASE
             WHEN p_old IS NULL AND p_new IS NULL THEN FALSE
             WHEN p_old IS NULL OR  p_new IS NULL THEN TRUE
             ELSE p_old <> p_new
           END;
  END is_changed;

  FUNCTION is_changed (p_old NUMBER, p_new NUMBER) RETURN BOOLEAN IS
  BEGIN
    RETURN CASE
             WHEN p_old IS NULL AND p_new IS NULL THEN FALSE
             WHEN p_old IS NULL OR  p_new IS NULL THEN TRUE
             ELSE p_old <> p_new
           END;
  END is_changed;

  FUNCTION is_changed (p_old DATE, p_new DATE) RETURN BOOLEAN IS
  BEGIN
    RETURN CASE
             WHEN p_old IS NULL AND p_new IS NULL THEN FALSE
             WHEN p_old IS NULL OR  p_new IS NULL THEN TRUE
             ELSE p_old <> p_new
           END;
  END is_changed;

  PROCEDURE log_change (p_table_name  VARCHAR2,
                        p_record_id   NUMBER,
                        p_action      VARCHAR2,
                        p_old_values  CLOB DEFAULT NULL,
                        p_new_values  CLOB DEFAULT NULL) IS
  BEGIN
    INSERT INTO audit_log (table_name, record_id, action, old_values, new_values)
    VALUES (p_table_name, p_record_id, p_action, p_old_values, p_new_values);
    -- no COMMIT: belongs to the caller's transaction
  END log_change;

  PROCEDURE log_event (p_table_name  VARCHAR2,
                       p_record_id   NUMBER,
                       p_action      VARCHAR2,
                       p_message     VARCHAR2,
                       p_new_values  CLOB DEFAULT NULL) IS
    PRAGMA AUTONOMOUS_TRANSACTION;
  BEGIN
    INSERT INTO audit_log (table_name, record_id, action, new_values, message)
    VALUES (p_table_name, p_record_id, p_action, p_new_values, SUBSTR(p_message, 1, 4000));
    COMMIT;   -- commits ONLY this insert
  END log_event;

  PROCEDURE log_error (p_context     VARCHAR2,
                       p_table_name  VARCHAR2 DEFAULT 'N/A',
                       p_record_id   NUMBER   DEFAULT NULL) IS
    PRAGMA AUTONOMOUS_TRANSACTION;
    l_msg  VARCHAR2(4000);
  BEGIN
    -- capture the error that is currently being handled, with line numbers
    l_msg := SUBSTR(p_context || ' | ' ||
                    DBMS_UTILITY.format_error_stack ||
                    DBMS_UTILITY.format_error_backtrace, 1, 4000);

    INSERT INTO audit_log (table_name, record_id, action, message)
    VALUES (NVL(p_table_name, 'N/A'), p_record_id, 'ERROR', l_msg);
    COMMIT;
  END log_error;

END audit_pkg;
/

-- ---------- INVOICES: normalise + housekeeping ----------
CREATE OR REPLACE TRIGGER invoices_biu_trg
BEFORE INSERT OR UPDATE ON invoices
FOR EACH ROW
BEGIN
  :new.invoice_number := UPPER(TRIM(:new.invoice_number));
  :new.currency_code  := UPPER(TRIM(:new.currency_code));
  IF UPDATING THEN
    :new.updated_at := SYSTIMESTAMP;
  END IF;
END;
/

-- ---------- INVOICES: audit trail ----------
CREATE OR REPLACE TRIGGER invoices_audit_trg
AFTER INSERT OR UPDATE OR DELETE ON invoices
FOR EACH ROW
DECLARE
  l_old     JSON_OBJECT_T := JSON_OBJECT_T();
  l_new     JSON_OBJECT_T := JSON_OBJECT_T();
  l_action  audit_log.action%TYPE;
BEGIN
  IF INSERTING THEN
    l_action := 'INSERT';
    l_new.put('invoice_number', :new.invoice_number);
    l_new.put('vendor_id',      :new.vendor_id);
    l_new.put('po_id',          :new.po_id);
    l_new.put('currency_code',  :new.currency_code);
    l_new.put('net_amount',     :new.net_amount);
    l_new.put('tax_amount',     :new.tax_amount);
    l_new.put('status',         :new.status);

  ELSIF DELETING THEN
    l_action := 'DELETE';
    l_old.put('invoice_number', :old.invoice_number);
    l_old.put('vendor_id',      :old.vendor_id);
    l_old.put('net_amount',     :old.net_amount);
    l_old.put('status',         :old.status);

  ELSE  -- UPDATING: record only the columns that actually changed
    IF audit_pkg.is_changed(:old.status, :new.status) THEN
      l_old.put('status', :old.status);            l_new.put('status', :new.status);
    END IF;
    IF audit_pkg.is_changed(:old.net_amount, :new.net_amount) THEN
      l_old.put('net_amount', :old.net_amount);    l_new.put('net_amount', :new.net_amount);
    END IF;
    IF audit_pkg.is_changed(:old.tax_amount, :new.tax_amount) THEN
      l_old.put('tax_amount', :old.tax_amount);    l_new.put('tax_amount', :new.tax_amount);
    END IF;
    IF audit_pkg.is_changed(:old.po_id, :new.po_id) THEN
      l_old.put('po_id', :old.po_id);              l_new.put('po_id', :new.po_id);
    END IF;
    IF audit_pkg.is_changed(:old.vendor_id, :new.vendor_id) THEN
      l_old.put('vendor_id', :old.vendor_id);      l_new.put('vendor_id', :new.vendor_id);
    END IF;
    IF audit_pkg.is_changed(:old.currency_code, :new.currency_code) THEN
      l_old.put('currency_code', :old.currency_code); l_new.put('currency_code', :new.currency_code);
    END IF;
    IF audit_pkg.is_changed(:old.due_date, :new.due_date) THEN
      l_old.put('due_date', TO_CHAR(:old.due_date, 'YYYY-MM-DD'));
      l_new.put('due_date', TO_CHAR(:new.due_date, 'YYYY-MM-DD'));
    END IF;

    IF l_new.get_size = 0 THEN
      RETURN;   -- nothing business-relevant changed (e.g. only updated_at)
    END IF;

    l_action := CASE WHEN audit_pkg.is_changed(:old.status, :new.status)
                     THEN 'STATUS_CHANGE' ELSE 'UPDATE' END;
  END IF;

  audit_pkg.log_change(
    p_table_name => 'INVOICES',
    p_record_id  => COALESCE(:new.invoice_id, :old.invoice_id),
    p_action     => l_action,
    p_old_values => CASE WHEN l_old.get_size > 0 THEN l_old.to_clob END,
    p_new_values => CASE WHEN l_new.get_size > 0 THEN l_new.to_clob END);
END;
/

-- ---------- VENDORS: business rule + housekeeping ----------
CREATE OR REPLACE TRIGGER vendors_biu_trg
BEFORE INSERT OR UPDATE ON vendors
FOR EACH ROW
BEGIN
  :new.vendor_code   := UPPER(TRIM(:new.vendor_code));
  :new.currency_code := UPPER(TRIM(:new.currency_code));
  IF :new.status <> 'ON_HOLD' THEN
    :new.hold_reason := NULL;      -- leaving hold clears the reason
  END IF;
  IF UPDATING THEN
    :new.updated_at := SYSTIMESTAMP;
  END IF;
END;
/

-- ---------- VENDORS: audit trail (holds and identity changes matter for fraud) ----------
CREATE OR REPLACE TRIGGER vendors_audit_trg
AFTER INSERT OR UPDATE OR DELETE ON vendors
FOR EACH ROW
DECLARE
  l_old     JSON_OBJECT_T := JSON_OBJECT_T();
  l_new     JSON_OBJECT_T := JSON_OBJECT_T();
  l_action  audit_log.action%TYPE;
BEGIN
  IF INSERTING THEN
    l_action := 'INSERT';
    l_new.put('vendor_code', :new.vendor_code);
    l_new.put('vendor_name', :new.vendor_name);
    l_new.put('status',      :new.status);

  ELSIF DELETING THEN
    l_action := 'DELETE';
    l_old.put('vendor_code', :old.vendor_code);
    l_old.put('vendor_name', :old.vendor_name);
    l_old.put('status',      :old.status);

  ELSE
    IF audit_pkg.is_changed(:old.status, :new.status) THEN
      l_old.put('status', :old.status);            l_new.put('status', :new.status);
    END IF;
    IF audit_pkg.is_changed(:old.hold_reason, :new.hold_reason) THEN
      l_old.put('hold_reason', :old.hold_reason);  l_new.put('hold_reason', :new.hold_reason);
    END IF;
    IF audit_pkg.is_changed(:old.vendor_name, :new.vendor_name) THEN
      l_old.put('vendor_name', :old.vendor_name);  l_new.put('vendor_name', :new.vendor_name);
    END IF;
    IF audit_pkg.is_changed(:old.tax_id, :new.tax_id) THEN
      l_old.put('tax_id', :old.tax_id);            l_new.put('tax_id', :new.tax_id);
    END IF;
    IF audit_pkg.is_changed(:old.payment_terms_days, :new.payment_terms_days) THEN
      l_old.put('payment_terms_days', :old.payment_terms_days);
      l_new.put('payment_terms_days', :new.payment_terms_days);
    END IF;

    IF l_new.get_size = 0 AND l_old.get_size = 0 THEN
      RETURN;
    END IF;

    l_action := CASE WHEN audit_pkg.is_changed(:old.status, :new.status)
                     THEN 'STATUS_CHANGE' ELSE 'UPDATE' END;
  END IF;

  audit_pkg.log_change(
    p_table_name => 'VENDORS',
    p_record_id  => COALESCE(:new.vendor_id, :old.vendor_id),
    p_action     => l_action,
    p_old_values => CASE WHEN l_old.get_size > 0 THEN l_old.to_clob END,
    p_new_values => CASE WHEN l_new.get_size > 0 THEN l_new.to_clob END);
END;
/