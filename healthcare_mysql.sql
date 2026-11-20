-- =====================================================================
-- Project  : Healthcare Admissions Analysis
-- Dialect  : MySQL 8.0+
-- Source   : healthcaredataset.csv  (15 columns, 55,500 rows)
-- Purpose  : Profile the raw data, clean it, build a star schema,
--            run quality checks, and produce analysis queries that
--            match the Power BI dashboard visuals.
-- Sections :
--   0  Database and raw table setup
--   1  Data profiling
--   2  Data quality checks (on raw data)
--   3  Cleaning into a staging table
--   4  Transformation into fact and dimension tables
--   5  Quality checks on the cleaned data
--   6  Reconciliation numbers (should match Power BI cards)
--   7  Analysis queries (mirror the dashboard visuals)
-- =====================================================================

-- =====================================================================
-- SECTION 0 : DATABASE AND RAW TABLE SETUP
-- We create the database once and point MySQL to it.
-- raw_admissions is the landing table for the CSV.
-- We never UPDATE or DELETE from this table so we always have the
-- original data to go back to if something goes wrong.
-- =====================================================================

CREATE DATABASE IF NOT EXISTS healthcare;
USE healthcare;

-- Drop and recreate so the script is safe to re-run from scratch.
-- Column types match the CSV: TEXT for all string fields, INT for
-- whole numbers, DECIMAL(14,6) for billing (preserves the raw
-- precision before we round it in the staging step), DATE for dates.
DROP TABLE IF EXISTS raw_admissions;
CREATE TABLE Raw_admissions (
    name               TEXT,
    age                INT,
    gender             TEXT,
    blood_type         TEXT,
    medical_condition  TEXT,
    date_of_admission  DATE,
    doctor             TEXT,
    hospital           TEXT,
    insurance_provider TEXT,
    billing_amount     DECIMAL(14,6),
    room_number        INT,
    admission_type     TEXT,
    discharge_date     DATE,
    medication         TEXT,
    test_results       TEXT
);

-- HOW TO LOAD THE CSV
-- Adjust the file path to wherever you saved healthcaredataset.csv.
-- The date columns are loaded into variables first (@adm, @dis) and
-- then converted with STR_TO_DATE because MySQL needs an explicit
-- format string to parse dates reliably.
-- The CSV stores dates as YYYY-MM-DD (e.g. 2024-01-31) so the
-- format string is '%Y-%m-%d'.  If your CSV used MM/DD/YYYY instead
-- you would change it to '%m/%d/%Y'.

SHOW VARIABLES LIKE 'secure_file_priv';

LOAD DATA INFILE 'C:/ProgramData/MySQL/MySQL Server 8.0/Uploads/healthcare_dataset.csv'
INTO TABLE raw_admissions
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 ROWS
(name, age, gender, blood_type, medical_condition,
 @adm, doctor, hospital, insurance_provider, billing_amount,
 room_number, admission_type, @dis, medication, test_results)
SET date_of_admission = STR_TO_DATE(@adm, '%Y-%m-%d'),
    discharge_date    = STR_TO_DATE(@dis, '%Y-%m-%d');



-- =====================================================================
-- SECTION 1 : DATA PROFILING
-- Goal: understand the shape and content of the raw data before
-- touching it.  Run these queries first and note the results.
-- =====================================================================

-- 1.1  BASIC ROW COUNT AND DATE RANGE
-- Tells us how many rows loaded and what time window the data covers.
-- Expected: ~55,500 rows, admissions from May 2019 to May 2024.
SELECT COUNT(*)               AS total_rows,
       MIN(date_of_admission) AS first_admission,
       MAX(date_of_admission) AS last_admission
FROM raw_admissions;

