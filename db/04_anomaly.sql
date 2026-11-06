-- =====================================================
-- 04_anomaly.sql  Rule-driven anomaly detection + scheduler job
-- =====================================================

-- ---------- Rules become data: add the query column if missing ----------
DECLARE
  l_count NUMBER;
BEGIN
  SELECT COUNT(*) INTO l_count
  FROM   user_tab_columns
  WHERE  table_name = 'ANOMALY_TYPES' AND column_name = 'DETECTION_SQL';

  IF l_count = 0 THEN
    EXECUTE IMMEDIATE 'ALTER TABLE anomaly_types ADD (detection_sql CLOB)';
  END IF;
END;
/

-- Contract for every rule query: returns INVOICE_ID and DETAILS,
-- considering only invoices in the work queue (RECEIVED or FLAGGED).

UPDATE anomaly_types SET detection_sql = q'[
SELECT i.invoice_id,
       'Same vendor and gross amount as: ' ||
       LISTAGG(o.invoice_number || ' (' || TO_CHAR(o.invoice_date, 'YYYY-MM-DD') || ')', ', ')
         WITHIN GROUP (ORDER BY o.invoice_date) AS details
FROM   invoices i
JOIN   invoices o
       ON  o.vendor_id    = i.vendor_id
       AND o.gross_amount = i.gross_amount
       AND o.invoice_id  <> i.invoice_id
       AND o.status      <> 'REJECTED'
       AND ABS(o.invoice_date - i.invoice_date) <=
           (SELECT TO_NUMBER(setting_value) FROM app_settings
            WHERE  setting_key = 'DUPLICATE_WINDOW_DAYS')
WHERE  i.status IN ('RECEIVED', 'FLAGGED')
GROUP  BY i.invoice_id
]' WHERE anomaly_code = 'DUPLICATE_SUSPECT';

UPDATE anomaly_types SET detection_sql = q'[
SELECT i.invoice_id,
       'Net ' || TO_CHAR(i.net_amount, 'FM999G999G990D00') || ' ' || i.currency_code ||
       ' exceeds PO ' || p.po_number || ' (' || TO_CHAR(p.po_amount, 'FM999G999G990D00') ||
       ') by ' || TO_CHAR(ROUND((i.net_amount / p.po_amount - 1) * 100, 1)) ||
       '%, tolerance ' || s.tol_pct || '%' AS details
FROM   invoices i
JOIN   purchase_orders p ON p.po_id = i.po_id
CROSS  JOIN (SELECT TO_NUMBER(setting_value) AS tol_pct FROM app_settings
             WHERE  setting_key = 'AMOUNT_TOLERANCE_PCT') s
WHERE  i.status IN ('RECEIVED', 'FLAGGED')
AND    i.net_amount > p.po_amount * (1 + s.tol_pct / 100)
]' WHERE anomaly_code = 'AMOUNT_OVER_PO';

UPDATE anomaly_types SET detection_sql = q'[
SELECT i.invoice_id,
       'Vendor ' || v.vendor_code || ' is on hold: ' || v.hold_reason AS details
FROM   invoices i
JOIN   vendors v ON v.vendor_id = i.vendor_id
WHERE  i.status IN ('RECEIVED', 'FLAGGED')
AND    v.status = 'ON_HOLD'
]' WHERE anomaly_code = 'VENDOR_ON_HOLD';

UPDATE anomaly_types SET detection_sql = q'[
SELECT i.invoice_id,
       'No purchase order referenced on invoice ' || i.invoice_number AS details
FROM   invoices i
WHERE  i.status IN ('RECEIVED', 'FLAGGED')
AND    i.po_id IS NULL
]' WHERE anomaly_code = 'MISSING_PO';

UPDATE anomaly_types SET detection_sql = q'[
SELECT i.invoice_id,
       'Invoice in ' || i.currency_code || ', vendor bills in ' || v.currency_code ||
       CASE WHEN p.po_id IS NOT NULL THEN ', PO in ' || p.currency_code END AS details
FROM   invoices i
JOIN   vendors v              ON v.vendor_id = i.vendor_id
LEFT   JOIN purchase_orders p ON p.po_id     = i.po_id
WHERE  i.status IN ('RECEIVED', 'FLAGGED')
AND   (i.currency_code <> v.currency_code
       OR (p.po_id IS NOT NULL AND i.currency_code <> p.currency_code))
]' WHERE anomaly_code = 'CURRENCY_MISMATCH';

COMMIT;

-- ---------- Package ----------
CREATE OR REPLACE PACKAGE anomaly_pkg AS
  -- Runs all active rules (or one, if p_anomaly_code is given). Commits.
  PROCEDURE run_detection (p_anomaly_code IN VARCHAR2 DEFAULT NULL);

  -- Resolve or dismiss an anomaly (used by the APEX app). Caller commits.
  PROCEDURE resolve_anomaly (p_anomaly_id IN NUMBER,
                             p_status     IN VARCHAR2,
                             p_note       IN VARCHAR2);
END anomaly_pkg;
/

