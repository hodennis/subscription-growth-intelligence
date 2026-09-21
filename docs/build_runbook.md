# Build and Reproduction Runbook

This runbook explains how to reproduce the Subscription Growth Intelligence and Attribution QA project from synthetic source generation through Snowflake modeling, quality assurance, and Tableau visualization.

The workflow is deterministic. Using the pinned Python dependencies and random seed `20260811` should produce the same source row counts and anomaly pattern documented in this repository.

## Project workflow

The project is built in the following order:

1. Generate four synthetic source datasets.
2. validate the generated data with source-level QA checks.
3. Create the Snowflake warehouse, database, schemas, file format, and stage.
4. Upload the generated source files to Snowflake.
5. Load the source files into typed `RAW` tables.
6. Standardize and deduplicate the records in `STAGING` views.
7. Build attribution, billing, campaign, cohort, and monitoring models in `MART`.
8. Run the 14-query Snowflake QA suite.
9. Export the reporting marts used by Tableau.
10. Validate the published Attribution and Tracking QA dashboard.

## Prerequisites

The full workflow requires:

* Python 3.11 or later
* A Snowflake account with permission to create a warehouse, database, schemas, file format, stage, tables, and views
* Access to Snowsight or another Snowflake SQL client
* Tableau Public or Tableau Desktop if the dashboard will be rebuilt
* A utility capable of creating a `.gz` file, if the web-session extract will be compressed before upload

Review the following project documentation before changing the source schemas or calculations:

* [Architecture](architecture.md)
* [Data dictionary](data_dictionary.md)
* [Metric definitions](metric_definitions.md)
* [Project limitations](limitations.md)

## 1. Obtain the project files

Download the repository as a ZIP file from GitHub or clone it using Git.

After extracting or cloning the repository, open a terminal in the project root. The project root is the directory containing:

* `README.md`
* `requirements.txt`
* `config/`
* `src/`
* `sql/`
* `docs/`

Full generated datasets are intentionally excluded from version control. Only small reviewable samples are committed under `data/sample/`.

## 2. Create the Python environment

### macOS or Linux

```bash
python3 -m venv .venv
source .venv/bin/activate
python -m pip install --upgrade pip
python -m pip install -r requirements.txt
```

### Windows PowerShell

```powershell
py -m venv .venv
.venv\Scripts\Activate.ps1
python -m pip install --upgrade pip
python -m pip install -r requirements.txt
```

The pinned dependencies are:

* `numpy==2.3.5`
* `pandas==2.2.3`
* `PyYAML==6.0.3`

Using the pinned versions helps preserve deterministic output across runs.

## 3. Review the synthetic scenario configuration

The source-generation settings are defined in:

`config/synthetic_scenarios.yml`

Important configuration values include:

| Setting                 | Configured value |
| ----------------------- | ---------------- |
| Random seed             | `20260811`       |
| Data start date         | January 1, 2026  |
| Data end date           | July 31, 2026    |
| Analysis date           | July 31, 2026    |
| Attribution lookback    | 30 days          |
| Trial length            | 7 days           |
| Realized revenue window | 90 days          |

The configured tracking incident affects:

* Dates: July 8–10, 2026
* Campaign: `PS_GENERIC`
* Device: mobile
* Landing page: `/people-search`

The scenario reduces captured sessions, click-ID retention, and tracked web trial events while leaving backend demand unchanged.

This is a controlled synthetic scenario. It demonstrates the analytical pattern of localized tracking loss without claiming that a particular production tag, script, or platform failed.

## 4. Generate the synthetic source data

From the repository root, run:

```bash
python src/generate_synthetic_data.py
```

The generator creates full source files under:

`data/generated/`

It also refreshes the small public samples under:

`data/sample/`

Expected generated files:

| File                       | Grain                                      |
| -------------------------- | ------------------------------------------ |
| `ad_performance_daily.csv` | One campaign per ad date                   |
| `web_sessions.csv`         | One captured web session                   |
| `subscriptions.csv`        | One subscription                           |
| `billing_events.csv`       | One billing attempt, refund, or chargeback |
| `source_qa_summary.json`   | Generator QA results and anomaly ratios    |

The generator should finish with:

```json
"status": "PASS"
```

The `failed_checks` array should be empty.

### Expected source row counts

Using the pinned dependencies, configuration, and random seed, the expected output is:

| Source               | Expected rows |
| -------------------- | ------------: |
| Ad performance daily |           848 |
| Web sessions         |       148,133 |
| Subscriptions        |        17,059 |
| Billing events       |        23,556 |