-- 1.2  MISSING VALUES PER COLUMN
-- COUNT(column) skips NULLs, so COUNT(*) - COUNT(col) gives the
-- number of NULLs in each column.
-- Expected: all zeros for this dataset (no missing values).
SELECT
    COUNT(*) - COUNT(name)               AS missing_name,
    COUNT(*) - COUNT(age)                AS missing_age,
    COUNT(*) - COUNT(gender)             AS missing_gender,
    COUNT(*) - COUNT(blood_type)         AS missing_blood_type,
    COUNT(*) - COUNT(medical_condition)  AS missing_condition,
    COUNT(*) - COUNT(date_of_admission)  AS missing_admission_date,
    COUNT(*) - COUNT(doctor)             AS missing_doctor,
    COUNT(*) - COUNT(hospital)           AS missing_hospital,
    COUNT(*) - COUNT(insurance_provider) AS missing_insurance,
    COUNT(*) - COUNT(billing_amount)     AS missing_billing,
    COUNT(*) - COUNT(room_number)        AS missing_room,
    COUNT(*) - COUNT(admission_type)     AS missing_admission_type,
    COUNT(*) - COUNT(discharge_date)     AS missing_discharge_date,
    COUNT(*) - COUNT(medication)         AS missing_medication,
    COUNT(*) - COUNT(test_results)       AS missing_test_results
FROM raw_admissions;

-- 1.3  DISTINCT VALUE COUNTS PER COLUMN
-- Low count = a true category (e.g. gender = 2, admission_type = 3).
-- High count = near-unique text (e.g. name, doctor, hospital).
-- This tells us which columns are safe to use as dimension keys and
-- which are too granular to slice by in a dashboard.
SELECT
    COUNT(DISTINCT name)               AS distinct_names,
    COUNT(DISTINCT gender)             AS distinct_gender,
    COUNT(DISTINCT blood_type)         AS distinct_blood_type,
    COUNT(DISTINCT medical_condition)  AS distinct_conditions,
    COUNT(DISTINCT doctor)             AS distinct_doctors,
    COUNT(DISTINCT hospital)           AS distinct_hospitals,
    COUNT(DISTINCT insurance_provider) AS distinct_insurers,
    COUNT(DISTINCT admission_type)     AS distinct_admission_types,
    COUNT(DISTINCT medication)         AS distinct_medications,
    COUNT(DISTINCT test_results)       AS distinct_test_results
FROM raw_admissions;

-- 1.4  NUMERIC COLUMN SUMMARY
-- Min / avg / max for age, billing_amount, and room_number.
-- Flags obvious problems: negative ages, billing of zero, rooms
-- outside a plausible range.
SELECT
    MIN(age)                      AS min_age,
    ROUND(AVG(age), 1)            AS avg_age,
    MAX(age)                      AS max_age,
    MIN(billing_amount)           AS min_billing,
    ROUND(AVG(billing_amount), 2) AS avg_billing,
    MAX(billing_amount)           AS max_billing,
    MIN(room_number)              AS min_room,
    MAX(room_number)              AS max_room
FROM raw_admissions;

-- 1.5  CATEGORY DISTRIBUTION FOR ADMISSION TYPE
-- Shows how evenly the three admission types (Emergency, Elective,
-- Urgent) are split.  Repeat this pattern for gender, medical_condition,
-- insurance_provider, medication, and test_results as needed.
-- The window function SUM(COUNT(*)) OVER () gives the grand total so
-- we can calculate a percentage without a subquery.
SELECT admission_type,
       COUNT(*) AS rows_n,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS pct
FROM raw_admissions
GROUP BY admission_type
ORDER BY rows_n DESC;


-- =====================================================================
-- SECTION 2 : DATA QUALITY CHECKS  (run on raw_admissions)
-- Goal: find and count every problem before we clean anything.
-- Document the results so you can explain every decision you made.
-- =====================================================================

-- 2.1  EXACT DUPLICATE ROWS
-- ROW_NUMBER() partitioned by all 15 columns assigns rn = 1 to the
-- first occurrence and rn > 1 to every copy.
-- We count the copies (rn > 1) to know how many rows will be removed
-- by SELECT DISTINCT in the staging step.
-- Expected: 534 duplicates (55,500 raw rows -> 54,966 after removal).
SELECT COUNT(*) AS duplicate_rows_to_remove
FROM (
    SELECT ROW_NUMBER() OVER (
               PARTITION BY name, age, gender, blood_type, medical_condition,
                            date_of_admission, doctor, hospital, insurance_provider,
                            billing_amount, room_number, admission_type,
                            discharge_date, medication, test_results
               ORDER BY name) AS rn
    FROM raw_admissions
) d
WHERE rn > 1;