CREATE OR REPLACE PACKAGE BODY anomaly_pkg AS

  PROCEDURE run_detection (p_anomaly_code IN VARCHAR2 DEFAULT NULL) IS
    l_sql      CLOB;
    l_start    TIMESTAMP := SYSTIMESTAMP;
    l_summary  JSON_OBJECT_T := JSON_OBJECT_T();
    l_new      PLS_INTEGER;
    l_total    PLS_INTEGER := 0;
    l_flagged  PLS_INTEGER := 0;
    l_failed   PLS_INTEGER := 0;
  BEGIN
    FOR r IN (SELECT anomaly_code, detection_sql
              FROM   anomaly_types
              WHERE  active_yn = 'Y'
              AND    detection_sql IS NOT NULL
              AND   (p_anomaly_code IS NULL OR anomaly_code = p_anomaly_code)
              ORDER  BY anomaly_code)
    LOOP
      BEGIN
        -- Dynamic SQL: wrap the stored rule query; values go in as bind variables
        l_sql := 'INSERT INTO invoice_anomalies (invoice_id, anomaly_code, details) '
              || 'SELECT src.invoice_id, :code, SUBSTR(src.details, 1, 1000) '
              || 'FROM (' || r.detection_sql || ') src '
              || 'WHERE NOT EXISTS (SELECT 1 FROM invoice_anomalies a '
              || '                  WHERE a.invoice_id = src.invoice_id '
              || '                  AND   a.anomaly_code = :code2)';

        EXECUTE IMMEDIATE l_sql USING r.anomaly_code, r.anomaly_code;

        l_new   := SQL%ROWCOUNT;
        l_total := l_total + l_new;
        l_summary.put(r.anomaly_code, l_new);
      EXCEPTION
        WHEN OTHERS THEN
          -- one broken rule must not stop the others
          l_failed := l_failed + 1;
          l_summary.put(r.anomaly_code, 'ERROR');
          audit_pkg.log_error('anomaly_pkg.run_detection rule ' || r.anomaly_code,
                              'INVOICE_ANOMALIES');
      END;
    END LOOP;

    -- Move invoices with open anomalies out of the approval queue
    UPDATE invoices i
    SET    i.status = 'FLAGGED'
    WHERE  i.status = 'RECEIVED'
    AND    EXISTS (SELECT 1 FROM invoice_anomalies a
                   WHERE  a.invoice_id = i.invoice_id
                   AND    a.status = 'OPEN');
    l_flagged := SQL%ROWCOUNT;

    COMMIT;

    l_summary.put('invoices_flagged', l_flagged);
    l_summary.put('rules_failed',     l_failed);
    l_summary.put('elapsed_ms',
                  ROUND(EXTRACT(SECOND FROM (SYSTIMESTAMP - l_start)) * 1000));

    audit_pkg.log_event(
      p_table_name => 'INVOICE_ANOMALIES',
      p_record_id  => NULL,
      p_action     => 'JOB_RUN',
      p_message    => 'Anomaly detection: ' || l_total || ' new anomalies, '
                      || l_flagged || ' invoices flagged, ' || l_failed || ' rules failed',
      p_new_values => l_summary.to_clob);
  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK;
      audit_pkg.log_error('anomaly_pkg.run_detection', 'INVOICE_ANOMALIES');
      RAISE;
  END run_detection;


  PROCEDURE resolve_anomaly (p_anomaly_id IN NUMBER,
                             p_status     IN VARCHAR2,
                             p_note       IN VARCHAR2) IS
    l_invoice_id  invoices.invoice_id%TYPE;
    l_new         JSON_OBJECT_T := JSON_OBJECT_T();
  BEGIN
    IF p_status NOT IN ('RESOLVED', 'DISMISSED') THEN
      RAISE_APPLICATION_ERROR(-20010, 'Status must be RESOLVED or DISMISSED');
    END IF;
    IF TRIM(p_note) IS NULL THEN
      RAISE_APPLICATION_ERROR(-20011, 'A resolution note is required');
    END IF;

    UPDATE invoice_anomalies
    SET    status          = p_status,
           resolved_by     = COALESCE(SYS_CONTEXT('APEX$SESSION', 'APP_USER'), USER),
           resolved_at     = SYSTIMESTAMP,
           resolution_note = p_note
    WHERE  anomaly_id = p_anomaly_id
    AND    status     = 'OPEN'
    RETURNING invoice_id INTO l_invoice_id;

    IF SQL%ROWCOUNT = 0 THEN
      RAISE_APPLICATION_ERROR(-20012, 'Anomaly ' || p_anomaly_id || ' not found or already closed');
    END IF;

    l_new.put('status', p_status);
    l_new.put('note',   p_note);
    audit_pkg.log_change('INVOICE_ANOMALIES', p_anomaly_id, 'UPDATE', NULL, l_new.to_clob);

    -- Last open anomaly cleared: return invoice to the queue for approval routing
    UPDATE invoices i
    SET    i.status = 'RECEIVED'
    WHERE  i.invoice_id = l_invoice_id
    AND    i.status     = 'FLAGGED'
    AND    NOT EXISTS (SELECT 1 FROM invoice_anomalies a
                       WHERE  a.invoice_id = i.invoice_id
                       AND    a.status = 'OPEN');
  END resolve_anomaly;

END anomaly_pkg;
/

-- ---------- Scheduler job (re-runnable: drop if it exists) ----------
BEGIN
  DBMS_SCHEDULER.drop_job(job_name => 'ANOMALY_DETECTION_JOB', force => TRUE);
EXCEPTION
  WHEN OTHERS THEN
    IF SQLCODE != -27475 THEN RAISE; END IF;   -- ORA-27475: job does not exist
END;
/

BEGIN
  DBMS_SCHEDULER.create_job(
    job_name        => 'ANOMALY_DETECTION_JOB',
    job_type        => 'PLSQL_BLOCK',
    job_action      => 'BEGIN anomaly_pkg.run_detection; END;',
    start_date      => SYSTIMESTAMP,
    repeat_interval => 'FREQ=MINUTELY; INTERVAL=15',
    enabled         => TRUE,
    comments        => 'Rule-driven invoice anomaly detection (duplicates, PO tolerance, vendor holds, missing PO, currency)');
END;
/