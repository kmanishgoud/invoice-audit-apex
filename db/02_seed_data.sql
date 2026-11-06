-- =====================================================
-- 02_seed_data.sql  Reference data, history, planted anomalies
-- =====================================================

-- ---------- Small schema addition: FX rates ----------
CREATE TABLE IF NOT EXISTS fx_rates (
  currency_code  VARCHAR2(3) CONSTRAINT fx_rates_pk PRIMARY KEY,
  rate_to_eur    NUMBER(12,6) NOT NULL CONSTRAINT fx_rates_rate_ck CHECK (rate_to_eur > 0)
);

-- ---------- Clean out (re-runnable) ----------
DELETE FROM invoice_anomalies;
DELETE FROM invoice_approvals;
DELETE FROM invoices;
DELETE FROM purchase_orders;
DELETE FROM vendors;
DELETE FROM cost_centers;
DELETE FROM approval_rules;
DELETE FROM anomaly_types;
DELETE FROM app_users;
DELETE FROM app_settings;
DELETE FROM fx_rates;
COMMIT;

-- ---------- Reference data (23ai multi-row VALUES) ----------
INSERT INTO fx_rates (currency_code, rate_to_eur) VALUES
  ('EUR', 1), ('PLN', 0.234), ('GBP', 1.17), ('USD', 0.92);

INSERT INTO app_settings (setting_key, setting_value, description) VALUES
  ('AMOUNT_TOLERANCE_PCT',  '5',   'Max % an invoice net amount may exceed its PO before it is flagged'),
  ('DUPLICATE_WINDOW_DAYS', '30',  'Same vendor and gross amount within this many days = suspected duplicate'),
  ('REPORTING_CURRENCY',    'EUR', 'Currency used for dashboards and approval limits');

INSERT INTO anomaly_types (anomaly_code, description, severity) VALUES
  ('DUPLICATE_SUSPECT', 'Same vendor and gross amount as another invoice within the duplicate window', 'HIGH'),
  ('AMOUNT_OVER_PO',    'Invoice net amount exceeds the PO amount by more than the tolerance',         'HIGH'),
  ('VENDOR_ON_HOLD',    'Invoice received from a vendor that is on hold',                               'HIGH'),
  ('MISSING_PO',        'Invoice has no purchase order reference',                                      'MEDIUM'),
  ('CURRENCY_MISMATCH', 'Invoice currency differs from the vendor or PO currency',                      'MEDIUM');

INSERT INTO app_users (username, full_name, email, role_code, approval_limit) VALUES
  ('MANISH',    'Manish Goud Kamareddy', 'manish@example.com',              'ADMIN',       0),
  ('ANNA',      'Anna Kowalska',         'anna.kowalska@example.com',       'CLERK',       0),
  ('TOMASZ',    'Tomasz Nowak',          'tomasz.nowak@example.com',        'APPROVER',    10000),
  ('KATARZYNA', 'Katarzyna Wisniewska',  'katarzyna.wisniewska@example.com','FIN_MANAGER', 50000),
  ('PIOTR',     'Piotr Zielinski',       'piotr.zielinski@example.com',     'CFO',         1000000),
  ('EWA',       'Ewa Lewandowska',       'ewa.lewandowska@example.com',     'AUDITOR',     0);

INSERT INTO cost_centers (cc_code, cc_name, manager_id)
SELECT 'IT',  'Information Technology', user_id FROM app_users WHERE username = 'TOMASZ'    UNION ALL
SELECT 'OPS', 'Operations',             user_id FROM app_users WHERE username = 'TOMASZ'    UNION ALL
SELECT 'FIN', 'Finance',                user_id FROM app_users WHERE username = 'KATARZYNA' UNION ALL
SELECT 'MKT', 'Marketing',              user_id FROM app_users WHERE username = 'KATARZYNA';

INSERT INTO vendors (vendor_code, vendor_name, tax_id, country_code, currency_code, payment_terms_days, status, hold_reason) VALUES
  ('V-ACME',    'Acme Office Supplies Sp. z o.o.', 'PL5260001111',   'PL', 'PLN', 30, 'ACTIVE',   NULL),
  ('V-NORD',    'Nordic Cloud Services AB',        'SE556000222201', 'SE', 'EUR', 30, 'ACTIVE',   NULL),
  ('V-RHEIN',   'Rhein Logistik GmbH',             'DE811000333',    'DE', 'EUR', 45, 'ACTIVE',   NULL),
  ('V-THAMES',  'Thames Consulting Ltd',           'GB123456789',    'GB', 'GBP', 30, 'ACTIVE',   NULL),
  ('V-LUMIERE', 'Lumiere Marketing SARL',          'FR40123456789',  'FR', 'EUR', 60, 'ACTIVE',   NULL),
  ('V-WAWEL',   'Wawel Facility Management',       'PL6750002222',   'PL', 'PLN', 14, 'ACTIVE',   NULL),
  ('V-ORBIT',   'Orbit Hardware Inc.',             'US987654321',    'US', 'USD', 30, 'ACTIVE',   NULL),
  ('V-VISTULA', 'Vistula Print House',             'PL7790003333',   'PL', 'PLN', 30, 'ON_HOLD',  'Bank account change not yet verified by finance'),
  ('V-OLDCO',   'OldCo Telecom',                   'PL1130004444',   'PL', 'PLN', 30, 'INACTIVE', NULL);