-- 2.2  NEGATIVE BILLING AMOUNTS
-- Negative values could be refunds, adjustments, or data entry errors.
-- The source file does not explain them, so we keep them and flag them
-- rather than deleting or sign-flipping them.
-- Expected: ~106 rows after de-duplication, totalling about -$53k.
SELECT COUNT(*)                       AS negative_rows,
       ROUND(SUM(billing_amount), 2)  AS negative_total,
       MIN(billing_amount)            AS most_negative
FROM raw_admissions
WHERE billing_amount < 0;

-- 2.3  DISCHARGE DATE BEFORE ADMISSION DATE
-- A discharge date earlier than the admission date is a logic error.
-- Any rows found here need investigation before they go into the model.
-- Expected: 0 rows.
SELECT COUNT(*) AS discharge_before_admission
FROM raw_admissions
WHERE discharge_date < date_of_admission;

-- 2.4  TEXT FORMAT ISSUES
-- Checks four specific problems found during initial exploration:
--   hospital_trailing_comma  : hospital name ends with a comma
--   hospital_leading_and     : hospital name starts with "and "
--   name_extra_spaces        : patient name has leading or trailing spaces
--   name_has_title_or_suffix : name contains Mr./Dr./MD/PhD etc.
-- The REGEXP operator in MySQL is case-insensitive by default for
-- standard character sets, so no flag is needed here.
SELECT
    SUM(CASE WHEN hospital LIKE '%,'           THEN 1 ELSE 0 END) AS hospital_trailing_comma,
    SUM(CASE WHEN LOWER(hospital) LIKE 'and %' THEN 1 ELSE 0 END) AS hospital_leading_and,
    SUM(CASE WHEN name <> TRIM(name)           THEN 1 ELSE 0 END) AS name_extra_spaces,
    SUM(CASE WHEN name REGEXP '^(Mr|Mrs|Ms|Miss|Dr)\\.?\\s'
              OR name REGEXP '\\s(MD|DDS|DVM|PhD)$'
             THEN 1 ELSE 0 END)                                    AS name_has_title_or_suffix
FROM raw_admissions;

-- 2.5  BILLING OUTLIERS  (IQR method)
-- We approximate Q1 and Q3 using NTILE(4) because MySQL 8 does not
-- have PERCENTILE_CONT.  NTILE splits rows into four equal buckets;
-- the top of bucket 1 is Q1 and the top of bucket 3 is Q3.
-- A value is an outlier if it falls more than 1.5 * IQR below Q1
-- or above Q3.  We report the count only; we do not remove outliers
-- because extreme billing amounts may be legitimate.
WITH ordered AS (
    SELECT billing_amount,
           NTILE(4) OVER (ORDER BY billing_amount) AS quartile
    FROM raw_admissions
),
bounds AS (
    -- MAX of each bucket gives the upper boundary of that quartile
    SELECT MAX(CASE WHEN quartile = 1 THEN billing_amount END) AS q1,
           MAX(CASE WHEN quartile = 3 THEN billing_amount END) AS q3
    FROM ordered
)
SELECT COUNT(*) AS billing_iqr_outliers
FROM raw_admissions, bounds
WHERE billing_amount < q1 - 1.5 * (q3 - q1)
   OR billing_amount > q3 + 1.5 * (q3 - q1);

-- 2.6  SAME NAME WITH CONFLICTING AGE OR GENDER
-- Because the dataset has no patient ID, the same name appearing
-- twice could be two different people or one person admitted twice.
-- If the age or gender differs across rows with the same name, they
-- are almost certainly different people, not re-admissions.
-- This check counts how many names have that conflict.
SELECT COUNT(*) AS names_with_conflicting_age_or_gender
FROM (
    SELECT LOWER(name) AS n
    FROM raw_admissions
    GROUP BY LOWER(name)
    HAVING COUNT(*) > 1
       AND (COUNT(DISTINCT age) > 1 OR COUNT(DISTINCT gender) > 1)
) x;


