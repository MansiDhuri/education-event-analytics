USE EventRegistrations;
GO

-- 1. Row reconciliation: nothing lost between raw and validated
SELECT (SELECT COUNT(*) FROM dbo.raw_registrations)       AS raw_rows,
       (SELECT COUNT(*) FROM dbo.registrations_validated) AS validated_rows;

-- 2. Status split overall
SELECT validation_status, COUNT(*) AS registrations
FROM dbo.registrations_validated
GROUP BY validation_status;

-- 3. Top rejection reasons (one row can have several)
SELECT TRIM(x.value) AS reason, COUNT(*) AS registrations
FROM dbo.registrations_validated v
CROSS APPLY STRING_SPLIT(v.reject_reason, ';') x
GROUP BY TRIM(x.value)
ORDER BY registrations DESC;

-- 4. Top review reasons
SELECT TRIM(x.value) AS reason, COUNT(*) AS registrations
FROM dbo.registrations_validated v
CROSS APPLY STRING_SPLIT(v.review_reason, ';') x
GROUP BY TRIM(x.value)
ORDER BY registrations DESC;

-- 5. Data quality by registration type (Google Form vs Cvent)
SELECT registration_type, form_source,
       COUNT(*) AS total,
       SUM(CASE WHEN validation_status = N'Verified' THEN 1 ELSE 0 END) AS verified,
       CAST(100.0 * SUM(CASE WHEN validation_status = N'Verified' THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5, 1)) AS verified_pct
FROM dbo.registrations_validated
GROUP BY registration_type, form_source;

-- 6. Data quality by region
SELECT region,
       COUNT(*) AS total,
       SUM(CASE WHEN validation_status = N'Verified' THEN 1 ELSE 0 END) AS verified,
       SUM(CASE WHEN validation_status = N'Needs Review' THEN 1 ELSE 0 END) AS needs_review,
       SUM(CASE WHEN validation_status = N'Rejected' THEN 1 ELSE 0 END) AS rejected
FROM dbo.registrations_validated
GROUP BY region
ORDER BY total DESC;

-- 7. Monthly registrations and data quality (feeds the trend page)
SELECT FORMAT(registration_date, 'yyyy-MM') AS month,
       COUNT(*) AS registrations,
       SUM(CASE WHEN validation_status = N'Verified' THEN 1 ELSE 0 END) AS verified
FROM dbo.registrations_validated
GROUP BY FORMAT(registration_date, 'yyyy-MM')
ORDER BY month;

-- 8. Revenue: paid university registrations that passed validation
SELECT region, SUM(fee_amount) AS verified_revenue
FROM dbo.registrations_validated
WHERE registration_type = N'University'
  AND payment_status = N'Paid'
  AND validation_status = N'Verified'
GROUP BY region
ORDER BY verified_revenue DESC;

-- 9. Spot-check fuzzy corrections (eyeball these before trusting the threshold)
SELECT TOP 30 institution_name_entered, institution_name, similarity
FROM dbo.registrations_validated
WHERE match_method = N'Fuzzy'
ORDER BY similarity ASC;

-- 10. Spot-check duplicates: show each duplicate next to the record that was kept
SELECT TOP 30 d.registration_id AS duplicate_id, d.delegate_name, d.email,
       k.registration_id AS kept_id, k.delegate_name AS kept_name, k.email AS kept_email
FROM dbo.registrations_validated d
JOIN dbo.registrations_validated k
  ON k.is_duplicate = 0
 AND k.registration_id <> d.registration_id
 AND ((k.email = d.email AND d.email_ok = 1)
      OR (k.delegate_name = d.delegate_name AND k.institution_id = d.institution_id))
WHERE d.is_duplicate = 1
ORDER BY d.registration_id;

-- 11. Confirmation-email list: verified and paid or free, one row per person
SELECT registration_id, delegate_name, email, institution_name, event_name
FROM dbo.vw_clean_registrations
WHERE payment_status IN (N'Paid', N'Free');