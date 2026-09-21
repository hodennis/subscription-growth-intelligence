# Attribution Anomaly Investigation

**Status:** Completed — the synthetic incident scenario was generated, loaded into Snowflake, evaluated through the QA suite, and reviewed in Tableau.

## Decision question

Should the team reduce spend on the affected paid-search campaign after a sharp drop in tracked conversions?

**Decision:** No. The decline in tracked conversions should not, by itself, trigger a campaign pause or material budget reduction because backend trial starts and successful first payments did not show a corresponding decline.

## Incident scope

* **Incident dates:** July 8–10, 2026
* **Comparison period:** July 1–7, 2026
* **Campaign:** `PS_GENERIC`
* **Device:** mobile
* **Landing page:** `/people-search`

The comparison table uses the immediately preceding seven days for readability and alignment with the Tableau investigation view. The automated Snowflake monitoring logic also evaluates rolling prior-period baselines.

## Investigation findings

| Check                                                            | Comparison-period result | Incident-period result | Interpretation                                                                                     |
| ---------------------------------------------------------------- | -----------------------: | ---------------------: | -------------------------------------------------------------------------------------------------- |
| Campaign ad clicks per day                                       |                    268.3 |                  301.7 | Ad demand remained healthy; clicks increased approximately 12%.                                    |
| Campaign captured sessions per day                               |                    214.6 |                  144.0 | Captured sessions declined even though ad clicks increased.                                        |
| Campaign sessions per click                                      |                    80.0% |                  47.7% | The relationship between platform-reported clicks and captured sessions deteriorated sharply.      |
| Affected-segment captured sessions per day                       |                    149.3 |                   63.0 | Captured sessions in the mobile `/people-search` segment fell approximately 58%.                   |
| Affected-segment click-ID coverage                               |                    91.9% |                  18.9% | Click-ID coverage fell 73 percentage points, indicating substantial attribution loss.              |
| Affected-segment tracked trial events per day                    |                     15.0 |                    1.0 | Web-tracked trial events fell approximately 93%.                                                   |
| Affected-segment backend trial starts per day                    |                     16.9 |                   17.7 | Backend trial creation remained stable and slightly increased.                                     |
| Successful first payments per day                                |                      6.4 |                    7.7 | Successful first payments did not show a corresponding decline.                                    |
| Desktop click-ID coverage for the same campaign and landing page |                    91.1% |                  89.3% | Desktop tracking remained broadly stable.                                                          |
| Click-ID coverage across other paid segments                     |                    93.3% |                  92.7% | Other paid segments did not exhibit the same concentrated collapse.                                |
| Data freshness and load completion                               |                 Complete |               Complete | All required source data was available for the investigation.                                      |
| Automated data-quality checks                                    |                        — |        14 of 14 passed | Primary keys, relationships, billing integrity, and expected anomaly conditions passed validation. |

Successful first payments are evaluated on a trial-cohort basis so that payment outcomes remain aligned with the backend trials originating during each comparison period.

## Conclusion

The evidence is consistent with a localized tracking or attribution failure affecting the `PS_GENERIC` mobile `/people-search` experience between July 8 and July 10.

The combination of stable ad clicks, stable backend trial starts, stable successful first payments, and sharply lower captured sessions, click-ID coverage, and web-tracked trial events indicates that the measured conversion decline was primarily a measurement artifact rather than a verified decline in customer demand or campaign performance.

This analysis does not establish the exact technical root cause. The available data cannot independently determine whether the loss originated from a tag, script, consent-management behavior, page release, redirect, browser condition, or another instrumentation issue.

## Recommendation

Do not pause or materially reduce the campaign solely because the tracked web conversion rate fell during the incident window.

Recommended actions are:

1. Escalate the mobile `/people-search` instrumentation for technical review.
2. Review tag firing, click-ID persistence, redirects, consent behavior, and releases deployed near July 8.
3. Temporarily evaluate campaign performance using backend trial starts and successful first payments alongside advertising-platform clicks.
4. Flag affected attribution reporting for July 8–10 so stakeholders do not interpret the observed decline as a confirmed demand change.
5. Backfill attribution only when a reliable click ID, visitor ID, or other deterministic key can be recovered.
6. Continue monitoring the segment after remediation to confirm that captured sessions, click-ID coverage, and tracked trial events return to their normal relationship with backend outcomes.

## Limitations

This is a controlled synthetic case study designed to demonstrate attribution monitoring and investigation methods. The scenario reproduces the analytical pattern of a localized measurement failure, but it does not identify or prove the failure of a particular production technology.

The findings should therefore be interpreted as evidence supporting a tracking-loss hypothesis, not as proof of a specific implementation defect.