-- =====================================================================
-- SECTION 3 : CLEANING  ->  stg_admissions
-- Goal: produce one clean, de-duplicated row per admission.
-- Rules applied:
--   * SELECT DISTINCT removes the 534 exact duplicate rows.
--   * Patient name: strip honorific prefix (Mr., Dr., etc.) and
--     credential suffix (MD, PhD, etc.), then TRIM whitespace.
--     MySQL has no INITCAP function so we leave casing as-is; the
--     names are not used as a dimension in the dashboard anyway.
--   * Blood type: UPPER + TRIM for consistent casing (e.g. "a+" -> "A+").
--   * Hospital: replace commas with spaces, remove a leading or
--     trailing "and", then collapse any double spaces.
--   * All other text columns: TRIM only (they were already consistent).
--   * billing_amount: ROUND to 2 decimal places (cents).
-- raw_admissions is never changed.
-- =====================================================================

DROP TABLE IF EXISTS stg_admissions;
CREATE TABLE stg_admissions AS
SELECT DISTINCT
    -- Patient name: remove title prefix then credential suffix, trim result.
    -- REGEXP_REPLACE in MySQL 8 replaces all matches by default.
    TRIM(
        REGEXP_REPLACE(
            REGEXP_REPLACE(TRIM(name),
                '^(Mr|Mrs|Ms|Miss|Dr)\\.?\\s+', ''),   -- strip prefix
            '\\s+(MD|DDS|DVM|PhD|Jr\\.?|II|III|IV)$', '') -- strip suffix
    )                                              AS patient_name,

    age,

    -- Gender and other short categoricals only need TRIM.
    TRIM(gender)                                   AS gender,

    -- Blood type is stored in mixed case in the source (e.g. "a+", "B-").
    -- UPPER makes it consistent for grouping and display.
    UPPER(TRIM(blood_type))                        AS blood_type,

    TRIM(medical_condition)                        AS medical_condition,
    date_of_admission,
    discharge_date,

    -- Doctor names are not used as a dimension but we trim for cleanliness.
    TRIM(doctor)                                   AS doctor,

    -- Hospital cleaning (innermost to outermost):
    --   1. Replace any comma (with optional surrounding spaces) with a space.
    --   2. Remove a leading "and " (any casing) at the start of the name.
    --   3. Remove a trailing " and" (any casing) at the end of the name.
    --   4. Collapse any run of multiple spaces down to one.
    --   5. TRIM removes any leftover leading/trailing space.
    TRIM(
        REGEXP_REPLACE(
            REGEXP_REPLACE(
                REGEXP_REPLACE(
                    REGEXP_REPLACE(TRIM(hospital), '\\s*,\\s*', ' '), -- step 1
                    '^[Aa][Nn][Dd]\\s+', ''),                         -- step 2
                '\\s+[Aa][Nn][Dd]$', ''),                             -- step 3
            '\\s+', ' ')                                              -- step 4
    )                                              AS hospital,

    TRIM(insurance_provider)                       AS insurance_provider,

    -- Round billing to 2 decimal places (dollars and cents).
    ROUND(billing_amount, 2)                       AS billing_amount,

    room_number,
    TRIM(admission_type)                           AS admission_type,
    TRIM(medication)                               AS medication,
    TRIM(test_results)                             AS test_results
FROM raw_admissions;


-- =====================================================================
-- SECTION 4 : TRANSFORMATION  ->  fact and dimension tables
-- Goal: build a simple star schema ready for Power BI.
--   fact_admissions  : one row per admission, all measures and FKs.
--   dim_*            : one row per distinct category value.
--   dim_date         : one row per calendar day 2019-01-01 to 2024-12-31.
-- Derived columns added here (not in staging):
--   admission_id     : surrogate key (ROW_NUMBER).
--   age_group        : bucketed age band for the demographics page.
--   length_of_stay   : DATEDIFF(discharge, admission) in whole days.
--   los_band         : length-of-stay bucket for the utilisation page.
--   negative_billing_flag : 1 if billing_amount < 0, else 0.
-- =====================================================================

