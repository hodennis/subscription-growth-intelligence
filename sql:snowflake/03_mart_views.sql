-- Governed attribution, billing, campaign, cohort, and diagnostic marts.
-- Fixed case-study parameters:
--   analysis timestamp: 2026-07-31 23:59:59
--   trial maturity: 7 days
--   last-non-direct lookback: 30 days
--   realized revenue window: 90 days after paid start

USE WAREHOUSE SGI_WH;
USE DATABASE SGI_DB;

CREATE OR REPLACE VIEW MART.SUBSCRIPTION_ATTRIBUTION AS
WITH ranked_touches AS (
  SELECT
    subscription.subscription_id,
    session.session_id,
    session.session_ts,
    session.campaign_id,
    DATEDIFF('day', session.session_ts, subscription.trial_start_ts) AS attribution_lag_days,
    ROW_NUMBER() OVER (
      PARTITION BY subscription.subscription_id
      ORDER BY session.session_ts DESC, session.session_id DESC
    ) AS touch_rank
  FROM STAGING.STG_SUBSCRIPTIONS AS subscription
  INNER JOIN STAGING.STG_WEB_SESSIONS AS session
    ON subscription.visitor_id = session.visitor_id
   AND session.campaign_id IS NOT NULL
   AND session.session_ts <= subscription.trial_start_ts
   AND session.session_ts >= DATEADD('day', -30, subscription.trial_start_ts)
),
selected_touch AS (
  SELECT *
  FROM ranked_touches
  WHERE touch_rank = 1
)
SELECT
  subscription.subscription_id,
  selected_touch.session_id AS attributed_session_id,
  selected_touch.session_ts AS attributed_session_ts,
  COALESCE(selected_touch.campaign_id, 'UNATTRIBUTED') AS attributed_campaign_id,
  selected_touch.attribution_lag_days
FROM STAGING.STG_SUBSCRIPTIONS AS subscription
LEFT JOIN selected_touch
  ON subscription.subscription_id = selected_touch.subscription_id;

CREATE OR REPLACE VIEW MART.SUBSCRIPTION_BILLING_SUMMARY AS
SELECT
  subscription.subscription_id,
  MAX(IFF(
    billing.event_type = 'charge'
    AND billing.billing_cycle_number = 1
    AND billing.event_status = 'succeeded', 1, 0
  )) AS first_payment_success_flag,
  MIN(IFF(
    billing.event_type = 'charge'
    AND billing.billing_cycle_number = 1
    AND billing.event_status = 'succeeded', billing.event_ts, NULL
  )) AS first_payment_ts,
  MAX(IFF(
    billing.event_type = 'charge'
    AND billing.billing_cycle_number = 2
    AND billing.event_status = 'succeeded', 1, 0
  )) AS first_rebill_success_flag,
  MAX(IFF(
    billing.event_type = 'charge'
    AND billing.billing_cycle_number = 3
    AND billing.event_status = 'succeeded', 1, 0
  )) AS second_rebill_success_flag,
  COUNT_IF(billing.event_type = 'charge' AND billing.event_status = 'failed') AS failed_charge_attempts,
  COALESCE(SUM(billing.net_amount_usd), 0) AS total_net_revenue_usd,
  COALESCE(SUM(IFF(
    subscription.paid_start_ts IS NOT NULL
    AND billing.event_ts >= subscription.paid_start_ts
    AND billing.event_ts <= DATEADD('day', 90, subscription.paid_start_ts),
    billing.net_amount_usd,
    0
  )), 0) AS net_revenue_90d_usd
FROM STAGING.STG_SUBSCRIPTIONS AS subscription
LEFT JOIN STAGING.STG_BILLING_EVENTS AS billing
  ON subscription.subscription_id = billing.subscription_id
GROUP BY subscription.subscription_id;

