# Governed Metric Definitions

Analysis date: **2026-07-31**  
Attribution model: **last non-direct campaign touch within 30 days before trial**  
Trial period: **7 days**  
Observed-value window: **90 days after paid start**

The definitions below are contracts. A dashboard calculation should not change
one without updating this document and its QA test.

| Metric | Reporting grain | Numerator | Denominator / eligibility | Important caveat |
|---|---|---|---|---|
| Impressions | Campaign-day | Sum of ad-platform impressions | Not applicable | Platform-reported. |
| Clicks | Campaign-day | Sum of ad-platform clicks | Not applicable | May not reconcile one-to-one with captured sessions. |
| CTR | Campaign-day or rollup | Clicks | Impressions | Use `NULLIF(impressions, 0)`. |
| Spend | Campaign-day | Sum of `spend_usd` | Not applicable | Aggregate before joining to session facts. |
| CPC | Campaign-day or rollup | Spend | Clicks | Null when clicks are zero. |
| Captured sessions | Campaign-day | Distinct `session_id` | Not applicable | Collection loss is possible; this is not ad clicks. |
| Click-ID coverage | Campaign/date/device/page | Paid sessions with nonnull `click_id` | All captured paid sessions | A fall can indicate tagging or collection loss but is not root-cause proof. |
| Backend trial starts | Trial cohort/backend signup segment | Distinct `subscription_id` created in backend | Not applicable | Backend subscriptions are the trial source of truth; backend signup campaign is diagnostic and remains distinct from governed attribution. |
| Tracked trial events | Session cohort/campaign | Sessions with `tracked_trial_event = TRUE` | Not applicable | Used for reconciliation, not as the canonical trial count. |
| Eligible trials | Trial cohort/campaign | Trials with `trial_start_ts <= analysis_date - 7 days` | Not applicable | Excludes immature trials from conversion denominators. |
| Trial-to-paid conversion | Trial cohort/campaign | Eligible trials with a successful first payment / paid start | Eligible trials | Attribute at trial start; never compare paid starts to all recent trials. |
| First-time paid subscribers | Trial cohort/campaign | Distinct subscriptions with successful cycle 1 charge | Not applicable | Do not count retry attempts more than once. |
| Trial CPA | Campaign/spend period | Spend | Attributed backend trial starts | Keep unattributed trials visible. |
| Paid CAC | Campaign/spend period | Spend | Attributed first-time paid subscribers | Period alignment must be explicit. |
| First rebill rate | Paid-start cohort/campaign | Subscriptions with successful cycle 2 charge | Subscriptions old enough to reach cycle 2 | Failed attempts do not count as success; recovered retries may. |
| Second rebill rate | Paid-start cohort/campaign | Subscriptions with successful cycle 3 charge | Subscriptions old enough to reach cycle 3 | Use subscription-level success flags to prevent retry duplication. |
| Realized 90-day net revenue | Paid-start cohort/campaign | Successful charges less discounts, refunds, and chargebacks within 90 days of paid start | Only 90-day mature subscriptions when used comparatively | This is observed value, not projected lifetime value. |
| Realized 90-day ROAS | Campaign/cohort | Realized 90-day net revenue from attributed 90-day mature subscriptions | Associated campaign spend | Clearly label cohort and maturity; do not mix mature revenue with immature spend. |
| Session-to-click variance | Campaign-day | Captured sessions minus ad clicks | Ad clicks | Negative is common; alert only when beyond the documented tolerance/baseline. |
| Trial reconciliation variance | Campaign-day/segment | Tracked web trial events minus backend trial starts | Backend trial starts | Large negative variance with stable backend activity suggests measurement loss. |

## Safe SQL patterns

### Rates

```sql
numerator / NULLIF(denominator, 0)
```

Calculate aggregate rates from aggregate numerators and denominators. Do not
average daily percentages when campaign volume differs by day.

### Attribution

For each subscription, rank eligible sessions where:

- the session belongs to the same `visitor_id`;
- `session_ts <= trial_start_ts`;
- `session_ts >= DATEADD(day, -30, trial_start_ts)`; and
- `campaign_id IS NOT NULL`.

Select the most recent eligible session with `ROW_NUMBER() = 1`. Preserve
subscriptions without an eligible session as `UNATTRIBUTED`.

### Billing

Reduce billing attempts to one subscription-level set of flags and amounts
before joining to a campaign or cohort table. For example:

- `first_payment_success_flag = MAX(cycle 1 succeeded)`
- `first_rebill_success_flag = MAX(cycle 2 succeeded)`
- `net_revenue_90d = SUM(net amount within 90 days of paid start)`

This prevents retries from multiplying subscribers and prevents sessions from
multiplying financial events.

## Metric ownership used in the case study

| Domain | Proposed owner | Validation partner |
|---|---|---|
| Spend, impressions, clicks | Performance Marketing | Analytics |
| Captured sessions and web events | Digital/Product Analytics | Engineering |
| Trials and paid starts | Subscription Operations | Analytics |
| Charges, refunds, chargebacks | Finance/Billing Operations | Analytics |
| Governed marts and dashboard calculations | Analytics | Relevant domain owner |