-- Approval bands on gross amount converted to EUR
INSERT INTO approval_rules (approval_level, min_amount, max_amount, approver_role) VALUES
  (1, 0,     10000, 'APPROVER'),
  (2, 10000, 50000, 'FIN_MANAGER'),
  (3, 50000, NULL,  'CFO');

COMMIT;

-- ---------- Historical invoices: generated ----------
DECLARE
  TYPE t_ids IS TABLE OF NUMBER;
  l_vendors   t_ids;
  l_ccs       t_ids;
  l_vendor_id NUMBER;
  l_cc_id     NUMBER;
  l_po_id     NUMBER;
  l_vcode     vendors.vendor_code%TYPE;
  l_curr      vendors.currency_code%TYPE;
  l_country   vendors.country_code%TYPE;
  l_terms     vendors.payment_terms_days%TYPE;
  l_inv_date  DATE;
  l_net       NUMBER;
  l_tax_rate  NUMBER;
  l_status    invoices.status%TYPE;
BEGIN
  DBMS_RANDOM.seed(42);   -- reproducible data

  SELECT vendor_id BULK COLLECT INTO l_vendors
  FROM   vendors WHERE status = 'ACTIVE' ORDER BY vendor_id;

  SELECT cost_center_id BULK COLLECT INTO l_ccs
  FROM   cost_centers ORDER BY cost_center_id;

  FOR i IN 1 .. 240 LOOP
    l_vendor_id := l_vendors(TRUNC(DBMS_RANDOM.value(1, l_vendors.COUNT + 1)));
    l_cc_id     := l_ccs(TRUNC(DBMS_RANDOM.value(1, l_ccs.COUNT + 1)));

    SELECT vendor_code, currency_code, country_code, payment_terms_days
    INTO   l_vcode, l_curr, l_country, l_terms
    FROM   vendors WHERE vendor_id = l_vendor_id;

    l_inv_date := TRUNC(SYSDATE) - TRUNC(DBMS_RANDOM.value(15, 365));
    l_net      := ROUND(DBMS_RANDOM.value(250, 20000), 2);
    IF DBMS_RANDOM.value < 0.10 THEN
      l_net := ROUND(l_net * 4, 2);            -- occasional large invoice
    END IF;

    l_tax_rate := CASE l_country WHEN 'PL' THEN 0.23 WHEN 'DE' THEN 0.19
                                 WHEN 'US' THEN 0    ELSE 0.20 END;

    l_status := CASE
                  WHEN l_inv_date < TRUNC(SYSDATE) - 60 THEN
                    CASE WHEN DBMS_RANDOM.value < 0.05 THEN 'REJECTED' ELSE 'PAID' END
                  ELSE 'APPROVED'
                END;

    INSERT INTO purchase_orders (po_number, vendor_id, cost_center_id, order_date,
                                 currency_code, po_amount, status)
    VALUES ('PO-' || TO_CHAR(2025000 + i), l_vendor_id, l_cc_id,
            l_inv_date - TRUNC(DBMS_RANDOM.value(5, 30)), l_curr,
            ROUND(l_net * DBMS_RANDOM.value(1.00, 1.10), 2),
            CASE WHEN l_status = 'PAID' THEN 'CLOSED' ELSE 'OPEN' END)
    RETURNING po_id INTO l_po_id;

    INSERT INTO invoices (vendor_id, po_id, cost_center_id, invoice_number, invoice_date,
                          received_date, due_date, currency_code, net_amount, tax_amount,
                          status, description)
    VALUES (l_vendor_id, l_po_id, l_cc_id,
            l_vcode || '/' || TO_CHAR(l_inv_date, 'YYYY') || '/' || LPAD(i, 4, '0'),
            l_inv_date, l_inv_date + TRUNC(DBMS_RANDOM.value(1, 6)), l_inv_date + l_terms,
            l_curr, l_net, ROUND(l_net * l_tax_rate, 2), l_status,
            'Generated historical invoice');
  END LOOP;

  COMMIT;
END;
/