Do not continue to Snowflake if the generator reports `FAIL` or if the row counts differ unexpectedly. Review the configuration, dependency versions, and generator output before proceeding.

## 5. Prepare the web-session extract

The Snowflake loader expects the largest source file to be named:

`web_sessions.csv.gz`

On macOS or Linux, create it while retaining the original CSV:

```bash
gzip -c data/generated/web_sessions.csv > data/generated/web_sessions.csv.gz
```

If the file is uploaded without compression, edit the `FILES` value in `sql/snowflake/01_raw_tables.sql` from:

```sql
FILES = ('web_sessions.csv.gz')
```

to:

```sql
FILES = ('web_sessions.csv')
```

Do not upload both versions. Upload either the compressed or uncompressed web-session file and ensure the SQL loader references the same filename.

## 6. Create the Snowflake environment

Open a Snowsight SQL worksheet and run:

`sql/snowflake/00_account_setup.sql`

This script creates:

* Warehouse: `SGI_WH`
* Database: `SGI_DB`
* Schema: `SGI_DB.RAW`
* Schema: `SGI_DB.STAGING`
* Schema: `SGI_DB.MART`
* CSV file format: `SGI_DB.RAW.SGI_CSV_FORMAT`
* Internal stage: `SGI_DB.RAW.SGI_CSV_STAGE`

The warehouse is configured as `X-SMALL` with automatic suspension after 60 seconds of inactivity.

The setup script uses `ACCOUNTADMIN` for a straightforward trial-account deployment. In a production environment, object creation and loading should use a dedicated role with the minimum required privileges.

At the end of the setup script, confirm that Snowflake returns the warehouse and schema definitions without an error.

## 7. Upload the generated source files

In Snowsight:

1. Open **Data**.
2. Open **Databases**.
3. Select `SGI_DB`.
4. Select the `RAW` schema.
5. Open **Stages**.
6. Select `SGI_CSV_STAGE`.
7. Upload the four generated source files to the stage root.

Upload:

* `ad_performance_daily.csv`
* `web_sessions.csv.gz`, or the uncompressed version referenced by the loader
* `subscriptions.csv`
* `billing_events.csv`

Do not upload:

* `source_qa_summary.json`
* Files from `data/sample/`
* Tableau exports
* Credentials or environment files

Verify the stage contents by running:

```sql
USE WAREHOUSE SGI_WH;
USE DATABASE SGI_DB;

LIST @RAW.SGI_CSV_STAGE;
```

Confirm that all four expected filenames appear.

## 8. Load the Snowflake RAW tables

Run:

`sql/snowflake/01_raw_tables.sql`

The script:

1. Creates four typed `RAW` tables.
2. Loads the staged CSV files using positional column transformations.
3. Records the source filename and load timestamp.
4. Returns the row count for each table.

Expected results:

| RAW table                  | Expected rows |
| -------------------------- | ------------: |
| `RAW.AD_PERFORMANCE_DAILY` |           848 |
| `RAW.WEB_SESSIONS`         |       148,133 |
| `RAW.SUBSCRIPTIONS`        |        17,059 |
| `RAW.BILLING_EVENTS`       |        23,556 |

Every count must match the generator output.

### File-format troubleshooting

If the load fails because Snowflake attempts to interpret the CSV header as column metadata, run:

`sql/snowflake/00_repair_csv_file_format.sql`

This repair script resets the file format to:

* `PARSE_HEADER = FALSE`
* `SKIP_HEADER = 1`
* `COMPRESSION = AUTO`

After running the repair script, rerun `01_raw_tables.sql`.

Do not lower validation standards, remove type conversions, or change expected row counts solely to make a failed load appear successful.

## 9. Build and inspect the STAGING views

Run:

`sql/snowflake/02_staging_views.sql`

The staging layer:

* Trims and standardizes text fields.
* Normalizes campaign IDs and categorical values.
* Converts empty strings to null where appropriate.
* Preserves unattributed activity.
* Deduplicates records using source update and load timestamps.
* Maintains the original source grain.

Inspect ten records from each staging view:

```sql
SELECT * FROM STAGING.STG_AD_PERFORMANCE_DAILY LIMIT 10;
SELECT * FROM STAGING.STG_WEB_SESSIONS LIMIT 10;
SELECT * FROM STAGING.STG_SUBSCRIPTIONS LIMIT 10;
SELECT * FROM STAGING.STG_BILLING_EVENTS LIMIT 10;
```