CREATE OR REPLACE VIEW MART.SUBSCRIPTION_FACT AS
WITH parameters AS (
  SELECT TO_TIMESTAMP_NTZ('2026-07-31 23:59:59') AS analysis_ts
),
campaign_dimension AS (
  SELECT
    campaign_id,
    MAX(campaign_name) AS campaign_name,
    MAX(channel) AS channel,
    MAX(platform) AS platform
  FROM STAGING.STG_AD_PERFORMANCE_DAILY
  GROUP BY campaign_id
)
SELECT
  subscription.subscription_id,
  subscription.customer_id,
  subscription.visitor_id,
  subscription.trial_start_ts,
  subscription.paid_start_ts,
  subscription.plan_name,
  subscription.monthly_price_usd,
  subscription.signup_campaign_id,
  subscription.signup_device_category,
  subscription.signup_landing_page,
  subscription.cancel_ts,
  subscription.cancel_reason,
  attribution.attributed_session_id,
  attribution.attributed_session_ts,
  attribution.attributed_campaign_id,
  COALESCE(campaign_dimension.campaign_name, 'Unattributed') AS attributed_campaign_name,
  COALESCE(campaign_dimension.channel, 'Unattributed') AS attributed_channel,
  COALESCE(campaign_dimension.platform, 'Unattributed') AS attributed_platform,
  attribution.attribution_lag_days,
  IFF(DATEADD('day', 7, subscription.trial_start_ts) <= parameters.analysis_ts, 1, 0) AS trial_mature_flag,
  IFF(
    subscription.paid_start_ts IS NOT NULL
    AND DATEADD('day', 30, subscription.paid_start_ts) <= parameters.analysis_ts,
    1, 0
  ) AS first_rebill_eligible_flag,
  IFF(
    subscription.paid_start_ts IS NOT NULL
    AND DATEADD('day', 60, subscription.paid_start_ts) <= parameters.analysis_ts,
    1, 0
  ) AS second_rebill_eligible_flag,
  IFF(
    subscription.paid_start_ts IS NOT NULL
    AND DATEADD('day', 90, subscription.paid_start_ts) <= parameters.analysis_ts,
    1, 0
  ) AS revenue_90d_mature_flag,
  billing.first_payment_success_flag,
  billing.first_payment_ts,
  billing.first_rebill_success_flag,
  billing.second_rebill_success_flag,
  billing.failed_charge_attempts,
  billing.total_net_revenue_usd,
  billing.net_revenue_90d_usd
FROM STAGING.STG_SUBSCRIPTIONS AS subscription
CROSS JOIN parameters
INNER JOIN MART.SUBSCRIPTION_ATTRIBUTION AS attribution
  ON subscription.subscription_id = attribution.subscription_id
INNER JOIN MART.SUBSCRIPTION_BILLING_SUMMARY AS billing
  ON subscription.subscription_id = billing.subscription_id
LEFT JOIN campaign_dimension
  ON attribution.attributed_campaign_id = campaign_dimension.campaign_id;

