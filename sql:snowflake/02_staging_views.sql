-- Standardize and deduplicate source-grain records.

USE WAREHOUSE SGI_WH;
USE DATABASE SGI_DB;

CREATE OR REPLACE VIEW STAGING.STG_AD_PERFORMANCE_DAILY AS
SELECT
  ad_date,
  UPPER(TRIM(campaign_id)) AS campaign_id,
  TRIM(campaign_name) AS campaign_name,
  TRIM(channel) AS channel,
  TRIM(platform) AS platform,
  impressions,
  clicks,
  spend_usd,
  source_updated_at,
  source_file_name,
  loaded_at
FROM RAW.AD_PERFORMANCE_DAILY
QUALIFY ROW_NUMBER() OVER (
  PARTITION BY ad_date, UPPER(TRIM(campaign_id))
  ORDER BY source_updated_at DESC, loaded_at DESC
) = 1;

CREATE OR REPLACE VIEW STAGING.STG_WEB_SESSIONS AS
SELECT
  TRIM(session_id) AS session_id,
  TRIM(visitor_id) AS visitor_id,
  session_ts,
  NULLIF(UPPER(TRIM(campaign_id)), '') AS campaign_id,
  NULLIF(LOWER(TRIM(utm_source)), '') AS utm_source,
  NULLIF(LOWER(TRIM(utm_medium)), '') AS utm_medium,
  NULLIF(LOWER(TRIM(utm_campaign)), '') AS utm_campaign,
  NULLIF(TRIM(click_id), '') AS click_id,
  TRIM(landing_page) AS landing_page,
  LOWER(TRIM(device_category)) AS device_category,
  tracked_trial_event,
  source_updated_at,
  source_file_name,
  loaded_at
FROM RAW.WEB_SESSIONS
QUALIFY ROW_NUMBER() OVER (
  PARTITION BY TRIM(session_id)
  ORDER BY source_updated_at DESC, loaded_at DESC
) = 1;

CREATE OR REPLACE VIEW STAGING.STG_SUBSCRIPTIONS AS
SELECT
  TRIM(subscription_id) AS subscription_id,
  TRIM(customer_id) AS customer_id,
  TRIM(visitor_id) AS visitor_id,
  trial_start_ts,
  paid_start_ts,
  TRIM(plan_name) AS plan_name,
  monthly_price_usd,
  NULLIF(UPPER(TRIM(signup_campaign_id)), '') AS signup_campaign_id,
  LOWER(TRIM(signup_device_category)) AS signup_device_category,
  TRIM(signup_landing_page) AS signup_landing_page,
  cancel_ts,
  NULLIF(TRIM(cancel_reason), '') AS cancel_reason,
  source_updated_at,
  source_file_name,
  loaded_at
FROM RAW.SUBSCRIPTIONS
QUALIFY ROW_NUMBER() OVER (
  PARTITION BY TRIM(subscription_id)
  ORDER BY source_updated_at DESC, loaded_at DESC
) = 1;

CREATE OR REPLACE VIEW STAGING.STG_BILLING_EVENTS AS
SELECT
  TRIM(billing_event_id) AS billing_event_id,
  TRIM(subscription_id) AS subscription_id,
  event_ts,
  LOWER(TRIM(event_type)) AS event_type,
  billing_cycle_number,
  LOWER(TRIM(event_status)) AS event_status,
  gross_amount_usd,
  discount_amount_usd,
  refund_amount_usd,
  chargeback_amount_usd,
  net_amount_usd,
  source_updated_at,
  source_file_name,
  loaded_at
FROM RAW.BILLING_EVENTS
QUALIFY ROW_NUMBER() OVER (
  PARTITION BY TRIM(billing_event_id)
  ORDER BY source_updated_at DESC, loaded_at DESC
) = 1;

