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

On macOS or Linux, create it
