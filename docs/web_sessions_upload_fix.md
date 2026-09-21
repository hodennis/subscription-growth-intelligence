# Web Sessions Upload Fix

The original `web_sessions.csv` is structurally valid, but its 19.3 MB browser
upload repeatedly failed in Snowsight. This package supplies an equivalent gzip
file of approximately 2 MB and a revised RAW-load script.

## Use the fix

1. Run `00_repair_csv_file_format.sql` in a Snowflake worksheet using **Run
   All**. In the final description results, confirm that `PARSE_HEADER` is
   `false` and `SKIP_HEADER` is `1`.
2. Keep the three CSV files that already uploaded to
   `@SGI_DB.RAW.SGI_CSV_STAGE`.
3. Upload `web_sessions.csv.gz` to the root of that same stage. Leave the
   optional path blank.
4. Verify that the stage contains the required source files:

   ```sql
   LIST @SGI_DB.RAW.SGI_CSV_STAGE;
   ```

5. Replace the earlier `01_raw_tables.sql` contents with the revised file in
   this package and run the entire worksheet.
6. Confirm these row counts:

   | Table | Expected rows |
   |---|---:|
   | AD_PERFORMANCE_DAILY | 848 |
   | WEB_SESSIONS | 148,133 |
   | SUBSCRIPTIONS | 17,059 |
   | BILLING_EVENTS | 23,556 |

The existing `SGI_CSV_FORMAT` uses Snowflake's default `COMPRESSION = AUTO`, so
Snowflake automatically detects and decompresses the gzip file during
`COPY INTO`.
