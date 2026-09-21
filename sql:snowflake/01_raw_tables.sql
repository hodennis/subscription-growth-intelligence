-- Create typed RAW tables, then load four CSVs uploaded to @RAW.SGI_CSV_STAGE.
-- Expected stage-root filenames:
--   ad_performance_daily.csv
--   web_sessions.csv.gz
--   subscriptions.csv
--   billing_events.csv

USE WAREHOUSE SGI_WH;
USE DATABASE SGI_DB;
USE SCHEMA RAW;

CREATE OR REPLACE TABLE AD_PERFORMANCE_DAILY (
  ad_date DATE NOT NULL,
  campaign_id VARCHAR(40) NOT NULL,
  campaign_name VARCHAR(100) NOT NULL,
  channel VARCHAR(40) NOT NULL,
  platform VARCHAR(40) NOT NULL,
  impressions INTEGER NOT NULL,
  clicks INTEGER NOT NULL,
  spend_usd NUMBER(12,2) NOT NULL,
  source_updated_at TIMESTAMP_NTZ NOT NULL,
  source_file_name VARCHAR(500) NOT NULL,
  loaded_at TIMESTAMP_LTZ NOT NULL DEFAULT CURRENT_TIMESTAMP()
);

CREATE OR REPLACE TABLE WEB_SESSIONS (
  session_id VARCHAR(50) NOT NULL,
  visitor_id VARCHAR(50) NOT NULL,
  session_ts TIMESTAMP_NTZ NOT NULL,
  campaign_id VARCHAR(40),
  utm_source VARCHAR(80),
  utm_medium VARCHAR(80),
  utm_campaign VARCHAR(120),
  click_id VARCHAR(100),
  landing_page VARCHAR(200) NOT NULL,
  device_category VARCHAR(20) NOT NULL,
  tracked_trial_event BOOLEAN NOT NULL,
  source_updated_at TIMESTAMP_NTZ NOT NULL,
  source_file_name VARCHAR(500) NOT NULL,
  loaded_at TIMESTAMP_LTZ NOT NULL DEFAULT CURRENT_TIMESTAMP()
);

CREATE OR REPLACE TABLE SUBSCRIPTIONS (
  subscription_id VARCHAR(50) NOT NULL,
  customer_id VARCHAR(50) NOT NULL,
  visitor_id VARCHAR(50) NOT NULL,
  trial_start_ts TIMESTAMP_NTZ NOT NULL,
  paid_start_ts TIMESTAMP_NTZ,
  plan_name VARCHAR(60) NOT NULL,
  monthly_price_usd NUMBER(10,2) NOT NULL,
  signup_campaign_id VARCHAR(40),
  signup_device_category VARCHAR(20) NOT NULL,
  signup_landing_page VARCHAR(200) NOT NULL,
  cancel_ts TIMESTAMP_NTZ,
  cancel_reason VARCHAR(120),
  source_updated_at TIMESTAMP_NTZ NOT NULL,
  source_file_name VARCHAR(500) NOT NULL,
  loaded_at TIMESTAMP_LTZ NOT NULL DEFAULT CURRENT_TIMESTAMP()
);

CREATE OR REPLACE TABLE BILLING_EVENTS (
  billing_event_id VARCHAR(60) NOT NULL,
  subscription_id VARCHAR(50) NOT NULL,
  event_ts TIMESTAMP_NTZ NOT NULL,
  event_type VARCHAR(20) NOT NULL,
  billing_cycle_number INTEGER,
  event_status VARCHAR(20) NOT NULL,
  gross_amount_usd NUMBER(10,2) NOT NULL,
  discount_amount_usd NUMBER(10,2) NOT NULL,
  refund_amount_usd NUMBER(10,2) NOT NULL,
  chargeback_amount_usd NUMBER(10,2) NOT NULL,
  net_amount_usd NUMBER(10,2) NOT NULL,
  source_updated_at TIMESTAMP_NTZ NOT NULL,
  source_file_name VARCHAR(500) NOT NULL,
  loaded_at TIMESTAMP_LTZ NOT NULL DEFAULT CURRENT_TIMESTAMP()
);

