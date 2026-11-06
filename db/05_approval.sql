-- =====================================================
-- 05_approval.sql  Approval routing and decisions
-- =====================================================

CREATE OR REPLACE PACKAGE approval_pkg AS
  -- Gross amount of an invoice converted to EUR via FX_RATES
  FUNCTION gross_eur (p_invoice_id IN NUMBER) RETURN NUMBER;

  -- Highest approval level required for an amount in EUR
  FUNCTION required_level (p_amount_eur IN NUMBER) RETURN NUMBER;

  -- Create approval steps for one clean RECEIVED invoice. Caller commits.
  PROCEDURE route_invoice (p_invoice_id IN NUMBER);

  -- Route every clean RECEIVED invoice. Commits. Used by the scheduler job.
  PROCEDURE route_pending;

  -- Approve or reject the current level. p_username defaults to the APEX user.
  -- Caller commits.
  PROCEDURE decide (p_invoice_id IN NUMBER,
                    p_decision   IN VARCHAR2,
                    p_comments   IN VARCHAR2 DEFAULT NULL,
                    p_username   IN VARCHAR2 DEFAULT NULL);
END approval_pkg;
/

CREATE OR REPLACE PACKAGE BODY approval_pkg AS

  FUNCTION current_username RETURN VARCHAR2 IS
  BEGIN
    RETURN UPPER(COALESCE(SYS_CONTEXT('APEX$SESSION', 'APP_USER'), USER));
  END current_username;


  FUNCTION gross_eur (p_invoice_id IN NUMBER) RETURN NUMBER IS
    l_amount NUMBER;
  BEGIN
    SELECT ROUND(i.gross_amount * r.rate_to_eur, 2)
    INTO   l_amount
    FROM   invoices i
    JOIN   fx_rates r ON r.currency_code = i.currency_code
    WHERE  i.invoice_id = p_invoice_id;
    RETURN l_amount;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      RAISE_APPLICATION_ERROR(-20020,
        'Invoice ' || p_invoice_id || ' not found or its currency has no FX rate');
  END gross_eur;


  FUNCTION required_level (p_amount_eur IN NUMBER) RETURN NUMBER IS
    l_level NUMBER;
  BEGIN
    SELECT MAX(approval_level)
    INTO   l_level
    FROM   approval_rules
    WHERE  p_amount_eur >= min_amount;

    IF l_level IS NULL THEN
      RAISE_APPLICATION_ERROR(-20024, 'No approval rule covers amount ' || p_amount_eur);
    END IF;
    RETURN l_level;
  END required_level;


  PROCEDURE route_invoice (p_invoice_id IN NUMBER) IS
    l_status    invoices.status%TYPE;
    l_open      PLS_INTEGER;
    l_amount    NUMBER;
    l_levels    NUMBER;
    l_approver  app_users.user_id%TYPE;
    l_log       JSON_OBJECT_T := JSON_OBJECT_T();
  BEGIN
    SELECT status INTO l_status
    FROM   invoices
    WHERE  invoice_id = p_invoice_id
    FOR UPDATE;                                    -- lock the invoice while routing

    IF l_status <> 'RECEIVED' THEN
      RAISE_APPLICATION_ERROR(-20021,
        'Invoice must be RECEIVED to route (current status: ' || l_status || ')');
    END IF;

    SELECT COUNT(*) INTO l_open
    FROM   invoice_anomalies
    WHERE  invoice_id = p_invoice_id AND status = 'OPEN';

    IF l_open > 0 THEN
      RAISE_APPLICATION_ERROR(-20022,
        'Invoice has ' || l_open || ' open anomalies and cannot be routed');
    END IF;

    l_amount := gross_eur(p_invoice_id);
    l_levels := required_level(l_amount);

    FOR r IN (SELECT approval_level, approver_role
              FROM   approval_rules
              WHERE  approval_level <= l_levels
              ORDER  BY approval_level)
    LOOP
      BEGIN
        SELECT user_id INTO l_approver
        FROM   app_users
        WHERE  role_code = r.approver_role
        AND    active_yn = 'Y'
        ORDER  BY approval_limit DESC, user_id
        FETCH  FIRST 1 ROW ONLY;
      EXCEPTION
        WHEN NO_DATA_FOUND THEN
          RAISE_APPLICATION_ERROR(-20023,
            'No active user with role ' || r.approver_role || ' for level ' || r.approval_level);
      END;

      INSERT INTO invoice_approvals (invoice_id, approval_level, approver_id)
      VALUES (p_invoice_id, r.approval_level, l_approver);
    END LOOP;

    UPDATE invoices SET status = 'PENDING_APPROVAL'
    WHERE  invoice_id = p_invoice_id;              -- trigger logs the STATUS_CHANGE

    l_log.put('event',      'ROUTED');
    l_log.put('amount_eur', l_amount);
    l_log.put('levels',     l_levels);
    audit_pkg.log_change('INVOICE_APPROVALS', p_invoice_id, 'INSERT', NULL, l_log.to_clob);
  END route_invoice;


  PROCEDURE route_pending IS
    l_routed  PLS_INTEGER := 0;
    l_failed  PLS_INTEGER := 0;
    l_summary JSON_OBJECT_T := JSON_OBJECT_T();
  BEGIN
    FOR r IN (SELECT i.invoice_id
              FROM   invoices i
              WHERE  i.status = 'RECEIVED'
              AND    NOT EXISTS (SELECT 1 FROM invoice_anomalies a
                                 WHERE  a.invoice_id = i.invoice_id
                                 AND    a.status = 'OPEN')
              ORDER  BY i.invoice_id)
    LOOP
      SAVEPOINT before_route;
      BEGIN
        route_invoice(r.invoice_id);
        l_routed := l_routed + 1;
      EXCEPTION
        WHEN OTHERS THEN
          ROLLBACK TO before_route;                -- undo only this invoice
          l_failed := l_failed + 1;
          audit_pkg.log_error('approval_pkg.route_pending', 'INVOICES', r.invoice_id);
      END;
    END LOOP;

    COMMIT;

    l_summary.put('routed', l_routed);
    l_summary.put('failed', l_failed);
    audit_pkg.log_event('INVOICE_APPROVALS', NULL, 'JOB_RUN',
                        'Approval routing: ' || l_routed || ' routed, ' || l_failed || ' failed',
                        l_summary.to_clob);
  END route_pending;


  PROCEDURE decide (p_invoice_id IN NUMBER,
                    p_decision   IN VARCHAR2,
                    p_comments   IN VARCHAR2 DEFAULT NULL,
                    p_username   IN VARCHAR2 DEFAULT NULL) IS
    l_user         app_users.username%TYPE := UPPER(NVL(p_username, current_username));
    l_status       invoices.status%TYPE;
    l_created_by   invoices.created_by%TYPE;
    l_approval_id  invoice_approvals.approval_id%TYPE;
    l_level        invoice_approvals.approval_level%TYPE;
    l_approver_id  invoice_approvals.approver_id%TYPE;
    l_user_id      app_users.user_id%TYPE;
    l_limit        app_users.approval_limit%TYPE;
    l_remaining    PLS_INTEGER;
    l_log          JSON_OBJECT_T := JSON_OBJECT_T();
  BEGIN
    IF p_decision NOT IN ('APPROVED', 'REJECTED') THEN
      RAISE_APPLICATION_ERROR(-20030, 'Decision must be APPROVED or REJECTED');
    END IF;
    IF p_decision = 'REJECTED' AND TRIM(p_comments) IS NULL THEN
      RAISE_APPLICATION_ERROR(-20031, 'A comment is required when rejecting');
    END IF;

    -- Lock the invoice; fail fast if someone else is deciding right now
    SELECT status, created_by INTO l_status, l_created_by
    FROM   invoices
    WHERE  invoice_id = p_invoice_id
    FOR UPDATE NOWAIT;

    IF l_status <> 'PENDING_APPROVAL' THEN
      RAISE_APPLICATION_ERROR(-20032,
        'Invoice is not awaiting approval (current status: ' || l_status || ')');
    END IF;

    -- Current step = lowest pending level
    SELECT approval_id, approval_level, approver_id
    INTO   l_approval_id, l_level, l_approver_id
    FROM   invoice_approvals
    WHERE  invoice_id = p_invoice_id AND decision = 'PENDING'
    ORDER  BY approval_level
    FETCH  FIRST 1 ROW ONLY;

    BEGIN
      SELECT user_id, approval_limit INTO l_user_id, l_limit
      FROM   app_users
      WHERE  username = l_user AND active_yn = 'Y';
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        RAISE_APPLICATION_ERROR(-20033, 'Unknown or inactive user ' || l_user);
    END;

    IF l_user_id <> l_approver_id THEN
      RAISE_APPLICATION_ERROR(-20034,
        'Level ' || l_level || ' of this invoice is assigned to another approver');
    END IF;

    IF UPPER(l_created_by) = l_user THEN
      RAISE_APPLICATION_ERROR(-20035,
        'Segregation of duties: you cannot decide on an invoice you entered');
    END IF;

    SELECT COUNT(*) INTO l_remaining
    FROM   invoice_approvals
    WHERE  invoice_id = p_invoice_id AND decision = 'PENDING';

    -- Final approver must have a limit that covers the full amount
    IF p_decision = 'APPROVED' AND l_remaining = 1
       AND l_limit < gross_eur(p_invoice_id) THEN
      RAISE_APPLICATION_ERROR(-20036,
        'Amount exceeds your approval limit of ' || l_limit || ' EUR');
    END IF;

    UPDATE invoice_approvals
    SET    decision    = p_decision,
           decision_at = SYSTIMESTAMP,
           comments    = p_comments
    WHERE  approval_id = l_approval_id;

    IF p_decision = 'REJECTED' THEN
      DELETE FROM invoice_approvals                -- later levels are now moot
      WHERE  invoice_id = p_invoice_id AND decision = 'PENDING';
      UPDATE invoices SET status = 'REJECTED' WHERE invoice_id = p_invoice_id;
    ELSIF l_remaining = 1 THEN
      UPDATE invoices SET status = 'APPROVED' WHERE invoice_id = p_invoice_id;
    END IF;

    l_log.put('event',    'DECISION');
    l_log.put('level',    l_level);
    l_log.put('decision', p_decision);
    l_log.put('by',       l_user);
    l_log.put('comments', p_comments);
    audit_pkg.log_change('INVOICE_APPROVALS', p_invoice_id, 'UPDATE', NULL, l_log.to_clob);
  END decide;

END approval_pkg;
/

-- ---------- Extend the scheduler job into a pipeline ----------
BEGIN
  DBMS_SCHEDULER.set_attribute(
    name      => 'ANOMALY_DETECTION_JOB',
    attribute => 'job_action',
    value     => 'BEGIN anomaly_pkg.run_detection; approval_pkg.route_pending; END;');

  DBMS_SCHEDULER.set_attribute(
    name      => 'ANOMALY_DETECTION_JOB',
    attribute => 'comments',
    value     => 'Invoice pipeline: anomaly detection, then approval routing of clean invoices');
END;
/