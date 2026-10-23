/* ==============================================================================
Create the database, raw tables, load the CSVs, and profile the data.
===============================================================================*/

-- ------------------------------------------------------------------------------
-- Step: 1 - Create Database
-- ------------------------------------------------------------------------------
IF DB_ID('EventRegistrations') IS NULL
	CREATE DATABASE EventRegistrations;
GO
USE EventRegistrations;
GO

-- ------------------------------------------------------------------------------
-- Step: 2 - Create raw tables
-- ------------------------------------------------------------------------------
DROP TABLE IF EXISTS dbo.raw_registrations;
CREATE TABLE dbo.raw_registrations (
	registration_id     NVARCHAR(20),
	registration_type   NVARCHAR(50),
	delegate_name       NVARCHAR(200),
	school_name         NVARCHAR(300),
	university_name     NVARCHAR(300),
	email_id            NVARCHAR(300),
	phone_no            NVARCHAR(50),       
	city                NVARCHAR(100),
	country             NVARCHAR(100),
	region              NVARCHAR(100),
	registration_date   NVARCHAR(20),
	event_name          NVARCHAR(100),
	form_source         NVARCHAR(50),
	fee_amount          NVARCHAR(20),
	payment_status      NVARCHAR(20)
);

DROP TABLE IF EXISTS dbo.ref_institutions;
CREATE TABLE dbo.ref_institutions(
	institution_id     INT           NOT NULL PRIMARY KEY,
	institution_name   NVARCHAR(300) NOT NULL,
	institution_type   NVARCHAR(50)  NOT NULL,
	city               NVARCHAR(100),
	country            NVARCHAR(100),
	region             NVARCHAR(100)
);
GO

-- ----------------------------------------------------------------------------------------
-- Step: 3 - Load the CSV files
-- ----------------------------------------------------------------------------------------
BULK INSERT dbo.raw_registrations
FROM 'C:\EventRegistrations\Data\raw_registrations.csv'
WITH (
	FORMAT  = 'CSV',
	FIRSTROW = 2,
	FIELDTERMINATOR = ',',
	ROWTERMINATOR = '0x0d0a',
	CODEPAGE = '65001',
	TABLOCK
);

BULK INSERT dbo.ref_institutions
FROM 'C:\EventRegistrations\Data\reference_institutions.csv'
WITH (
	FORMAT  = 'CSV',
	FIRSTROW = 2,
	FIELDTERMINATOR = ',',
	ROWTERMINATOR = '0x0d0a',
	CODEPAGE = '65001',
	TABLOCK
);
GO

-- -----------------------------------------------------------------------------------
-- Step: 4 - Check the load
-- -----------------------------------------------------------------------------------
SELECT * FROM dbo.raw_registrations;
SELECT * FROM dbo.ref_institutions;

-- -----------------------------------------------------------------------------------
--	Step: 5 - Profile the raw data
-- -----------------------------------------------------------------------------------

-- 5a. Registartion type spilt
SELECT registration_type, form_source, COUNT(*) AS registrations
FROM dbo.raw_registrations
GROUP BY registration_type, form_source
ORDER BY registrations DESC;

-- 5b. Blank or missing values per column
SELECT
	SUM(CASE WHEN NULLIF(LTRIM(RTRIM(delegate_name)),'') IS NULL THEN 1 ELSE 0 END) AS blank_name,
	SUM(CASE WHEN NULLIF(LTRIM(RTRIM(email_id)),'') IS NULL THEN 1 ELSE 0 END) AS blank_email,
	SUM(CASE WHEN NULLIF(LTRIM(RTRIM(phone_no)),'') IS NULL THEN 1 ELSE 0 END) AS blank_phone,
	SUM(CASE WHEN NULLIF(LTRIM(RTRIM(city)),'') IS NULL THEN 1 ELSE 0 END) AS blank_city,
	SUM(CASE WHEN NULLIF(LTRIM(RTRIM(country)),'') IS NULL THEN 1 ELSE 0 END) AS blank_country,
	SUM(CASE WHEN NULLIF(LTRIM(RTRIM(region)),'') IS NULL THEN 1 ELSE 0 END) AS blank_region
FROM dbo.raw_registrations;

-- 5c. Country spellings (shows the USA / US / United States problem)
SELECT country, COUNT(*) AS cnt
FROM dbo.raw_registrations
GROUP BY country
ORDER BY country;

-- 5d. Institution fields: both filled, neither filled
SELECT
	SUM(CASE WHEN NULLIF(LTRIM(RTRIM(school_name)), '') IS NOT NULL
			AND NULLIF(LTRIM(RTRIM(university_name)), '') IS NOT NULL THEN 1 ELSE 0 END) AS both_filled,
	SUM(CASE WHEN NULLIF(LTRIM(RTRIM(school_name)), '') IS NOT NULL
			AND NULLIF(LTRIM(RTRIM(university_name)), '') IS NOT NULL THEN 1 ELSE 0 END) AS neither_filled
FROM dbo.raw_registrations;

-- 5e. Emails that clearly fail a basic pattern 
SELECT COUNT(*) AS suspicious_emails
FROM dbo.raw_registrations
WHERE email_id IS NULL
	OR email_id NOT LIKE '%_@_%._%'
	OR email_id LIKE '% %'
	OR email_id LIKE '%@%@%';


-- 5f. Institution names that do not match the reference list exactly
SELECT COUNT(*) AS names_not_exact_match
FROM dbo.raw_registrations r
WHERE NOT EXISTS (
	SELECT 1 FROM dbo.ref_institutions ri
	WHERE ri.institution_name = COALESCE(NULLIF(LTRIM(RTRIM(r.school_name)), ''),
										 NULLIF(LTRIM(RTRIM(r.university_name)), ''))
);

-- 5g. Exact duplicate rows ignoring the registration ID
SELECT delegate_name, email_id, COALESCE(school_name, university_name) AS institution, COUNT(*) AS times
FROM dbo.raw_registrations
GROUP BY delegate_name, email_id, COALESCE(school_name, university_name)
HAVING COUNT(*) > 1
ORDER BY times DESC;


	