Confirm that:

* Dates and timestamps parsed correctly.
* Boolean values are valid.
* Numeric fields are numeric.
* Empty campaign identifiers remain null.
* Click IDs are null only where expected.
* Failed charges have zero net revenue.
* Refund and chargeback events have nonpositive net values.

## 10. Build the MART layer

Run:

`sql/snowflake/03_mart_views.sql`

The script creates the following models:

| Model                               | Purpose                                                              |
| ----------------------------------- | -------------------------------------------------------------------- |
| `MART.SUBSCRIPTION_ATTRIBUTION`     | Applies the governed campaign-attribution rules                      |
| `MART.SUBSCRIPTION_BILLING_SUMMARY` | Summarizes payment, rebill, refund, and chargeback activity          |
| `MART.SUBSCRIPTION_FACT`            | Provides one governed record per subscription                        |
| `MART.MART_CAMPAIGN_DAILY`          | Reports campaign performance at the daily grain                      |
| `MART.MART_SUBSCRIPTION_COHORT`     | Reports trial, paid, and rebill outcomes by cohort                   |
| `MART.MART_ATTRIBUTION_HEALTH`      | Reconciles campaign-level advertising, session, and backend activity |
| `MART.MART_ATTRIBUTION_SEGMENT`     | Diagnoses tracking performance by campaign, device, and landing page |

The mart logic aggregates each fact table to the required reporting grain before combining metrics. This prevents many-to-many joins from multiplying spend, sessions, subscriptions, or revenue.

### Inspect attributed and unattributed subscriptions

Run:

```sql
SELECT *
FROM MART.SUBSCRIPTION_FACT
WHERE attributed_campaign_id <> 'UNATTRIBUTED'
LIMIT 5;
```

Then run:

```sql
SELECT *
FROM MART.SUBSCRIPTION_FACT
WHERE attributed_campaign_id = 'UNATTRIBUTED'
LIMIT 5;
```

Confirm that unattributed subscriptions are preserved rather than reassigned to a paid campaign.

## 11. Run the Snowflake QA suite

Run:

`sql/snowflake/04_qa_tests.sql`

The first result set should contain 14 QA tests.

Expected result:

* All 14 rows have `status = 'PASS'`.
* All 14 rows have `failure_count = 0`.

The QA suite checks:

1. Ad-source key uniqueness
2. Session key uniqueness
3. Subscription key uniqueness
4. Billing-event key uniqueness
5. Advertising business rules
6. Billing foreign-key integrity
7. Failed-charge net revenue
8. Paid-start and first-payment reconciliation
9. Campaign-mart spend reconciliation
10. Campaign-mart session reconciliation
11. Subscription-fact revenue reconciliation
12. Preservation of unattributed trials
13. Detection of the campaign-level anomaly
14. Detection of the affected campaign-device-page segment

Investigate every failed test before using the marts for reporting. Do not modify an expected total or alert threshold merely to convert a legitimate failure into a pass.

## 12. Validate the anomaly findings

The final two queries in `04_qa_tests.sql` return the campaign-level and segment-level evidence for July 1–17, 2026.

For the comparison period of July 1–7 and incident period of July 8–10, the expected findings include:

| Metric                                        | July 1–7 | July 8–10 |
| --------------------------------------------- | -------: | --------: |
| Campaign ad clicks per day                    |    268.3 |     301.7 |
| Campaign captured sessions per day            |    214.6 |     144.0 |
| Campaign sessions per click                   |    80.0% |     47.7% |
| Affected-segment captured sessions per day    |    149.3 |      63.0 |
| Affected-segment click-ID coverage            |    91.9% |     18.9% |
| Affected-segment tracked trial events per day |     15.0 |       1.0 |
| Affected-segment backend trial starts per day |     16.9 |      17.7 |
| Successful first payments per day             |      6.4 |       7.7 |

The diagnostic pattern should show:

* Advertising-platform clicks remained healthy.
* Captured sessions declined.
* Click-ID coverage collapsed in the affected segment.
* Web-tracked trial events collapsed.
* Backend trial starts remained stable.
* Successful first payments did not show a corresponding collapse.
* Desktop and other paid segments remained broadly stable.

These results support the conclusion that the observed conversion decline is consistent with localized tracking or attribution loss rather than a demonstrated collapse in customer demand.

They do not prove whether the technical cause was a tag, page release, consent behavior, redirect, script, or browser condition.

