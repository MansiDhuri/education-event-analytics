USE EventRegistrations;
GO

-- ---------------------------------------------------------------------
-- STEP 1: Drop old versions (fact first, because it references the dimensions)
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS dbo.fact_registrations;
DROP TABLE IF EXISTS dbo.dim_date;
DROP TABLE IF EXISTS dbo.dim_geography;
DROP TABLE IF EXISTS dbo.dim_institution;
DROP TABLE IF EXISTS dbo.dim_event;
DROP TABLE IF EXISTS dbo.dim_registration_type;
DROP TABLE IF EXISTS dbo.dim_status;
GO

-- ---------------------------------------------------------------------
-- STEP 2: Dimension tables
-- ---------------------------------------------------------------------

-- Date dimension: every day of 2026
CREATE TABLE dbo.dim_date (
    date_key      INT          NOT NULL PRIMARY KEY,   -- 20260315
    full_date     DATE         NOT NULL,
    year_num      INT          NOT NULL,
    quarter_num   INT          NOT NULL,
    month_num     INT          NOT NULL,
    month_name    NVARCHAR(10) NOT NULL,               -- Jan, Feb ...
    month_year    NVARCHAR(12) NOT NULL,               -- Jan 2026
    day_of_month  INT          NOT NULL,
    day_name      NVARCHAR(10) NOT NULL,
    is_weekend    BIT          NOT NULL
);

;WITH d AS (
    SELECT CAST('2026-01-01' AS DATE) AS dt
    UNION ALL
    SELECT DATEADD(DAY, 1, dt) FROM d WHERE dt < '2026-12-31'
)
INSERT INTO dbo.dim_date
SELECT YEAR(dt) * 10000 + MONTH(dt) * 100 + DAY(dt),
       dt, YEAR(dt), DATEPART(QUARTER, dt), MONTH(dt),
       LEFT(DATENAME(MONTH, dt), 3),
       LEFT(DATENAME(MONTH, dt), 3) + N' ' + CAST(YEAR(dt) AS NVARCHAR(4)),
       DAY(dt), DATENAME(WEEKDAY, dt),
       CASE WHEN DATENAME(WEEKDAY, dt) IN (N'Saturday', N'Sunday') THEN 1 ELSE 0 END
FROM d
OPTION (MAXRECURSION 400);

-- Geography dimension: city / country / region (missing values become 'Unknown')
CREATE TABLE dbo.dim_geography (
    geo_key  INT IDENTITY(1, 1) PRIMARY KEY,
    city     NVARCHAR(100) NOT NULL,
    country  NVARCHAR(100) NOT NULL,
    region   NVARCHAR(100) NOT NULL,
    CONSTRAINT uq_dim_geography UNIQUE (city, country, region)
);
INSERT INTO dbo.dim_geography (city, country, region)
SELECT DISTINCT COALESCE(city, N'Unknown'), COALESCE(country, N'Unknown'), COALESCE(region, N'Unknown')
FROM dbo.registrations_validated;

-- Institution dimension: the verified reference list, plus one row for "unknown"
CREATE TABLE dbo.dim_institution (
    institution_key   INT           NOT NULL PRIMARY KEY,
    institution_name  NVARCHAR(300) NOT NULL,
    institution_type  NVARCHAR(50)  NOT NULL,
    city              NVARCHAR(100),
    country           NVARCHAR(100),
    region            NVARCHAR(100)
);
INSERT INTO dbo.dim_institution (institution_key, institution_name, institution_type, city, country, region)
SELECT institution_id, institution_name, institution_type, city, country, region
FROM dbo.ref_institutions;
INSERT INTO dbo.dim_institution
VALUES (-1, N'Unknown / not verified', N'Unknown', N'Unknown', N'Unknown', N'Unknown');

-- Event dimension: the regional events, ordered by month
CREATE TABLE dbo.dim_event (
    event_key        INT IDENTITY(1, 1) PRIMARY KEY,
    event_name       NVARCHAR(100) NOT NULL UNIQUE,
    event_month_num  INT,
    event_type       NVARCHAR(20)
);
INSERT INTO dbo.dim_event (event_name, event_month_num, event_type)
SELECT event_name, MIN(MONTH(registration_date)), N'Regional'
FROM dbo.registrations_validated
WHERE event_name IS NOT NULL
GROUP BY event_name
ORDER BY MIN(MONTH(registration_date));

-- Registration type dimension: School (free, Google Form) vs University (paid, Cvent)
CREATE TABLE dbo.dim_registration_type (
    reg_type_key       INT IDENTITY(1, 1) PRIMARY KEY,
    registration_type  NVARCHAR(20) NOT NULL,
    form_source        NVARCHAR(50) NOT NULL,
    fee_model          NVARCHAR(10) NOT NULL,
    CONSTRAINT uq_dim_reg_type UNIQUE (registration_type, form_source)
);
INSERT INTO dbo.dim_registration_type (registration_type, form_source, fee_model)
SELECT DISTINCT registration_type, COALESCE(form_source, N'Unknown'),
       CASE registration_type WHEN N'School' THEN N'Free' ELSE N'Paid' END
FROM dbo.registrations_validated
WHERE registration_type IS NOT NULL;

-- Status dimension (sort_order keeps Verified, Needs Review, Rejected in a sensible order)
CREATE TABLE dbo.dim_status (
    status_key         INT          NOT NULL PRIMARY KEY,
    validation_status  NVARCHAR(20) NOT NULL UNIQUE,
    sort_order         INT          NOT NULL
);
INSERT INTO dbo.dim_status (status_key, validation_status, sort_order) VALUES
(1, N'Verified', 1), (2, N'Needs Review', 2), (3, N'Rejected', 3);
GO