-- FACT TABLE
-- ROW_NUMBER gives each admission a unique integer key.
-- DATEDIFF(discharge_date, date_of_admission) is the MySQL way to
-- subtract two dates; the result is the number of whole days.
DROP TABLE IF EXISTS fact_admissions;
CREATE TABLE fact_admissions AS
SELECT
    ROW_NUMBER() OVER (
        ORDER BY date_of_admission, patient_name, discharge_date
    )                                                              AS admission_id,
    patient_name,
    age,

    -- Age group bands used on the Patient & Demographics page.
    CASE WHEN age < 18 THEN '13-17'
         WHEN age < 30 THEN '18-29'
         WHEN age < 45 THEN '30-44'
         WHEN age < 60 THEN '45-59'
         WHEN age < 75 THEN '60-74'
         ELSE '75+' END                                            AS age_group,

    gender,
    blood_type,
    medical_condition,
    date_of_admission,
    discharge_date,

    -- Length of stay in days.  DATEDIFF returns discharge minus admission.
    DATEDIFF(discharge_date, date_of_admission)                    AS length_of_stay,

    -- LOS band used on the Utilisation & Services page.
    CASE WHEN DATEDIFF(discharge_date, date_of_admission) <= 7  THEN '1-7'
         WHEN DATEDIFF(discharge_date, date_of_admission) <= 14 THEN '8-14'
         WHEN DATEDIFF(discharge_date, date_of_admission) <= 21 THEN '15-21'
         ELSE '22-30' END                                          AS los_band,

    doctor,
    hospital,
    insurance_provider,
    admission_type,
    room_number,
    medication,
    test_results,
    billing_amount,

    -- Flag negative billing rows so they can be isolated in the
    -- Costs & Billing page without removing them from totals.
    CASE WHEN billing_amount < 0 THEN 1 ELSE 0 END                 AS negative_billing_flag
FROM stg_admissions;


-- DIMENSION TABLES
-- Each dim table holds the distinct values for one categorical column.
-- In Power BI these become the filter/slicer tables connected to the
-- fact table via one-to-many relationships.

-- Medical conditions (Arthritis, Cancer, Diabetes, etc.)
DROP TABLE IF EXISTS dim_medical_condition;
CREATE TABLE dim_medical_condition AS
    SELECT DISTINCT medical_condition FROM fact_admissions;

-- Insurance providers (Aetna, Blue Cross, Cigna, etc.)
DROP TABLE IF EXISTS dim_insurance;
CREATE TABLE dim_insurance AS
    SELECT DISTINCT insurance_provider FROM fact_admissions;

-- Admission types (Elective, Emergency, Urgent)
DROP TABLE IF EXISTS dim_admission_type;
CREATE TABLE dim_admission_type AS
    SELECT DISTINCT admission_type FROM fact_admissions;

-- Medications (Aspirin, Ibuprofen, Lipitor, etc.)
DROP TABLE IF EXISTS dim_medication;
CREATE TABLE dim_medication AS
    SELECT DISTINCT medication FROM fact_admissions;

-- DATE DIMENSION
-- MySQL 8 has no generate_series, so we use a recursive CTE.
-- The anchor row is 2019-01-01; each recursive step adds one day
-- until we reach 2024-12-31.  The result covers the full data range
-- plus padding so the time-intelligence measures in Power BI work
-- correctly even for partial years at the start and end.
DROP TABLE IF EXISTS dim_date;
CREATE TABLE dim_date AS
WITH RECURSIVE date_series AS (
    SELECT DATE('2019-01-01') AS date_key          -- anchor: first day
    UNION ALL
    SELECT DATE_ADD(date_key, INTERVAL 1 DAY)      -- add one day each step
    FROM date_series
    WHERE date_key < DATE('2024-12-31')            -- stop at last day
)
SELECT date_key,
       YEAR(date_key)               AS year,
       QUARTER(date_key)            AS quarter,
       MONTH(date_key)              AS month_no,
       DATE_FORMAT(date_key, '%b')  AS month_name   -- Jan, Feb, Mar ...
