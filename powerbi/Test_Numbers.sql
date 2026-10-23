USE EventRegistrations;

-- A. Status counts: compare with the status bars on Page 1
SELECT s.validation_status, COUNT(*) AS registrations
FROM dbo.fact_registrations f JOIN dbo.dim_status s ON 
s.status_key = f.status_key
GROUP BY s.validation_status;

-- B. Verified revenue: compare with the Verified Revenue card 
SELECT SUM(f.fee_amount) AS verified_revenue
FROM dbo.fact_registrations f JOIN dbo.dim_status s ON 
s.status_key = f.status_key
WHERE f.payment_status = 'Paid' AND s.validation_status = 'Verified';

-- C. Revenue at risk: compare with the Revenue At Risk card on Page 5
SELECT SUM(fee_amount) AS revenue_at_risk
FROM dbo.fact_registrations WHERE payment_status IN ('Pending', 'Failed');

-- D. Countries: compare with the Countries Represented card
SELECT COUNT(DISTINCT country) AS countries FROM dbo.dim_geography WHERE country <> 'Unknown';

-- E. Registrations per month: compare with the Page 4 table
SELECT d.month_num, d.month_name, COUNT(*) AS registrations
FROM dbo.fact_registrations f JOIN dbo.dim_date d ON d.date_key = f.date_key
GROUP BY d.month_num, d.month_name ORDER BY d.month_num;

-- F. One slicer test: select Europe in the Region slicer, then compare
SELECT COUNT(*) AS europe_registrations
FROM dbo.fact_registrations f JOIN dbo.dim_geography g ON g.geo_key = f.geo_key
WHERE g.region = 'Europe';

