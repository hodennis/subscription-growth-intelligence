# Data Dictionary

All tables contain synthetic data. Currency is in US dollars. Source timestamps
are generated in America/Chicago and stored in Snowflake as `TIMESTAMP_NTZ` for
this bounded case study. A production system should document and enforce a UTC
strategy instead.

## Relationship summary

| Parent | Child | Join | Cardinality and caveat |
|---|---|---|---|
| `ad_performance_daily` | `web_sessions` | `campaign_id` plus calendar date for reconciliation | One campaign-day to many sessions; aggregate sessions before joining to spend. |
| `web_sessions` | `subscriptions` | `visitor_id`; apply a 30-day last-non-direct lookback | One visitor can have many sessions and, rarely, more than one subscription. Do not join without ranking eligible touches. |
| `subscriptions` | `billing_events` | `subscription_id` | One subscription to many attempted charges, refunds, or chargebacks. Aggregate billing before joining to subscriptions. |

## `ad_performance_daily`

Grain: one record per `ad_date` and `campaign_id`.

| Field | Snowflake type | Nullable | Rule / meaning |
|---|---|---:|---|
| `ad_date` | `DATE` | No | Ad-platform reporting date. Part of the primary key. |
| `campaign_id` | `VARCHAR(40)` | No | Stable synthetic campaign identifier. Part of the primary key. |
| `campaign_name` | `VARCHAR(100)` | No | Human-readable campaign name. |
| `channel` | `VARCHAR(40)` | No | Governed channel grouping, such as `Paid Search`. |
| `platform` | `VARCHAR(40)` | No | Advertising platform. |
| `impressions` | `INTEGER` | No | Nonnegative served impressions. |
| `clicks` | `INTEGER` | No | Nonnegative clicks; cannot exceed impressions. |
| `spend_usd` | `NUMBER(12,2)` | No | Nonnegative platform-reported spend. |
| `source_updated_at` | `TIMESTAMP_NTZ` | No | Synthetic source refresh timestamp. |

Expected constraints:

- Unique: (`ad_date`, `campaign_id`)
- `0 <= clicks <= impressions`
- `spend_usd >= 0`
- Campaign attributes are stable for a given `campaign_id`

## `web_sessions`

Grain: one record per captured web session. The anomaly intentionally causes
some sessions to be absent, simulating collection loss rather than zero demand.

| Field | Snowflake type | Nullable | Rule / meaning |
|---|---|---:|---|
| `session_id` | `VARCHAR(50)` | No | Unique captured-session identifier. |
| `visitor_id` | `VARCHAR(50)` | No | Synthetic browser/person key used to connect sessions to trials. |
| `session_ts` | `TIMESTAMP_NTZ` | No | Captured session start. |
| `campaign_id` | `VARCHAR(40)` | Yes | Paid campaign associated with the touch; null for direct or unattributed traffic. |
| `utm_source` | `VARCHAR(80)` | Yes | Normalized source supplied on the landing URL. |
| `utm_medium` | `VARCHAR(80)` | Yes | Normalized medium supplied on the landing URL. |
| `utm_campaign` | `VARCHAR(120)` | Yes | Campaign token supplied on the landing URL. |
| `click_id` | `VARCHAR(100)` | Yes | Synthetic ad click identifier; coverage is a tracked health metric. |
| `landing_page` | `VARCHAR(200)` | No | Path of the session entry page. |
| `device_category` | `VARCHAR(20)` | No | `desktop`, `mobile`, or `tablet`. |
| `tracked_trial_event` | `BOOLEAN` | No | Whether the web instrumentation captured a trial-start event in this session. Not the backend source of truth for trials. |
| `source_updated_at` | `TIMESTAMP_NTZ` | No | Synthetic source refresh timestamp. |

Expected constraints:

- Unique: `session_id`
- `device_category` is in the governed domain
- A null `campaign_id` is allowed and must remain visible as unattributed/direct
- `tracked_trial_event` may disagree with backend trial creation by design

## `subscriptions`

Grain: one record per subscription. A visitor may have more than one
subscription only if a prior subscription was canceled; `subscription_id`, not
`customer_id`, is the billing join key.