-- ---------- Live work queue: planted scenarios ----------
DECLARE
  l_po NUMBER;

  FUNCTION vid (p_code VARCHAR2) RETURN NUMBER IS
    l_id NUMBER;
  BEGIN
    SELECT vendor_id INTO l_id FROM vendors WHERE vendor_code = p_code;
    RETURN l_id;
  END;

  FUNCTION ccid (p_code VARCHAR2) RETURN NUMBER IS
    l_id NUMBER;
  BEGIN
    SELECT cost_center_id INTO l_id FROM cost_centers WHERE cc_code = p_code;
    RETURN l_id;
  END;

  FUNCTION add_po (p_num VARCHAR2, p_vendor VARCHAR2, p_cc VARCHAR2,
                   p_curr VARCHAR2, p_amount NUMBER) RETURN NUMBER IS
    l_id        NUMBER;
    l_vendor_id NUMBER := vid(p_vendor);   -- resolved in PL/SQL, not inside SQL
    l_cc_id     NUMBER := ccid(p_cc);
  BEGIN
    INSERT INTO purchase_orders (po_number, vendor_id, cost_center_id, order_date, currency_code, po_amount)
    VALUES (p_num, l_vendor_id, l_cc_id, TRUNC(SYSDATE) - 20, p_curr, p_amount)
    RETURNING po_id INTO l_id;
    RETURN l_id;
  END;

  PROCEDURE add_inv (p_vendor VARCHAR2, p_po NUMBER, p_cc VARCHAR2, p_num VARCHAR2,
                     p_days_ago NUMBER, p_curr VARCHAR2, p_net NUMBER, p_tax NUMBER,
                     p_desc VARCHAR2) IS
    l_vendor_id NUMBER := vid(p_vendor);
    l_cc_id     NUMBER := ccid(p_cc);
  BEGIN
    INSERT INTO invoices (vendor_id, po_id, cost_center_id, invoice_number, invoice_date,
                          received_date, due_date, currency_code, net_amount, tax_amount,
                          status, description)
    VALUES (l_vendor_id, p_po, l_cc_id, p_num,
            TRUNC(SYSDATE) - p_days_ago, TRUNC(SYSDATE) - p_days_ago + 1,
            TRUNC(SYSDATE) - p_days_ago + 30,
            p_curr, p_net, p_tax, 'RECEIVED', p_desc);
  END;
BEGIN
  -- 1-3: clean invoices, one per approval level
  l_po := add_po('PO-LIVE-001', 'V-RHEIN',   'OPS', 'EUR', 4500);
  add_inv('V-RHEIN',   l_po, 'OPS', 'RHEIN/2026/L001',   5, 'EUR', 4200,   798,   'Clean - approval level 1');

  l_po := add_po('PO-LIVE-002', 'V-NORD',    'IT',  'EUR', 30000);
  add_inv('V-NORD',    l_po, 'IT',  'NORD/2026/L002',    4, 'EUR', 28000,  5600,  'Clean - approval level 2');

  l_po := add_po('PO-LIVE-003', 'V-LUMIERE', 'MKT', 'EUR', 70000);
  add_inv('V-LUMIERE', l_po, 'MKT', 'LUM/2026/L003',     3, 'EUR', 65000,  13000, 'Clean - approval level 3');

  -- 4-5: suspected duplicate (same vendor, same amount, different number, 3 days apart)
  l_po := add_po('PO-LIVE-004', 'V-ACME',    'FIN', 'PLN', 15000);
  add_inv('V-ACME',    l_po, 'FIN', 'ACME/2026/D001',   10, 'PLN', 12345.67, 2839.50, 'Planted: duplicate original');
  add_inv('V-ACME',    l_po, 'FIN', 'ACME/2026/D001A',   7, 'PLN', 12345.67, 2839.50, 'Planted: duplicate resubmission');

  -- 6: 17.5% over PO
  l_po := add_po('PO-LIVE-005', 'V-THAMES',  'IT',  'GBP', 20000);
  add_inv('V-THAMES',  l_po, 'IT',  'THM-2026-0099',     6, 'GBP', 23500,  4700,  'Planted: amount over PO tolerance');

  -- 7: 3% over PO - control case, must NOT be flagged
  l_po := add_po('PO-LIVE-006', 'V-WAWEL',   'OPS', 'PLN', 10000);
  add_inv('V-WAWEL',   l_po, 'OPS', 'WFM/2026/0412',     6, 'PLN', 10300,  2369,  'Control: within tolerance');

  -- 8: vendor on hold
  l_po := add_po('PO-LIVE-007', 'V-VISTULA', 'MKT', 'PLN', 3000);
  add_inv('V-VISTULA', l_po, 'MKT', 'VPH-2026-077',      2, 'PLN', 2800,   644,   'Planted: vendor on hold');

  -- 9: missing PO
  add_inv('V-ORBIT',   NULL, 'IT',  'ORB-INV-55120',     4, 'USD', 5400,   0,     'Planted: no purchase order');

  -- 10: currency mismatch (EUR vendor and PO, invoice in USD)
  l_po := add_po('PO-LIVE-008', 'V-RHEIN',   'OPS', 'EUR', 8000);
  add_inv('V-RHEIN',   l_po, 'OPS', 'RHEIN/2026/L010',   1, 'USD', 7900,   0,     'Planted: currency mismatch');

  COMMIT;
END;
/