CREATE OR REPLACE VIEW MART.MART_CAMPAIGN_DAILY AS
WITH parameters AS (
  SELECT TO_DATE('2026-07-31') AS analysis_date
),
ad_daily AS (
  SELECT
    ad_date AS report_date,
    campaign_id,
    MAX(campaign_name) AS campaign_name,
    MAX(channel) AS channel,
    MAX(platform) AS platform,
    SUM(impressions) AS impressions,
    SUM(clicks) AS clicks,
    SUM(spend_usd) AS spend_usd
  FROM STAGING.STG_AD_PERFORMANCE_DAILY
  GROUP BY ad_date, campaign_id
),
session_daily AS (
  SELECT
    TO_DATE(session_ts) AS report_date,
    COALESCE(campaign_id, 'UNATTRIBUTED') AS campaign_id,
    COUNT(DISTINCT session_id) AS captured_sessions,
    COUNT(DISTINCT IFF(click_id IS NOT NULL, session_id, NULL)) AS sessions_with_click_id,
    COUNT(DISTINCT IFF(tracked_trial_event, session_id, NULL)) AS tracked_trial_events
  FROM STAGING.STG_WEB_SESSIONS
  GROUP BY TO_DATE(session_ts), COALESCE(campaign_id, 'UNATTRIBUTED')
),
subscription_daily AS (
  SELECT
    TO_DATE(trial_start_ts) AS report_date,
    attributed_campaign_id AS campaign_id,
    COUNT(DISTINCT subscription_id) AS backend_trials,
    COUNT(DISTINCT IFF(trial_mature_flag = 1, subscription_id, NULL)) AS eligible_trials,
    COUNT(DISTINCT IFF(
      trial_mature_flag = 1 AND first_payment_success_flag = 1,
      subscription_id, NULL
    )) AS first_time_paid_subscribers,
    COUNT(DISTINCT IFF(revenue_90d_mature_flag = 1, subscription_id, NULL)) AS revenue_90d_mature_subscribers,
    SUM(IFF(revenue_90d_mature_flag = 1, net_revenue_90d_usd, 0)) AS realized_90d_net_revenue_usd
  FROM MART.SUBSCRIPTION_FACT
  GROUP BY TO_DATE(trial_start_ts), attributed_campaign_id
),
reporting_keys AS (
  SELECT report_date, campaign_id FROM ad_daily
  UNION
  SELECT report_date, campaign_id FROM session_daily
  UNION
  SELECT report_date, campaign_id FROM subscription_daily
),
joined AS (
  SELECT
    key.report_date,
    key.campaign_id,
    COALESCE(ad.campaign_name, IFF(key.campaign_id = 'UNATTRIBUTED', 'Unattributed', key.campaign_id)) AS campaign_name,
    COALESCE(ad.channel, IFF(key.campaign_id = 'UNATTRIBUTED', 'Unattributed', 'Unknown')) AS channel,
    COALESCE(ad.platform, IFF(key.campaign_id = 'UNATTRIBUTED', 'Unattributed', 'Unknown')) AS platform,
    COALESCE(ad.impressions, 0) AS impressions,
    COALESCE(ad.clicks, 0) AS clicks,
    COALESCE(ad.spend_usd, 0) AS spend_usd,
    COALESCE(session.captured_sessions, 0) AS captured_sessions,
    COALESCE(session.sessions_with_click_id, 0) AS sessions_with_click_id,
    COALESCE(session.tracked_trial_events, 0) AS tracked_trial_events,
    COALESCE(subscription.backend_trials, 0) AS backend_trials,
    COALESCE(subscription.eligible_trials, 0) AS eligible_trials,
    COALESCE(subscription.first_time_paid_subscribers, 0) AS first_time_paid_subscribers,
    COALESCE(subscription.revenue_90d_mature_subscribers, 0) AS revenue_90d_mature_subscribers,
    COALESCE(subscription.realized_90d_net_revenue_usd, 0) AS realized_90d_net_revenue_usd
  FROM reporting_keys AS key
  LEFT JOIN ad_daily AS ad
    ON key.report_date = ad.report_date AND key.campaign_id = ad.campaign_id
  LEFT JOIN session_daily AS session
    ON key.report_date = session.report_date AND key.campaign_id = session.campaign_id
  LEFT JOIN subscription_daily AS subscription
    ON key.report_date = subscription.report_date AND key.campaign_id = subscription.campaign_id
)
SELECT
  joined.*,
  joined.clicks / NULLIF(joined.impressions, 0) AS click_through_rate,
  joined.spend_usd / NULLIF(joined.clicks, 0) AS cost_per_click_usd,
  joined.sessions_with_click_id / NULLIF(joined.captured_sessions, 0) AS click_id_coverage,
  IFF(
    joined.spend_usd > 0,
    joined.spend_usd / NULLIF(joined.backend_trials, 0),
    NULL
  ) AS trial_cpa_usd,
  IFF(
    joined.spend_usd > 0,
    joined.spend_usd / NULLIF(joined.first_time_paid_subscribers, 0),
    NULL
  ) AS paid_cac_usd,
  joined.first_time_paid_subscribers / NULLIF(joined.eligible_trials, 0) AS trial_to_paid_rate,
  IFF(
    joined.report_date <= DATEADD('day', -97, parameters.analysis_date),
    joined.spend_usd,
    0
  ) AS mature_90d_spend_usd,
  joined.realized_90d_net_revenue_usd / NULLIF(
    IFF(joined.report_date <= DATEADD('day', -97, parameters.analysis_date), joined.spend_usd, 0),
    0
  ) AS realized_90d_roas