FROM date_series;


-- =====================================================================
-- SECTION 5 : QUALITY CHECKS ON THE CLEANED DATA
-- Goal: confirm that every cleaning rule worked correctly.
-- All five checks should return 'PASS'.  If any returns 'FAIL',
-- go back to Section 3 and investigate the cleaning logic.
-- =====================================================================

-- Check 1: No duplicate rows remain after SELECT DISTINCT.
--   MySQL cannot do COUNT(DISTINCT col1, col2, ...) with multiple
--   columns, so we hash all 15 columns together with MD5(CONCAT_WS).
--   CONCAT_WS uses '|' as a separator so values cannot accidentally
--   merge (e.g. 'AB' + 'C' vs 'A' + 'BC').
-- Check 2: The four most critical columns have no NULLs.
-- Check 3: Every length_of_stay value is between 1 and 30 days.
-- Check 4: Every admission date exists in dim_date (no orphan rows).
-- Check 5: No hospital name still contains a comma or starts with "and".
SELECT 'No duplicate rows' AS check_name,
       CASE WHEN COUNT(*) = COUNT(DISTINCT MD5(CONCAT_WS('|',
                patient_name, age, gender, blood_type, medical_condition,
                date_of_admission, doctor, hospital, insurance_provider,
                billing_amount, room_number, admission_type,
                discharge_date, medication, test_results)))
            THEN 'PASS' ELSE 'FAIL' END AS result
FROM fact_admissions

UNION ALL

SELECT 'No nulls in key fields',
       CASE WHEN SUM(CASE WHEN date_of_admission IS NULL
                            OR discharge_date    IS NULL
                            OR billing_amount    IS NULL
                            OR medical_condition IS NULL
                          THEN 1 ELSE 0 END) = 0
            THEN 'PASS' ELSE 'FAIL' END
FROM fact_admissions

UNION ALL

SELECT 'Length of stay is 1 to 30 days',
       CASE WHEN MIN(length_of_stay) >= 1
             AND MAX(length_of_stay) <= 30
            THEN 'PASS' ELSE 'FAIL' END
FROM fact_admissions

UNION ALL

-- LEFT JOIN to dim_date; any fact row with no matching date_key
-- means that date is missing from the dimension table.
SELECT 'Every admission has a date-dimension row',
       CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END
FROM fact_admissions f
LEFT JOIN dim_date d ON d.date_key = f.date_of_admission
WHERE d.date_key IS NULL

UNION ALL

SELECT 'No hospital names with commas or leading and',
       CASE WHEN SUM(CASE WHEN hospital LIKE '%,%'
                            OR LOWER(hospital) LIKE 'and %'
                          THEN 1 ELSE 0 END) = 0
            THEN 'PASS' ELSE 'FAIL' END
FROM fact_admissions;


-- =====================================================================
-- SECTION 6 : RECONCILIATION
-- Goal: produce the same headline numbers that appear on the Power BI
-- Executive Overview and Costs & Billing pages.
-- Run this after loading the .pbix and compare each value to the
-- corresponding KPI card.  Any mismatch means the model or a DAX
-- measure needs investigation.
-- Expected (from the README):
--   admissions          ~54,966
--   total_billing       ~$1.40 B
--   avg_billing         ~$25,544
--   avg_length_of_stay  ~15.5 days
--   total_bed_days      ~851,934
--   avg_age             ~51.5
--   negative_billing_rows ~106
-- =====================================================================

SELECT
    COUNT(*)                                                           AS admissions,
    ROUND(SUM(billing_amount), 0)                                      AS total_billing,
    ROUND(AVG(billing_amount), 0)                                      AS avg_billing,
    ROUND(AVG(length_of_stay), 1)                                      AS avg_length_of_stay,
    SUM(length_of_stay)                                                AS total_bed_days,
    ROUND(AVG(age), 1)                                                 AS avg_age,
    ROUND(100.0 * AVG(CASE WHEN test_results   = 'Abnormal'  THEN 1 ELSE 0 END), 1) AS abnormal_pct,
    ROUND(100.0 * AVG(CASE WHEN admission_type = 'Emergency' THEN 1 ELSE 0 END), 1) AS emergency_pct,
    SUM(negative_billing_flag)                                         AS negative_billing_rows,
    ROUND(SUM(CASE WHEN negative_billing_flag = 1
                   THEN billing_amount ELSE 0 END), 0)                 AS negative_billing_total