| Field | Snowflake type | Nullable | Rule / meaning |
|---|---|---:|---|
| `subscription_id` | `VARCHAR(50)` | No | Unique subscription identifier. |
| `customer_id` | `VARCHAR(50)` | No | Synthetic customer identifier. |
| `visitor_id` | `VARCHAR(50)` | No | Connects the backend trial to eligible web touches. |
| `trial_start_ts` | `TIMESTAMP_NTZ` | No | Backend source-of-truth trial creation time. |
| `paid_start_ts` | `TIMESTAMP_NTZ` | Yes | First successful paid-service start; null if the trial never converted by the analysis date. |
| `plan_name` | `VARCHAR(60)` | No | Plan selected at trial start. |
| `monthly_price_usd` | `NUMBER(10,2)` | No | Contracted monthly list price at trial start. |
| `signup_campaign_id` | `VARCHAR(40)` | Yes | Campaign token captured independently by the backend signup request; used for reconciliation, not silently substituted for governed last-touch attribution. |
| `signup_device_category` | `VARCHAR(20)` | No | Device category preserved by the backend trial event. |
| `signup_landing_page` | `VARCHAR(200)` | No | Landing page preserved by the backend trial event. |
| `cancel_ts` | `TIMESTAMP_NTZ` | Yes | Cancellation timestamp when present. |
| `cancel_reason` | `VARCHAR(120)` | Yes | Synthetic cancellation category; required when `cancel_ts` is populated. |
| `source_updated_at` | `TIMESTAMP_NTZ` | No | Synthetic source refresh timestamp. |

Expected constraints:

- Unique: `subscription_id`
- `monthly_price_usd > 0`
- `signup_device_category` is in the governed device domain
- `paid_start_ts >= trial_start_ts` when populated
- `cancel_ts >= trial_start_ts` when populated
- Trial maturity is determined relative to the documented analysis date, not
  by whether `paid_start_ts` happens to be null

## `billing_events`

Grain: one attempted financial event. Failed attempts remain in the table so
payment failure and recovery can be analyzed without inflating realized revenue.

| Field | Snowflake type | Nullable | Rule / meaning |
|---|---|---:|---|
| `billing_event_id` | `VARCHAR(60)` | No | Unique financial-event identifier. |
| `subscription_id` | `VARCHAR(50)` | No | Foreign key to `subscriptions`. |
| `event_ts` | `TIMESTAMP_NTZ` | No | Attempt, refund, or chargeback timestamp. |
| `event_type` | `VARCHAR(20)` | No | `charge`, `refund`, or `chargeback`. |
| `billing_cycle_number` | `INTEGER` | Yes | `1` for first payment, `2` for first rebill, and so on; null for refund/chargeback rows. |
| `event_status` | `VARCHAR(20)` | No | `succeeded` or `failed`; refund/chargeback rows are succeeded when processed. |
| `gross_amount_usd` | `NUMBER(10,2)` | No | Positive list charge for charge attempts; otherwise zero. |
| `discount_amount_usd` | `NUMBER(10,2)` | No | Nonnegative discount applied to a charge. |
| `refund_amount_usd` | `NUMBER(10,2)` | No | Positive amount returned on a refund event; otherwise zero. |
| `chargeback_amount_usd` | `NUMBER(10,2)` | No | Positive disputed amount on a chargeback event; otherwise zero. |
| `net_amount_usd` | `NUMBER(10,2)` | No | Successful gross less discount, refund, and chargeback amounts; failed charges contribute zero. |
| `source_updated_at` | `TIMESTAMP_NTZ` | No | Synthetic source refresh timestamp. |

Expected constraints:

- Unique: `billing_event_id`
- Every `subscription_id` exists in `subscriptions`
- Charge rows have a positive `billing_cycle_number`; refund and chargeback rows have null cycles
- Failed charges have `net_amount_usd = 0`
- Refund and chargeback rows have nonpositive `net_amount_usd`
- `discount_amount_usd <= gross_amount_usd` for charge rows

## Derived attribution fields

The staging/modeling layer should add these fields rather than storing them in
the source extracts:

| Field | Rule |
|---|---|
| `attributed_session_id` | Most recent eligible non-direct session at or before trial start and within 30 days. |
| `attributed_campaign_id` | Campaign from the attributed session; otherwise `UNATTRIBUTED`. |
| `attribution_lag_days` | Days between the attributed session and backend trial start. |
| `trial_mature_flag` | Trial start is at least seven days before the analysis timestamp. |
| `rebill_1_eligible_flag` | Paid start is at least one billing interval before the analysis timestamp. |
| `revenue_90d_mature_flag` | Paid start is at least 90 days before the analysis timestamp. |

`signup_campaign_id` and `attributed_campaign_id` answer different questions.
The former is an independently captured backend diagnostic field. The latter is
the governed reporting attribution selected from eligible web touches. The
attribution-health mart may compare them, but must never overwrite one with the
other without an explicit, documented fallback rule.
