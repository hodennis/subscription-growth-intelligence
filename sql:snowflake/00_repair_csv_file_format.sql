-- One-time repair for accounts where SGI_CSV_FORMAT was created with
-- PARSE_HEADER = TRUE. Positional COPY transformations require the header to
-- be skipped rather than parsed.

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE SGI_WH;
USE DATABASE SGI_DB;

ALTER FILE FORMAT RAW.SGI_CSV_FORMAT SET
  PARSE_HEADER = FALSE
  SKIP_HEADER = 1
  COMPRESSION = AUTO;

DESCRIBE FILE FORMAT RAW.SGI_CSV_FORMAT;