COPY INTO AD_PERFORMANCE_DAILY (
  ad_date, campaign_id, campaign_name, channel, platform, impressions, clicks,
  spend_usd, source_updated_at, source_file_name
)
FROM (
  SELECT
    $1::DATE, $2::VARCHAR, $3::VARCHAR, $4::VARCHAR, $5::VARCHAR,
    $6::INTEGER, $7::INTEGER, $8::NUMBER(12,2), $9::TIMESTAMP_NTZ,
    METADATA$FILENAME
  FROM @RAW.SGI_CSV_STAGE
)
FILES = ('ad_performance_daily.csv')
FILE_FORMAT = (FORMAT_NAME = 'SGI_DB.RAW.SGI_CSV_FORMAT')
ON_ERROR = 'ABORT_STATEMENT'
FORCE = TRUE;

COPY INTO WEB_SESSIONS (
  session_id, visitor_id, session_ts, campaign_id, utm_source, utm_medium,
  utm_campaign, click_id, landing_page, device_category, tracked_trial_event,
  source_updated_at, source_file_name
)
FROM (
  SELECT
    $1::VARCHAR, $2::VARCHAR, $3::TIMESTAMP_NTZ, $4::VARCHAR,
    $5::VARCHAR, $6::VARCHAR, $7::VARCHAR,
    $8::VARCHAR, $9::VARCHAR, $10::VARCHAR,
    $11::BOOLEAN, $12::TIMESTAMP_NTZ,
    METADATA$FILENAME
  FROM @RAW.SGI_CSV_STAGE
)
FILES = ('web_sessions.csv.gz')
FILE_FORMAT = (FORMAT_NAME = 'SGI_DB.RAW.SGI_CSV_FORMAT')
ON_ERROR = 'ABORT_STATEMENT'
FORCE = TRUE;

COPY INTO SUBSCRIPTIONS (
  subscription_id, customer_id, visitor_id, trial_start_ts, paid_start_ts,
  plan_name, monthly_price_usd, signup_campaign_id, signup_device_category,
  signup_landing_page, cancel_ts, cancel_reason, source_updated_at,
  source_file_name
)
FROM (
  SELECT
    $1::VARCHAR, $2::VARCHAR, $3::VARCHAR, $4::TIMESTAMP_NTZ,
    $5::TIMESTAMP_NTZ, $6::VARCHAR, $7::NUMBER(10,2),
    $8::VARCHAR, $9::VARCHAR, $10::VARCHAR,
    $11::TIMESTAMP_NTZ, $12::VARCHAR,
    $13::TIMESTAMP_NTZ, METADATA$FILENAME
  FROM @RAW.SGI_CSV_STAGE
)
FILES = ('subscriptions.csv')
FILE_FORMAT = (FORMAT_NAME = 'SGI_DB.RAW.SGI_CSV_FORMAT')
ON_ERROR = 'ABORT_STATEMENT'
FORCE = TRUE;

COPY INTO BILLING_EVENTS (
  billing_event_id, subscription_id, event_ts, event_type,
  billing_cycle_number, event_status, gross_amount_usd, discount_amount_usd,
  refund_amount_usd, chargeback_amount_usd, net_amount_usd,
  source_updated_at, source_file_name
)
FROM (
  SELECT
    $1::VARCHAR, $2::VARCHAR, $3::TIMESTAMP_NTZ, $4::VARCHAR,
    $5::INTEGER, $6::VARCHAR, $7::NUMBER(10,2),
    $8::NUMBER(10,2), $9::NUMBER(10,2), $10::NUMBER(10,2),
    $11::NUMBER(10,2), $12::TIMESTAMP_NTZ,
    METADATA$FILENAME
  FROM @RAW.SGI_CSV_STAGE
)
FILES = ('billing_events.csv')
FILE_FORMAT = (FORMAT_NAME = 'SGI_DB.RAW.SGI_CSV_FORMAT')
ON_ERROR = 'ABORT_STATEMENT'
FORCE = TRUE;

SELECT 'AD_PERFORMANCE_DAILY' AS table_name, COUNT(*) AS row_count FROM AD_PERFORMANCE_DAILY
UNION ALL
SELECT 'WEB_SESSIONS', COUNT(*) FROM WEB_SESSIONS
UNION ALL
SELECT 'SUBSCRIPTIONS', COUNT(*) FROM SUBSCRIPTIONS
UNION ALL
SELECT 'BILLING_EVENTS', COUNT(*) FROM BILLING_EVENTS
ORDER BY table_name;
