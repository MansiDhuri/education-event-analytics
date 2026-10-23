USE EventRegistrations;
GO

-- -----------------------------------------------------------------------------
-- STEP 1: Institution matching
-- -----------------------------------------------------------------------------
DROP TABLE IF EXISTS dbo.stg_inst_match;
CREATE TABLE dbo.stg_inst_match (
    inst_name       NVARCHAR(300),
    country_final   NVARCHAR(100),
    institution_id  INT,
    matched_name    NVARCHAR(300),
    match_method    NVARCHAR(20),     -- Exact / Fuzzy
    similarity      DECIMAL(5, 2)
);

DROP TABLE IF EXISTS #to_match;
SELECT DISTINCT inst_name, country_final
INTO #to_match
FROM dbo.stg_registrations
WHERE inst_name IS NOT NULL;

-- 1a. Exact match (case-insensitive because of the default collation)
INSERT INTO dbo.stg_inst_match (inst_name, country_final, institution_id, matched_name, match_method, similarity)
SELECT t.inst_name, t.country_final, ri.institution_id, ri.institution_name, N'Exact', 1.00
FROM #to_match t
JOIN dbo.ref_institutions ri
  ON ri.institution_name = t.inst_name
 AND ri.country = t.country_final;

-- 1b. Fuzzy match for the rest, only against institutions in the same country.
;WITH cand AS (
    SELECT t.inst_name, t.country_final, ri.institution_id, ri.institution_name,
           CAST(1.0 - dbo.fn_Levenshtein(t.inst_name, ri.institution_name) * 1.0
                    / CASE WHEN LEN(t.inst_name) > LEN(ri.institution_name)
                           THEN LEN(t.inst_name) ELSE LEN(ri.institution_name) END
                AS DECIMAL(5, 2)) AS sim
    FROM #to_match t
    JOIN dbo.ref_institutions ri ON ri.country = t.country_final
    WHERE NOT EXISTS (SELECT 1 FROM dbo.stg_inst_match m
                      WHERE m.inst_name = t.inst_name AND m.country_final = t.country_final)
),
ranked AS (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY inst_name, country_final ORDER BY sim DESC) AS rn
    FROM cand
)
INSERT INTO dbo.stg_inst_match (inst_name, country_final, institution_id, matched_name, match_method, similarity)
SELECT inst_name, country_final, institution_id, institution_name, N'Fuzzy', sim
FROM ranked
WHERE rn = 1 AND sim >= 0.85;

-- Check
SELECT match_method, COUNT(*) AS name_country_pairs FROM dbo.stg_inst_match GROUP BY match_method;
GO

-- ---------------------------------------------------------------------
-- STEP 2: Validation flags, duplicate detection, status
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS dbo.registrations_validated;