The full interpretation and recommended response are documented in:

[Attribution Anomaly Investigation](anomaly_investigation.md)

## 13. Export the reporting marts

The completed Tableau QA dashboard uses:

* `MART.MART_ATTRIBUTION_HEALTH`
* `MART.MART_ATTRIBUTION_SEGMENT`

Run the following queries in Snowsight:

```sql
SELECT *
FROM MART.MART_ATTRIBUTION_HEALTH
ORDER BY report_date, campaign_id;
```

```sql
SELECT *
FROM MART.MART_ATTRIBUTION_SEGMENT
ORDER BY report_date, campaign_id, device_category, landing_page;
```

Use Snowsight’s result-download option to save the files as:

* `data/tableau_exports/mart_attribution_health.csv`
* `data/tableau_exports/mart_attribution_segment.csv`

The following marts may also be exported for additional campaign or cohort analysis:

```sql
SELECT *
FROM MART.MART_CAMPAIGN_DAILY
ORDER BY report_date, campaign_id;
```

```sql
SELECT *
FROM MART.MART_SUBSCRIPTION_COHORT
ORDER BY trial_cohort_month, attributed_campaign_id;
```

Save them as:

* `data/tableau_exports/mart_campaign_daily.csv`
* `data/tableau_exports/mart_subscription_cohort.csv`

The `data/tableau_exports/` directory is excluded from version control because these files can be regenerated from the Snowflake models.

## 14. Rebuild or validate the Tableau dashboard

The published dashboard is available at:

[Subscription Growth Intelligence — Attribution and Tracking QA](https://public.tableau.com/app/profile/dennis.ho2795/viz/subscription-growth-intelligence/02AttributionQA)

The dashboard contains three diagnostic views:

1. Campaign-level ad clicks versus captured sessions
2. Segment-level click-ID coverage
3. Segment-level tracked trial events versus backend trial starts

The dashboard should include:

* A date-range control
* A campaign filter
* A device filter that applies only to the segment-level charts
* A highlighted incident period for July 8–10
* An annotation summarizing the tracking evidence
* Clear legends and axis labels
* Language that distinguishes observed evidence from inferred root cause

The campaign-level chart should remain at the campaign grain. Applying a device filter to that chart would incorrectly mix a segment-level filter with campaign-level advertising data.

When connecting the exported CSVs in Tableau:

* Use `mart_attribution_health.csv` for campaign-level diagnostics.
* Use `mart_attribution_segment.csv` for device and landing-page diagnostics.
* Relate the sources only where needed.
* Do not create a row-level join that duplicates campaign metrics across devices or landing pages.

## 15. Final validation checklist

The reproduction is complete when all of the following are true:

* [ ] The Python generator reports `PASS`.
* [ ] `source_qa_summary.json` contains no failed checks.
* [ ] The four source row counts match the documented totals.
* [ ] The four staged files appear in `SGI_CSV_STAGE`.
* [ ] The four `RAW` table counts match the generated source counts.
* [ ] All four `STAGING` views return correctly typed records.
* [ ] The seven `MART` views build successfully.
* [ ] All 14 Snowflake QA tests return `PASS`.
* [ ] Spend reconciles between its source and campaign mart.
* [ ] Net revenue reconciles between billing events and the subscription fact.
* [ ] Unattributed subscriptions remain visible.
* [ ] The July 8–10 campaign and segment warnings are triggered.
* [ ] Tableau shows the expected tracking divergence.
* [ ] The written conclusion says the evidence is “consistent with” tracking loss rather than claiming a proven root cause.
* [ ] No credentials, account identifiers, or nonsynthetic data have been added to the repository.

## 16. Security and repository hygiene

Do not commit:

* `.env`
* Snowflake passwords or account identifiers
* Private keys or authentication tokens
* Full files under `data/generated/`
* Tableau exports under `data/tableau_exports/`
* Tableau `.hyper` extracts
* Non-synthetic customer, campaign, subscription, or billing data

The repository should contain only:

* The deterministic generator
* Scenario configuration
* Small sample datasets
* Snowflake SQL
* Documentation
* Dashboard imagery
* An optional public-safe Tableau workbook

## 17. End the Snowflake session

The warehouse automatically suspends after 60 seconds of inactivity. It can also be suspended manually:

```sql
ALTER WAREHOUSE SGI_WH SUSPEND;
```

This prevents unnecessary credit consumption after the build and validation workflow is complete.
