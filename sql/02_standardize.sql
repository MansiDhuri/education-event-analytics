USE EventRegistrations;
GO

-- --------------------------------------------------------------------
-- Step: 1 - Country reference (standard name, region, phone rules)
-- --------------------------------------------------------------------
DROP TABLE IF EXISTS dbo.ref_country;
CREATE TABLE dbo.ref_country (
	country         NVARCHAR(100) NOT NULL PRIMARY KEY,
	region          NVARCHAR(100) NOT NULL,
	dial_code       NVARCHAR(5)   NOT NULL,
	phone_digits    INT           NOT NULL
);
INSERT INTO dbo.ref_country (country, region, dial_code, phone_digits) VALUES
(N'United States',        N'North America', N'1',   10),
(N'Canada',               N'North America', N'1',   10),
(N'United Kingdom',       N'Europe',        N'44',  10),
(N'Germany',              N'Europe',        N'49',  10),
(N'France',               N'Europe',        N'33',  9),
(N'United Arab Emirates', N'Middle East',   N'971', 9),
(N'Saudi Arabia',         N'Middle East',   N'966', 9),
(N'India',                N'Asia Pacific',  N'91',  10),
(N'Singapore',            N'Asia Pacific',  N'65',  8),
(N'Australia',            N'Asia Pacific',  N'61',  9),
(N'South Africa',         N'Africa',        N'27',  9),
(N'Nigeria',              N'Africa',        N'234', 10),
(N'Kenya',                N'Africa',        N'254', 9),
(N'Brazil',               N'Latin America', N'55',  11),
(N'Mexico',               N'Latin America', N'52',  10);

-- Spelling variants -> standard country 
DROP TABLE IF EXISTS dbo.country_map;
CREATE TABLE dbo.country_map (
	variant NVARCHAR(100) NOT NULL PRIMARY KEY,
	country NVARCHAR(100) NOT NULL
);
INSERT INTO dbo.country_map (variant,country)
SELECT country, country FROM dbo.ref_country;

INSERT INTO dbo.country_map (variant,country) VALUES
(N'USA', N'United States'), (N'US', N'United States'), (N'U.S.A', N'United States'),
(N'United States of America', N'United States'),
(N'UK', N'United Kingdom'), (N'U.K.', N'United Kingdom'), (N'Great Britain', N'United Kingdom'),
(N'UAE', N'United Arab Emirates'), (N'U.A.E', N'United Arab Emirates'),
(N'IND', N'India'), (N'Bharat', N'India'),
(N'Brasil', N'Brazil'), (N'Deutschland', N'Germany');
GO

-- Blocklist of fake or throwaway email domains
DROP TABLE IF EXISTS dbo.email_blocklist;
CREATE TABLE dbo.email_blocklist (domain NVARCHAR(200) NOT NULL PRIMARY KEY);
INSERT INTO dbo.email_blocklist (domain) VALUES
(N'test.com'), (N'abc.com'), (N'na.com'), (N'asdf.in'), (N'example.com'), (N'mailinator.com');
GO

-- City -> country lookup, used to fill a missing country
CREATE OR ALTER VIEW dbo.vw_ref_city AS
SELECT DISTINCT city, country FROM dbo.ref_institutions;
GO

-- ---------------------------------------------------------------------------------------------
-- Step: 2 - Helper functions
-- ---------------------------------------------------------------------------------------------

-- Trim , collapse repeated spaces to one, return NULL if empty
CREATE OR ALTER FUNCTION dbo.fn_CleanText (@s NVARCHAR(500))
RETURNS NVARCHAR(500)
AS 
BEGIN
	RETURN NULLIF(
		LTRIM(RTRIM(
			REPLACE(REPLACE(REPLACE(@s, N'  ', N' ' + NCHAR(7)), NCHAR(7) + N' ', N''), NCHAR(7), N'')
			)), N'');
END;
GO