;WITH base AS (
    SELECT s.*,
           m.institution_id, m.matched_name, m.match_method, m.similarity,
           ri.institution_type, ri.city AS inst_city,
           rc.dial_code, rc.phone_digits AS expected_digits
    FROM dbo.stg_registrations s
    LEFT JOIN dbo.stg_inst_match m
           ON m.inst_name = s.inst_name AND m.country_final = s.country_final
    LEFT JOIN dbo.ref_institutions ri ON ri.institution_id = m.institution_id
    LEFT JOIN dbo.ref_country rc      ON rc.country = s.country_final
),
flags AS (
    SELECT b.*,
        COALESCE(b.city, b.inst_city) AS city_final,

        -- Full name expected: at least two words, no digits
        CASE WHEN b.delegate_name LIKE N'% %' AND b.delegate_name NOT LIKE N'%[0-9]%'
             THEN 1 ELSE 0 END AS name_ok,

        -- Email: pattern, no spaces, exactly one @, domain not on the blocklist
        CASE WHEN b.email LIKE N'%_@_%._%'
              AND b.email NOT LIKE N'% %'
              AND b.email NOT LIKE N'%@%@%'
              AND NOT EXISTS (SELECT 1 FROM dbo.email_blocklist bl
                              WHERE bl.domain = SUBSTRING(b.email, CHARINDEX(N'@', b.email) + 1, 200))
             THEN 1 ELSE 0 END AS email_ok,

        -- Phone: digits only, not all the same digit, right length for the country
        -- (either with or without the country code)
        CASE WHEN b.phone_digits IS NOT NULL
              AND b.phone_digits NOT LIKE N'%[^0-9]%'
              AND b.expected_digits IS NOT NULL
              AND b.phone_digits <> REPLICATE(LEFT(b.phone_digits, 1), LEN(b.phone_digits))
              AND (LEN(b.phone_digits) = b.expected_digits
                   OR (b.phone_digits LIKE b.dial_code + N'%'
                       AND LEN(b.phone_digits) = LEN(b.dial_code) + b.expected_digits))
             THEN 1 ELSE 0 END AS phone_ok,

        -- Fee: schools free, universities paid
        CASE WHEN (b.registration_type = N'School'     AND b.fee_amount = 0)
               OR (b.registration_type = N'University' AND b.fee_amount > 0)
             THEN 1 ELSE 0 END AS fee_ok
    FROM base b
),
dups AS (
    SELECT f.*,
        -- Rule 1: same valid email. Rule 2: same name + institution + country
        CASE WHEN f.email_ok = 1
             THEN ROW_NUMBER() OVER (PARTITION BY f.email
                                     ORDER BY f.registration_date, f.registration_id) END AS rn_email,
        CASE WHEN f.delegate_name IS NOT NULL AND f.institution_id IS NOT NULL
             THEN ROW_NUMBER() OVER (PARTITION BY f.delegate_name, f.institution_id, f.country_final
                                     ORDER BY f.registration_date, f.registration_id) END AS rn_person
    FROM flags f
),
reasons AS (
    SELECT d.*,
        CASE WHEN d.rn_email > 1 OR d.rn_person > 1 THEN 1 ELSE 0 END AS is_duplicate,

        -- Reasons that lead to Rejected (separated by ;)
        NULLIF(CONCAT_WS(N';',
            CASE WHEN d.rn_email > 1 OR d.rn_person > 1 THEN N'Duplicate registration' END,
            CASE WHEN d.inst_name IS NOT NULL AND d.institution_id IS NULL AND d.country_final IS NOT NULL
                 THEN N'Institution not found' END,
            CASE WHEN d.email_ok = 0 THEN N'Invalid email' END,
            CASE WHEN d.payment_status = N'Failed' THEN N'Payment failed' END
        ), N'') AS reject_reason,
        -- Reasons that lead to Needs Review
        NULLIF(CONCAT_WS(N';',
            CASE WHEN d.match_method = N'Fuzzy' THEN N'Institution name corrected by fuzzy match' END,
            CASE WHEN d.institution_type IS NOT NULL AND d.institution_type <> d.registration_type
                 THEN N'Registration type does not match institution type' END,
            CASE WHEN d.inst_field_issue IS NOT NULL THEN N'Institution field: ' + d.inst_field_issue END,
            CASE WHEN d.inst_name IS NOT NULL AND d.institution_id IS NULL AND d.country_final IS NULL
                 THEN N'Institution unverifiable (country unknown)' END,
            CASE WHEN d.name_ok = 0 THEN N'Name missing or incomplete' END,
            CASE WHEN d.phone_ok = 0 THEN N'Invalid phone' END,
            CASE WHEN COALESCE(d.city, d.inst_city) IS NULL THEN N'City missing' END,
            CASE WHEN d.country_final IS NULL THEN N'Country missing' END,
            CASE WHEN d.region_raw IS NOT NULL AND d.region_final IS NOT NULL
                  AND d.region_raw <> d.region_final THEN N'Region does not match country' END,
            CASE WHEN d.fee_ok = 0 THEN N'Fee does not match registration type' END,
            CASE WHEN d.payment_status = N'Pending' THEN N'Payment pending' END
        ), N'') AS review_reason
    FROM dups d
)
SELECT
    r.registration_id, r.registration_type, r.delegate_name,
    r.matched_name AS institution_name, r.institution_id, r.inst_name AS institution_name_entered,
    r.match_method, r.similarity,
    r.email, r.phone_digits, r.city_final AS city, r.country_final AS country,
    COALESCE(r.region_final, r.region_raw) AS region,
    r.registration_date, r.event_name, r.form_source, r.fee_amount, r.payment_status,
    r.name_ok, r.email_ok, r.phone_ok, r.fee_ok, r.is_duplicate,
    r.reject_reason, r.review_reason,
    CASE WHEN r.reject_reason IS NOT NULL THEN N'Rejected'
         WHEN r.review_reason IS NOT NULL THEN N'Needs Review'
         ELSE N'Verified' END AS validation_status
INTO dbo.registrations_validated
FROM reasons r;
GO


-- ---------------------------------------------------------------------
-- STEP 3: Views for each audience
-- ---------------------------------------------------------------------
CREATE OR ALTER VIEW dbo.vw_clean_registrations AS      -- ready for confirmation emails
SELECT registration_id, registration_type, delegate_name, institution_id, institution_name,
       email, phone_digits, city, country, region,
       registration_date, event_name, form_source, fee_amount, payment_status
FROM dbo.registrations_validated
WHERE validation_status = N'Verified';
GO

CREATE OR ALTER VIEW dbo.vw_needs_review AS             -- manual verification queue
SELECT registration_id, registration_type, delegate_name, institution_name_entered, institution_name,
       email, phone_digits, country, review_reason
FROM dbo.registrations_validated
WHERE validation_status = N'Needs Review';
GO

CREATE OR ALTER VIEW dbo.vw_rejected AS
SELECT registration_id, registration_type, delegate_name, institution_name_entered, email, country,
       reject_reason, review_reason
FROM dbo.registrations_validated
WHERE validation_status = N'Rejected';
GO

-- Quick result
SELECT validation_status, COUNT(*) AS registrations,
       CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER () AS DECIMAL(5, 1)) AS pct
FROM dbo.registrations_validated
GROUP BY validation_status;