FROM joined
CROSS JOIN parameters;

CREATE OR REPLACE VIEW MART.MART_SUBSCRIPTION_COHORT AS
WITH cohort_counts AS (
  SELECT
    DATE_TRUNC('month', trial_start_ts)::DATE AS trial_cohort_month,
    attributed_campaign_id,
    MAX(attributed_campaign_name) AS attributed_campaign_name,
    MAX(attributed_channel) AS attributed_channel,
    COUNT(DISTINCT subscription_id) AS trials,
    COUNT(DISTINCT IFF(trial_mature_flag = 1, subscription_id, NULL)) AS eligible_trials,
    COUNT(DISTINCT IFF(
      trial_mature_flag = 1 AND first_payment_success_flag = 1,
      subscription_id, NULL
    )) AS paid_subscribers,
    COUNT(DISTINCT IFF(first_rebill_eligible_flag = 1, subscription_id, NULL)) AS first_rebill_eligible_subscribers,
    COUNT(DISTINCT IFF(
      first_rebill_eligible_flag = 1 AND first_rebill_success_flag = 1,
      subscription_id, NULL
    )) AS first_rebill_subscribers,
    COUNT(DISTINCT IFF(second_rebill_eligible_flag = 1, subscription_id, NULL)) AS second_rebill_eligible_subscribers,
    COUNT(DISTINCT IFF(
      second_rebill_eligible_flag = 1 AND second_rebill_success_flag = 1,
      subscription_id, NULL
    )) AS second_rebill_subscribers,
    COUNT(DISTINCT IFF(revenue_90d_mature_flag = 1, subscription_id, NULL)) AS revenue_90d_mature_subscribers,
    SUM(IFF(revenue_90d_mature_flag = 1, net_revenue_90d_usd, 0)) AS realized_90d_net_revenue_usd
  FROM MART.SUBSCRIPTION_FACT
  GROUP BY DATE_TRUNC('month', trial_start_ts)::DATE, attributed_campaign_id
)
SELECT
  cohort_counts.*,
  paid_subscribers / NULLIF(eligible_trials, 0) AS trial_to_paid_rate,
  first_rebill_subscribers / NULLIF(first_rebill_eligible_subscribers, 0) AS first_rebill_rate,
  second_rebill_subscribers / NULLIF(second_rebill_eligible_subscribers, 0) AS second_rebill_rate,
  realized_90d_net_revenue_usd / NULLIF(revenue_90d_mature_subscribers, 0) AS realized_90d_net_revenue_per_mature_subscriber_usd
FROM cohort_counts;

