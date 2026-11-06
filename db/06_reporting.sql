-- =====================================================
-- 06_reporting.sql  Reporting views (analytic functions)
-- =====================================================

-- ---------- Base view: one row per invoice, enriched ----------
CREATE OR REPLACE VIEW v_invoice_overview AS
SELECT i.invoice_id,
       i.invoice_number,
       i.invoice_date,
       i.received_date,
       i.due_date,
       i.status,
       i.currency_code,
       i.net_amount,
       i.tax_amount,
       i.gross_amount,
       ROUND(i.gross_amount * fx.rate_to_eur, 2)          AS gross_eur,
       v.vendor_id,
       v.vendor_code,
       v.vendor_name,
       v.status                                           AS vendor_status,
       cc.cost_center_id,
       cc.cc_code,
       cc.cc_name,
       p.po_number,
       TRUNC(i.due_date) - TRUNC(SYSDATE)                 AS days_to_due,
       CASE
         WHEN i.status IN ('PAID', 'REJECTED')             THEN 'CLOSED'
         WHEN i.due_date <  TRUNC(SYSDATE) - 30            THEN 'OVERDUE 30+'
         WHEN i.due_date <  TRUNC(SYSDATE)                 THEN 'OVERDUE 1-30'
         WHEN i.due_date <= TRUNC(SYSDATE) + 7             THEN 'DUE IN 7 DAYS'
         ELSE 'NOT DUE'
       END                                                AS aging_bucket,
       (SELECT COUNT(*)
        FROM   invoice_anomalies a
        WHERE  a.invoice_id = i.invoice_id
        AND    a.status = 'OPEN')                          AS open_anomalies,
       (SELECT u.full_name
        FROM   invoice_approvals ap
        JOIN   app_users u ON u.user_id = ap.approver_id
        WHERE  ap.invoice_id = i.invoice_id
        AND    ap.decision = 'PENDING'
        ORDER  BY ap.approval_level
        FETCH  FIRST 1 ROW ONLY)                           AS current_approver,
       i.description,
       i.created_by,
       i.created_at
FROM   invoices i
JOIN   vendors       v  ON v.vendor_id        = i.vendor_id
JOIN   cost_centers  cc ON cc.cost_center_id  = i.cost_center_id
JOIN   fx_rates      fx ON fx.currency_code   = i.currency_code
LEFT   JOIN purchase_orders p ON p.po_id      = i.po_id;

-- ---------- Monthly trend: LAG, moving average, running total, YTD ----------
CREATE OR REPLACE VIEW v_monthly_spend AS
WITH m AS (
  SELECT TRUNC(invoice_date, 'MM')        AS month_start,
         COUNT(*)                         AS invoice_count,
         ROUND(SUM(gross_eur), 2)         AS spend_eur
  FROM   v_invoice_overview
  WHERE  status <> 'REJECTED'
  GROUP  BY TRUNC(invoice_date, 'MM')
)
SELECT month_start,
       TO_CHAR(month_start, 'YYYY-MM')                                    AS month_label,
       invoice_count,
       spend_eur,
       LAG(spend_eur) OVER (ORDER BY month_start)                         AS prev_month_eur,
       ROUND((spend_eur / NULLIF(LAG(spend_eur) OVER (ORDER BY month_start), 0) - 1) * 100, 1)
                                                                          AS mom_change_pct,
       ROUND(AVG(spend_eur) OVER (ORDER BY month_start
                                  ROWS BETWEEN 2 PRECEDING AND CURRENT ROW), 2)
                                                                          AS moving_avg_3m,
       SUM(spend_eur) OVER (ORDER BY month_start
                            ROWS UNBOUNDED PRECEDING)                     AS running_total_eur,
       SUM(spend_eur) OVER (PARTITION BY EXTRACT(YEAR FROM month_start)
                            ORDER BY month_start
                            ROWS UNBOUNDED PRECEDING)                     AS ytd_eur
FROM   m;

-- ---------- Vendor ranking (last 12 months): RANK, share, Pareto, quartiles ----------
CREATE OR REPLACE VIEW v_vendor_ranking AS
WITH s AS (
  SELECT vendor_id,
         vendor_code,
         vendor_name,
         vendor_status,
         COUNT(*)                                                       AS invoice_count,
         ROUND(SUM(gross_eur), 2)                                       AS spend_eur,
         ROUND(AVG(gross_eur), 2)                                       AS avg_invoice_eur,
         MAX(gross_eur)                                                 AS largest_invoice_eur,
         MAX(invoice_number) KEEP (DENSE_RANK LAST ORDER BY gross_eur)  AS largest_invoice
  FROM   v_invoice_overview
  WHERE  status <> 'REJECTED'
  AND    invoice_date >= ADD_MONTHS(TRUNC(SYSDATE), -12)
  GROUP  BY vendor_id, vendor_code, vendor_name, vendor_status
)
SELECT s.vendor_id,
       s.vendor_code,
       s.vendor_name,
       s.vendor_status,
       s.invoice_count,
       s.spend_eur,
       s.avg_invoice_eur,
       s.largest_invoice,
       s.largest_invoice_eur,
       RANK() OVER (ORDER BY s.spend_eur DESC)                             AS spend_rank,
       ROUND(RATIO_TO_REPORT(s.spend_eur) OVER () * 100, 1)                AS share_pct,
       ROUND(SUM(s.spend_eur) OVER (ORDER BY s.spend_eur DESC
                                    ROWS UNBOUNDED PRECEDING)
             / SUM(s.spend_eur) OVER () * 100, 1)                          AS cumulative_share_pct,
       NTILE(4) OVER (ORDER BY s.spend_eur DESC)                           AS spend_quartile,
       (SELECT COUNT(*)
        FROM   invoice_anomalies a
        JOIN   invoices i ON i.invoice_id = a.invoice_id
        WHERE  i.vendor_id = s.vendor_id)                                  AS anomaly_count