-- Proper Case: capitalise the first letter after a space, hyphen, apostrophe or dot
CREATE OR ALTER FUNCTION dbo.fn_ProperCase (@s NVARCHAR(200))
RETURNS NVARCHAR(200)
AS
BEGIN
	IF @s IS NULL RETURN NULL;
	DECLARE @r NVARCHAR(200) = LOWER(@s),
            @i INT = 1,
            @len INT = LEN(@s),
            @prev NCHAR(1) = N' ';
    WHILE @i <= @len
	BEGIN
        IF @prev IN (N' ', N'-', N'''', N'.')
            SET @r = STUFF(@r, @i, 1, UPPER(SUBSTRING(@r, @i, 1)));
        SET @prev = SUBSTRING(@r, @i, 1);
        SET @i += 1;
    END;
    RETURN @r;
END;
GO

-- Levenshtein edit distance (used for fuzzy institution matching in script 03)
CREATE OR ALTER FUNCTION dbo.fn_Levenshtein (@s NVARCHAR(300), @t NVARCHAR(300))
RETURNS INT
AS
BEGIN
    DECLARE @sl INT = LEN(@s), @tl INT = LEN(@t),
            @i INT = 1, @j INT = 1,
            @sc NCHAR(1), @c INT = 0, @c1 INT,
            @cv0 NVARCHAR(300), @cv1 NVARCHAR(300) = N'';

    IF @sl = 0 RETURN @tl;
    IF @tl = 0 RETURN @sl;

    WHILE @j <= @tl
    BEGIN
        SET @cv1 = @cv1 + NCHAR(@j);
        SET @j += 1;
    END;
    
    WHILE @i <= @sl
    BEGIN
        SELECT @sc = SUBSTRING(@s, @i, 1), @c1 = @i, @c = @i, @cv0 = N'', @j = 1;
        WHILE @j <= @tl
        BEGIN
            SET @c += 1;
            SET @c1 = @c1 - CASE WHEN @sc = SUBSTRING(@t, @j, 1) THEN 1 ELSE 0 END;
            IF @c > @c1 SET @c = @c1;
            SET @c1 = UNICODE(SUBSTRING(@cv1, @j, 1)) + 1;
            IF @c > @c1 SET @c = @c1;
            SET @cv0 = @cv0 + NCHAR(@c);
            SET @j += 1;
        END;
        SELECT @cv1 = @cv0, @i += 1;
    END;
    RETURN @c;
END;
GO

-- Quick test: expect 1 and 3
SELECT dbo.fn_Levenshtein(N'Oakwood', N'Oakwod') AS expect_1,
       dbo.fn_Levenshtein(N'kitten',  N'sitting') AS expect_3;
GO

-- ---------------------------------------------------------------------------------
-- STEP 3: Build the standardized staging table
-- ---------------------------------------------------------------------------------
DROP TABLE IF EXISTS dbo.stg_registrations;

SELECT
    r.registration_id,
    NULLIF(LTRIM(RTRIM(r.registration_type)), N'')            AS registration_type,

    -- Name: NULL-like text becomes NULL, then Proper Case
    CASE WHEN c.nm IN (N'NULL', N'N/A', N'-') THEN NULL
         ELSE dbo.fn_ProperCase(c.nm) END                      AS delegate_name,

    -- Institution: use the field that matches the registration type, expand abbreviations
    REPLACE(REPLACE(REPLACE(i.inst_raw, N'Univ.', N'University'), N'Intl', N'International'), N'Sch.', N'School')
                                                               AS inst_name,
    CASE WHEN c.sch IS NULL AND c.uni IS NULL     THEN N'Missing'
         WHEN c.sch IS NOT NULL AND c.uni IS NOT NULL THEN N'Both filled'
    END                                                        AS inst_field_issue,

    LOWER(c.em)                                                AS email,

    c.ph                                                       AS phone_raw,
    REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(c.ph, N'+', N''), N' ', N''), N'-', N''), N'(', N''), N')', N'')
                                                               AS phone_digits,
    c.city                                                     AS city,
    COALESCE(cm.country, rc.country)                           AS country_final,
    c.region                                                   AS region_raw,
    ref.region                                                 AS region_final,

    TRY_CAST(r.registration_date AS DATE)                      AS registration_date,
    NULLIF(LTRIM(RTRIM(r.event_name)), N'')                    AS event_name,
    NULLIF(LTRIM(RTRIM(r.form_source)), N'')                   AS form_source,
    TRY_CAST(r.fee_amount AS DECIMAL(10, 2))                   AS fee_amount,
    NULLIF(LTRIM(RTRIM(r.payment_status)), N'')                AS payment_status
INTO dbo.stg_registrations
FROM dbo.raw_registrations r
CROSS APPLY (SELECT dbo.fn_CleanText(r.delegate_name)   AS nm,
                    dbo.fn_CleanText(r.school_name)     AS sch,
                    dbo.fn_CleanText(r.university_name) AS uni,
                    dbo.fn_CleanText(r.email_id)        AS em,
                    dbo.fn_CleanText(r.phone_no)        AS ph,
                    dbo.fn_CleanText(r.city)            AS city,
                    dbo.fn_CleanText(r.country)         AS country,
                    dbo.fn_CleanText(r.region)          AS region) c
CROSS APPLY (SELECT CASE WHEN r.registration_type = N'School'
                         THEN COALESCE(c.sch, c.uni)
                         ELSE COALESCE(c.uni, c.sch) END AS inst_raw) i
LEFT JOIN dbo.country_map cm ON cm.variant = c.country
LEFT JOIN dbo.vw_ref_city rc ON rc.city = c.city
LEFT JOIN dbo.ref_country ref ON ref.country = COALESCE(cm.country, rc.country);
GO

-- -------------------------------------------------------------------------------------
-- STEP 4: Check the result
-- -------------------------------------------------------------------------------------
SELECT COUNT(*) AS rows_in_stg FROM dbo.stg_registrations;   -- expect 8480

SELECT TOP 20 * FROM dbo.stg_registrations ORDER BY registration_id;

-- Countries are now standard (15 values, plus NULL if none could be resolved)
SELECT country_final, COUNT(*) AS cnt
FROM dbo.stg_registrations
GROUP BY country_final
ORDER BY country_final;

-- Missing values left after standardization
SELECT
    SUM(CASE WHEN delegate_name  IS NULL THEN 1 ELSE 0 END) AS name_null,
    SUM(CASE WHEN email          IS NULL THEN 1 ELSE 0 END) AS email_null,
    SUM(CASE WHEN city           IS NULL THEN 1 ELSE 0 END) AS city_null,
    SUM(CASE WHEN country_final  IS NULL THEN 1 ELSE 0 END) AS country_null,
    SUM(CASE WHEN region_final   IS NULL THEN 1 ELSE 0 END) AS region_null,
    SUM(CASE WHEN registration_date IS NULL THEN 1 ELSE 0 END) AS bad_date
FROM dbo.stg_registrations;