CREATE OR REPLACE VIEW MART.MART_ATTRIBUTION_HEALTH AS
WITH ad_daily AS (
  SELECT
    ad_date AS report_date,
    campaign_id,
    MAX(campaign_name) AS campaign_name,
    SUM(clicks) AS ad_clicks,
    SUM(spend_usd) AS spend_usd
  FROM STAGING.STG_AD_PERFORMANCE_DAILY
  GROUP BY ad_date, campaign_id
),
session_daily AS (
  SELECT
    TO_DATE(session_ts) AS report_date,
    campaign_id,
    COUNT(DISTINCT session_id) AS captured_sessions,
    COUNT(DISTINCT IFF(click_id IS NOT NULL, session_id, NULL)) AS sessions_with_click_id,
    COUNT(DISTINCT IFF(tracked_trial_event, session_id, NULL)) AS tracked_trial_events
  FROM STAGING.STG_WEB_SESSIONS
  WHERE campaign_id IS NOT NULL
  GROUP BY TO_DATE(session_ts), campaign_id
),
backend_daily AS (
  SELECT
    TO_DATE(fact.trial_start_ts) AS report_date,
    fact.signup_campaign_id AS campaign_id,
    COUNT(DISTINCT fact.subscription_id) AS backend_trials,
    COUNT(DISTINCT IFF(fact.first_payment_success_flag = 1, fact.subscription_id, NULL)) AS successful_first_payments
  FROM MART.SUBSCRIPTION_FACT AS fact
  WHERE fact.signup_campaign_id IS NOT NULL
  GROUP BY TO_DATE(fact.trial_start_ts), fact.signup_campaign_id
),
reporting_keys AS (
  SELECT report_date, campaign_id FROM ad_daily
  UNION
  SELECT report_date, campaign_id FROM session_daily
  UNION
  SELECT report_date, campaign_id FROM backend_daily
),
base AS (
  SELECT
    key.report_date,
    key.campaign_id,
    COALESCE(ad.campaign_name, key.campaign_id) AS campaign_name,
    COALESCE(ad.ad_clicks, 0) AS ad_clicks,
    COALESCE(ad.spend_usd, 0) AS spend_usd,
    COALESCE(session.captured_sessions, 0) AS captured_sessions,
    COALESCE(session.sessions_with_click_id, 0) AS sessions_with_click_id,
    COALESCE(session.tracked_trial_events, 0) AS tracked_trial_events,
    COALESCE(backend.backend_trials, 0) AS backend_trials,
    COALESCE(backend.successful_first_payments, 0) AS successful_first_payments
  FROM reporting_keys AS key
  LEFT JOIN ad_daily AS ad
    ON key.report_date = ad.report_date AND key.campaign_id = ad.campaign_id
  LEFT JOIN session_daily AS session
    ON key.report_date = session.report_date AND key.campaign_id = session.campaign_id
  LEFT JOIN backend_daily AS backend
    ON key.report_date = backend.report_date AND key.campaign_id = backend.campaign_id
),
rates AS (
  SELECT
    base.*,
    captured_sessions / NULLIF(ad_clicks, 0) AS sessions_per_click,
    sessions_with_click_id / NULLIF(captured_sessions, 0) AS click_id_coverage,
    tracked_trial_events / NULLIF(backend_trials, 0) AS tracked_to_backend_trial_ratio,
    backend_trials / NULLIF(ad_clicks, 0) AS backend_trials_per_click
  FROM base
),
baselines AS (
  SELECT
    rates.*,
    AVG(sessions_per_click) OVER (
      PARTITION BY campaign_id ORDER BY report_date
      ROWS BETWEEN 14 PRECEDING AND 1 PRECEDING
    ) AS sessions_per_click_prior_14d,
    AVG(click_id_coverage) OVER (
      PARTITION BY campaign_id ORDER BY report_date
      ROWS BETWEEN 14 PRECEDING AND 1 PRECEDING
    ) AS click_id_coverage_prior_14d,
    AVG(backend_trials_per_click) OVER (
      PARTITION BY campaign_id ORDER BY report_date
      ROWS BETWEEN 14 PRECEDING AND 1 PRECEDING
    ) AS backend_trials_per_click_prior_14d
  FROM rates
)
SELECT
  baselines.*,
  tracked_trial_events - backend_trials AS trial_reconciliation_variance,
  IFF(
    sessions_per_click < 0.75 * sessions_per_click_prior_14d
    AND click_id_coverage < 0.75 * click_id_coverage_prior_14d
    AND backend_trials_per_click >= 0.60 * backend_trials_per_click_prior_14d,
    'TRACKING_WARNING',
    'NO_ALERT'
  ) AS attribution_health_status
FROM baselines;