-- ---------------------------------------------------------------------
-- STEP 3: Fact table, one row per registration
-- ---------------------------------------------------------------------
CREATE TABLE dbo.fact_registrations (
    registration_id   NVARCHAR(20)  NOT NULL PRIMARY KEY,
    date_key          INT           NULL REFERENCES dbo.dim_date (date_key),
    geo_key           INT           NOT NULL REFERENCES dbo.dim_geography (geo_key),
    institution_key   INT           NOT NULL REFERENCES dbo.dim_institution (institution_key),
    event_key         INT           NOT NULL REFERENCES dbo.dim_event (event_key),
    reg_type_key      INT           NOT NULL REFERENCES dbo.dim_registration_type (reg_type_key),
    status_key        INT           NOT NULL REFERENCES dbo.dim_status (status_key),
    delegate_name     NVARCHAR(200) NULL,
    email             NVARCHAR(300) NULL,
    fee_amount        DECIMAL(10, 2) NULL,
    payment_status    NVARCHAR(20)  NULL,
    name_ok           BIT NOT NULL,
    email_ok          BIT NOT NULL,
    phone_ok          BIT NOT NULL,
    fee_ok            BIT NOT NULL,
    is_duplicate      BIT NOT NULL,
    match_method      NVARCHAR(20)  NULL,
    similarity        DECIMAL(5, 2) NULL,
    reject_reason     NVARCHAR(500) NULL,
    review_reason     NVARCHAR(1000) NULL
);

INSERT INTO dbo.fact_registrations
    (registration_id, date_key, geo_key, institution_key, event_key, reg_type_key, status_key,
     delegate_name, email, fee_amount, payment_status,
     name_ok, email_ok, phone_ok, fee_ok, is_duplicate,
     match_method, similarity, reject_reason, review_reason)
SELECT v.registration_id,
       YEAR(v.registration_date) * 10000 + MONTH(v.registration_date) * 100 + DAY(v.registration_date),
       g.geo_key,
       COALESCE(v.institution_id, -1),
       e.event_key,
       rt.reg_type_key,
       s.status_key,
       v.delegate_name, v.email, v.fee_amount, v.payment_status,
       v.name_ok, v.email_ok, v.phone_ok, v.fee_ok, v.is_duplicate,
       v.match_method, v.similarity, v.reject_reason, v.review_reason
FROM dbo.registrations_validated v
JOIN dbo.dim_geography g
  ON g.city    = COALESCE(v.city, N'Unknown')
 AND g.country = COALESCE(v.country, N'Unknown')
 AND g.region  = COALESCE(v.region, N'Unknown')
JOIN dbo.dim_event e              ON e.event_name = v.event_name
JOIN dbo.dim_registration_type rt ON rt.registration_type = v.registration_type
                                 AND rt.form_source = COALESCE(v.form_source, N'Unknown')
JOIN dbo.dim_status s             ON s.validation_status = v.validation_status;
GO

-- ---------------------------------------------------------------------
-- STEP 4: Checks. The first query must show the same number twice.
-- ---------------------------------------------------------------------
SELECT (SELECT COUNT(*) FROM dbo.registrations_validated) AS validated_rows,
       (SELECT COUNT(*) FROM dbo.fact_registrations)      AS fact_rows;

-- Table sizes
SELECT 'dim_date' AS tbl, COUNT(*) AS row_count FROM dbo.dim_date
UNION ALL SELECT 'dim_geography', COUNT(*) FROM dbo.dim_geography
UNION ALL SELECT 'dim_institution', COUNT(*) FROM dbo.dim_institution
UNION ALL SELECT 'dim_event', COUNT(*) FROM dbo.dim_event
UNION ALL SELECT 'dim_registration_type', COUNT(*) FROM dbo.dim_registration_type
UNION ALL SELECT 'dim_status', COUNT(*) FROM dbo.dim_status
UNION ALL SELECT 'fact_registrations', COUNT(*) FROM dbo.fact_registrations;

-- A star-schema query: registrations by month, region and status
SELECT d.month_num, d.month_name, g.region, s.validation_status, COUNT(*) AS registrations
FROM dbo.fact_registrations f
JOIN dbo.dim_date d       ON d.date_key = f.date_key
JOIN dbo.dim_geography g  ON g.geo_key = f.geo_key
JOIN dbo.dim_status s     ON s.status_key = f.status_key
GROUP BY d.month_num, d.month_name, g.region, s.validation_status
ORDER BY d.month_num, g.region, s.validation_status;

-- ---------------------------------------------------------------------
-- STEP 5: One row per issue, for the "issues" chart in Power BI
-- Reasons are stored as text separated by ';', so split them into rows.
-- ---------------------------------------------------------------------
GO
CREATE OR ALTER VIEW dbo.vw_issues AS
SELECT f.registration_id, N'Rejected' AS severity, TRIM(s.value) AS issue
FROM dbo.fact_registrations f
CROSS APPLY STRING_SPLIT(f.reject_reason, ';') s
WHERE f.reject_reason IS NOT NULL
UNION ALL
SELECT f.registration_id, N'Needs Review', TRIM(s.value)
FROM dbo.fact_registrations f
CROSS APPLY STRING_SPLIT(f.review_reason, ';') s
WHERE f.review_reason IS NOT NULL;
GO

-- Check: the most common issues
SELECT severity, issue, COUNT(*) AS registrations
FROM dbo.vw_issues
GROUP BY severity, issue
ORDER BY severity, registrations DESC;