FROM fact_admissions;


-- =====================================================================
-- SECTION 7 : ANALYSIS QUERIES
-- Goal: reproduce the logic behind each dashboard visual in plain SQL
-- so the numbers can be verified independently of Power BI.
-- Each query maps to a specific chart or table on the dashboard.
-- =====================================================================

-- 7.1  ADMISSIONS AND BILLING BY YEAR  (Executive Overview - line chart)
-- YEAR() extracts the four-digit year from the admission date.
-- The partial years 2019 and 2024 will show lower counts than full years.
SELECT YEAR(date_of_admission)        AS year,
       COUNT(*)                       AS admissions,
       ROUND(SUM(billing_amount), 0)  AS total_billing
FROM fact_admissions
GROUP BY YEAR(date_of_admission)
ORDER BY year;

-- 7.2  BILLING BY INSURANCE PROVIDER  (Costs & Billing - bar chart)
-- pct_of_billing uses a window function to divide each provider's
-- total by the grand total without a self-join or subquery.
-- The result should show roughly equal shares (~16-17%) per provider.
SELECT insurance_provider,
       COUNT(*)                       AS admissions,
       ROUND(SUM(billing_amount), 0)  AS total_billing,
       ROUND(AVG(billing_amount), 0)  AS avg_billing,
       ROUND(100.0 * SUM(billing_amount)
             / SUM(SUM(billing_amount)) OVER (), 1) AS pct_of_billing
FROM fact_admissions
GROUP BY insurance_provider
ORDER BY total_billing DESC;

-- 7.3  LENGTH-OF-STAY BANDS  (Utilisation & Services - clustered bar)
-- Shows what share of admissions and bed days each LOS band accounts
-- for, plus the billing rate per bed day.
-- Key finding: the 22-30 day band is ~30% of admissions but ~50% of
-- bed days, and its billing per bed day is the lowest (~$980).
SELECT los_band,
       COUNT(*)                                                            AS admissions,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1)                 AS pct_admissions,
       SUM(length_of_stay)                                                 AS bed_days,
       ROUND(100.0 * SUM(length_of_stay)
             / SUM(SUM(length_of_stay)) OVER (), 1)                        AS pct_bed_days,
       ROUND(SUM(billing_amount) / SUM(length_of_stay), 0)                AS billing_per_bed_day
FROM fact_admissions
GROUP BY los_band
ORDER BY MIN(length_of_stay);

-- 7.4  TEST RESULTS MIX BY MEDICAL CONDITION  (Patient & Demographics - 100% stacked bar)
-- PARTITION BY medical_condition means the percentage is calculated
-- within each condition, not across all rows.
-- Expected: roughly equal Normal / Abnormal / Inconclusive splits
-- for every condition (no condition stands out).
SELECT medical_condition,
       test_results,
       COUNT(*) AS admissions,
       ROUND(100.0 * COUNT(*)
             / SUM(COUNT(*)) OVER (PARTITION BY medical_condition), 1) AS pct_within_condition
FROM fact_admissions
GROUP BY medical_condition, test_results
ORDER BY medical_condition, test_results;

-- 7.5  NEGATIVE BILLING RECORDS FOR REVIEW  (Costs & Billing - detail table)
-- Lists every admission where billing_amount is negative so a
-- business user can investigate whether each one is a refund,
-- a billing adjustment, or a data entry error.
-- Ordered ascending so the most negative amount appears first.
SELECT admission_id,
       medical_condition,
       insurance_provider,
       admission_type,
       billing_amount
FROM fact_admissions
WHERE negative_billing_flag = 1
ORDER BY billing_amount;