CREATE OR REPLACE VIEW MART.MART_ATTRIBUTION_SEGMENT AS
WITH session_segment AS (
  SELECT
    TO_DATE(session_ts) AS report_date,
    COALESCE(campaign_id, 'UNATTRIBUTED') AS campaign_id,
    device_category,
    landing_page,
    COUNT(DISTINCT session_id) AS captured_sessions,
    COUNT(DISTINCT IFF(click_id IS NOT NULL, session_id, NULL)) AS sessions_with_click_id,
    COUNT(DISTINCT IFF(tracked_trial_event, session_id, NULL)) AS tracked_trial_events
  FROM STAGING.STG_WEB_SESSIONS
  GROUP BY
    TO_DATE(session_ts), COALESCE(campaign_id, 'UNATTRIBUTED'),
    device_category, landing_page
),
backend_segment AS (
  SELECT
    TO_DATE(trial_start_ts) AS report_date,
    COALESCE(signup_campaign_id, 'UNATTRIBUTED') AS campaign_id,
    signup_device_category AS device_category,
    signup_landing_page AS landing_page,
    COUNT(DISTINCT subscription_id) AS backend_trials,
    COUNT(DISTINCT IFF(first_payment_success_flag = 1, subscription_id, NULL)) AS successful_first_payments
  FROM MART.SUBSCRIPTION_FACT
  GROUP BY
    TO_DATE(trial_start_ts), COALESCE(signup_campaign_id, 'UNATTRIBUTED'),
    signup_device_category, signup_landing_page
),
reporting_keys AS (
  SELECT report_date, campaign_id, device_category, landing_page FROM session_segment
  UNION
  SELECT report_date, campaign_id, device_category, landing_page FROM backend_segment
),
base AS (
  SELECT
    key.report_date,
    key.campaign_id,
    key.device_category,
    key.landing_page,
    COALESCE(session.captured_sessions, 0) AS captured_sessions,
    COALESCE(session.sessions_with_click_id, 0) AS sessions_with_click_id,
    COALESCE(session.tracked_trial_events, 0) AS tracked_trial_events,
    COALESCE(backend.backend_trials, 0) AS backend_trials,
    COALESCE(backend.successful_first_payments, 0) AS successful_first_payments
  FROM reporting_keys AS key
  LEFT JOIN session_segment AS session
    ON key.report_date = session.report_date
   AND key.campaign_id = session.campaign_id
   AND key.device_category = session.device_category
   AND key.landing_page = session.landing_page
  LEFT JOIN backend_segment AS backend
    ON key.report_date = backend.report_date
   AND key.campaign_id = backend.campaign_id
   AND key.device_category = backend.device_category
   AND key.landing_page = backend.landing_page
),
rates AS (
  SELECT
    base.*,
    sessions_with_click_id / NULLIF(captured_sessions, 0) AS click_id_coverage,
    tracked_trial_events / NULLIF(backend_trials, 0) AS tracked_to_backend_trial_ratio
  FROM base
),
baselines AS (
  SELECT
    rates.*,
    AVG(click_id_coverage) OVER (
      PARTITION BY campaign_id, device_category, landing_page
      ORDER BY report_date ROWS BETWEEN 14 PRECEDING AND 1 PRECEDING
    ) AS click_id_coverage_prior_14d,
    AVG(tracked_to_backend_trial_ratio) OVER (
      PARTITION BY campaign_id, device_category, landing_page
      ORDER BY report_date ROWS BETWEEN 14 PRECEDING AND 1 PRECEDING
    ) AS tracked_to_backend_prior_14d
  FROM rates
)
SELECT
  baselines.*,
  tracked_trial_events - backend_trials AS trial_reconciliation_variance,
  IFF(
    click_id_coverage < 0.60 * click_id_coverage_prior_14d
    AND tracked_to_backend_trial_ratio < 0.60 * tracked_to_backend_prior_14d,
    'SEGMENT_TRACKING_WARNING',
    'NO_ALERT'
  ) AS segment_health_status
FROM baselines;
