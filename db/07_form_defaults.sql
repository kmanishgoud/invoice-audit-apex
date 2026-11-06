-- =====================================================
-- 07_form_defaults.sql  Defaults that also apply to explicit NULLs
-- =====================================================

ALTER TABLE invoices MODIFY (
  status        DEFAULT ON NULL 'RECEIVED',
  received_date DEFAULT ON NULL TRUNC(SYSDATE),
  tax_amount    DEFAULT ON NULL 0,
  created_by    DEFAULT ON NULL COALESCE(SYS_CONTEXT('APEX$SESSION', 'APP_USER'), USER),
  created_at    DEFAULT ON NULL SYSTIMESTAMP
);

ALTER TABLE vendors MODIFY (
  currency_code      DEFAULT ON NULL 'EUR',
  payment_terms_days DEFAULT ON NULL 30,
  status             DEFAULT ON NULL 'ACTIVE',
  created_at         DEFAULT ON NULL SYSTIMESTAMP
);

ALTER TABLE purchase_orders MODIFY (
  status DEFAULT ON NULL 'OPEN'
);