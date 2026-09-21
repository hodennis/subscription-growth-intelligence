-- Query-based QA suite. Every returned status should be PASS.

USE WAREHOUSE SGI_WH;
USE DATABASE SGI_DB;

WITH tests AS (
  SELECT
    '01_ad_source_key_unique' AS test_name,
    IFF(COUNT(*) = COUNT(DISTINCT ad_date || '|' || campaign_id), 'PASS', 'FAIL') AS status,
    COUNT(*) - COUNT(DISTINCT ad_date || '|' || campaign_id) AS failure_count
  FROM STAGING.STG_AD_PERFORMANCE_DAILY

  UNION ALL
  SELECT
    '02_session_source_key_unique',
    IFF(COUNT(*) = COUNT(DISTINCT session_id), 'PASS', 'FAIL'),
    COUNT(*) - COUNT(DISTINCT session_id)
  FROM STAGING.STG_WEB_SESSIONS

  UNION ALL
  SELECT
    '03_subscription_source_key_unique',
    IFF(COUNT(*) = COUNT(DISTINCT subscription_id), 'PASS', 'FAIL'),
    COUNT(*) - COUNT(DISTINCT subscription_id)
  FROM STAGING.STG_SUBSCRIPTIONS

  UNION ALL
  SELECT
    '04_billing_source_key_unique',
    IFF(COUNT(*) = COUNT(DISTINCT billing_event_id), 'PASS', 'FAIL'),
    COUNT(*) - COUNT(DISTINCT billing_event_id)
  FROM STAGING.STG_BILLING_EVENTS

  UNION ALL
  SELECT
    '05_ad_business_rules',
    IFF(COUNT_IF(impressions < 0 OR clicks < 0 OR clicks > impressions OR spend_usd < 0) = 0, 'PASS', 'FAIL'),
    COUNT_IF(impressions < 0 OR clicks < 0 OR clicks > impressions OR spend_usd < 0)
  FROM STAGING.STG_AD_PERFORMANCE_DAILY

  UNION ALL
  SELECT
    '06_billing_foreign_keys',
    IFF(COUNT_IF(subscription.subscription_id IS NULL) = 0, 'PASS', 'FAIL'),
    COUNT_IF(subscription.subscription_id IS NULL)
  FROM STAGING.STG_BILLING_EVENTS AS billing
  LEFT JOIN STAGING.STG_SUBSCRIPTIONS AS subscription
    ON billing.subscription_id = subscription.subscription_id

  UNION ALL
  SELECT
    '07_failed_charges_have_zero_net',
    IFF(COUNT_IF(event_type = 'charge' AND event_status = 'failed' AND net_amount_usd <> 0) = 0, 'PASS', 'FAIL'),
    COUNT_IF(event_type = 'charge' AND event_status = 'failed' AND net_amount_usd <> 0)
  FROM STAGING.STG_BILLING_EVENTS

  UNION ALL
  SELECT
    '08_paid_start_matches_first_payment',
    IFF(COUNT_IF(IFF(paid_start_ts IS NOT NULL, 1, 0) <> first_payment_success_flag) = 0, 'PASS', 'FAIL'),
    COUNT_IF(IFF(paid_start_ts IS NOT NULL, 1, 0) <> first_payment_success_flag)
  FROM MART.SUBSCRIPTION_FACT

  UNION ALL
  SELECT
    '09_campaign_mart_spend_reconciles',
    IFF(ABS(source_total - mart_total) < 0.01, 'PASS', 'FAIL'),
    ABS(source_total - mart_total)
  FROM (
    SELECT
      (SELECT SUM(spend_usd) FROM STAGING.STG_AD_PERFORMANCE_DAILY) AS source_total,
      (SELECT SUM(spend_usd) FROM MART.MART_CAMPAIGN_DAILY) AS mart_total
  )

  UNION ALL
  SELECT
    '10_campaign_mart_sessions_reconcile',
    IFF(source_total = mart_total, 'PASS', 'FAIL'),
    ABS(source_total - mart_total)
  FROM (
    SELECT
      (SELECT COUNT(DISTINCT session_id) FROM STAGING.STG_WEB_SESSIONS) AS source_total,
      (SELECT SUM(captured_sessions) FROM MART.MART_CAMPAIGN_DAILY) AS mart_total
  )

  UNION ALL
  SELECT
    '11_subscription_fact_revenue_reconciles',
    IFF(ABS(source_total - mart_total) < 0.01, 'PASS', 'FAIL'),
    ABS(source_total - mart_total)
  FROM (
    SELECT
      (SELECT SUM(net_amount_usd) FROM STAGING.STG_BILLING_EVENTS) AS source_total,
      (SELECT SUM(total_net_revenue_usd) FROM MART.SUBSCRIPTION_FACT) AS mart_total
  )

  UNION ALL
  SELECT
    '12_unattributed_trials_preserved',
    IFF(COUNT_IF(attributed_campaign_id = 'UNATTRIBUTED') > 0, 'PASS', 'FAIL'),
    IFF(COUNT_IF(attributed_campaign_id = 'UNATTRIBUTED') > 0, 0, 1)
  FROM MART.SUBSCRIPTION_FACT

  UNION ALL
  SELECT
    '13_expected_anomaly_flagged',
    IFF(COUNT_IF(attribution_health_status = 'TRACKING_WARNING') > 0, 'PASS', 'FAIL'),
    IFF(COUNT_IF(attribution_health_status = 'TRACKING_WARNING') > 0, 0, 1)
  FROM MART.MART_ATTRIBUTION_HEALTH
  WHERE report_date BETWEEN '2026-07-08' AND '2026-07-10'
    AND campaign_id = 'PS_GENERIC'

  UNION ALL
  SELECT
    '14_expected_segment_flagged',
    IFF(COUNT_IF(segment_health_status = 'SEGMENT_TRACKING_WARNING') > 0, 'PASS', 'FAIL'),
    IFF(COUNT_IF(segment_health_status = 'SEGMENT_TRACKING_WARNING') > 0, 0, 1)
  FROM MART.MART_ATTRIBUTION_SEGMENT
  WHERE report_date BETWEEN '2026-07-08' AND '2026-07-10'
    AND campaign_id = 'PS_GENERIC'
    AND device_category = 'mobile'
    AND landing_page = '/people-search'
)
SELECT *
FROM tests
ORDER BY test_name;

-- Manual anomaly evidence table for the investigation memo.
SELECT
  report_date,
  campaign_id,
  ad_clicks,
  captured_sessions,
  sessions_per_click,
  click_id_coverage,
  tracked_trial_events,
  backend_trials,
  successful_first_payments,
  attribution_health_status
FROM MART.MART_ATTRIBUTION_HEALTH
WHERE report_date BETWEEN '2026-07-01' AND '2026-07-17'
  AND campaign_id = 'PS_GENERIC'
ORDER BY report_date;

SELECT
  report_date,
  campaign_id,
  device_category,
  landing_page,
  captured_sessions,
  click_id_coverage,
  tracked_trial_events,
  backend_trials,
  successful_first_payments,
  segment_health_status
FROM MART.MART_ATTRIBUTION_SEGMENT
WHERE report_date BETWEEN '2026-07-01' AND '2026-07-17'
  AND campaign_id = 'PS_GENERIC'
  AND device_category = 'mobile'
  AND landing_page = '/people-search'
ORDER BY report_date;