FROM   s;

-- ---------- Cost centre by month: analytic functions over aggregates ----------
CREATE OR REPLACE VIEW v_cost_center_monthly AS
SELECT cc_code,
       cc_name,
       TRUNC(invoice_date, 'MM')                                          AS month_start,
       TO_CHAR(TRUNC(invoice_date, 'MM'), 'YYYY-MM')                      AS month_label,
       COUNT(*)                                                           AS invoice_count,
       ROUND(SUM(gross_eur), 2)                                           AS spend_eur,
       ROUND(RATIO_TO_REPORT(SUM(gross_eur))
             OVER (PARTITION BY TRUNC(invoice_date, 'MM')) * 100, 1)      AS share_of_month_pct,
       RANK() OVER (PARTITION BY TRUNC(invoice_date, 'MM')
                    ORDER BY SUM(gross_eur) DESC)                         AS rank_in_month,
       ROUND(SUM(SUM(gross_eur)) OVER (PARTITION BY cc_code,
                                                    EXTRACT(YEAR FROM TRUNC(invoice_date, 'MM'))
                                       ORDER BY TRUNC(invoice_date, 'MM')
                                       ROWS UNBOUNDED PRECEDING), 2)      AS ytd_eur
FROM   v_invoice_overview
WHERE  status <> 'REJECTED'
GROUP  BY cc_code, cc_name, TRUNC(invoice_date, 'MM');

-- ---------- Statistical outliers per vendor: z-score, LAG, PERCENT_RANK ----------
CREATE OR REPLACE VIEW v_invoice_outliers AS
WITH x AS (
  SELECT invoice_id,
         invoice_number,
         vendor_id,
         vendor_code,
         invoice_date,
         status,
         gross_eur,
         ROUND(AVG(gross_eur)    OVER (PARTITION BY vendor_id), 2)        AS vendor_avg_eur,
         ROUND(STDDEV(gross_eur) OVER (PARTITION BY vendor_id), 2)        AS vendor_stddev_eur,
         COUNT(*)                OVER (PARTITION BY vendor_id)            AS vendor_invoice_count,
         invoice_date - LAG(invoice_date) OVER (PARTITION BY vendor_id
                                                ORDER BY invoice_date, invoice_id)
                                                                          AS days_since_prev,
         ROUND(PERCENT_RANK() OVER (PARTITION BY vendor_id
                                    ORDER BY gross_eur) * 100, 1)         AS percentile_in_vendor
  FROM   v_invoice_overview
  WHERE  status <> 'REJECTED'
)
SELECT x.*,
       ROUND((gross_eur - vendor_avg_eur) / NULLIF(vendor_stddev_eur, 0), 2) AS z_score,
       CASE
         WHEN ABS((gross_eur - vendor_avg_eur) / NULLIF(vendor_stddev_eur, 0)) >= 2
         THEN 'Y' ELSE 'N'
       END                                                                 AS outlier_yn
FROM   x;

-- ---------- Anomalies by type and status ----------
CREATE OR REPLACE VIEW v_anomaly_summary AS
SELECT t.anomaly_code,
       t.description,
       t.severity,
       COUNT(a.anomaly_id)                                  AS total_count,
       COUNT(CASE WHEN a.status = 'OPEN'      THEN 1 END)   AS open_count,
       COUNT(CASE WHEN a.status = 'RESOLVED'  THEN 1 END)   AS resolved_count,
       COUNT(CASE WHEN a.status = 'DISMISSED' THEN 1 END)   AS dismissed_count
FROM   anomaly_types t
LEFT   JOIN invoice_anomalies a ON a.anomaly_code = t.anomaly_code
GROUP  BY t.anomaly_code, t.description, t.severity;

-- ---------- Dashboard KPI tiles (single row) ----------
CREATE OR REPLACE VIEW v_dashboard_kpis AS
SELECT
  (SELECT COUNT(*) FROM invoices
   WHERE  status IN ('RECEIVED', 'FLAGGED', 'PENDING_APPROVAL'))          AS open_queue,
  (SELECT COUNT(*) FROM invoices WHERE status = 'FLAGGED')               AS flagged,
  (SELECT COUNT(*) FROM invoices WHERE status = 'PENDING_APPROVAL')      AS pending_approval,
  (SELECT COUNT(*)
   FROM   invoice_anomalies a
   JOIN   anomaly_types t ON t.anomaly_code = a.anomaly_code
   WHERE  a.status = 'OPEN' AND t.severity = 'HIGH')                     AS open_high_anomalies,
  (SELECT ROUND(NVL(SUM(gross_eur), 0))
   FROM   v_invoice_overview WHERE status = 'PENDING_APPROVAL')          AS pending_eur,
  (SELECT ROUND(NVL(SUM(gross_eur), 0))
   FROM   v_invoice_overview
   WHERE  status <> 'REJECTED'
   AND    invoice_date >= TRUNC(SYSDATE, 'YYYY'))                        AS spend_ytd_eur,
  (SELECT COUNT(*)
   FROM   v_invoice_overview
   WHERE  aging_bucket LIKE 'OVERDUE%')                                  AS overdue_count
FROM dual;