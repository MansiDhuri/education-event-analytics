# 📊 Education Event Registration: Data Quality & Analytics

Personal project built on simulated data. It is inspired by a registration-management workflow I handled in a previous role, where verification was done by manually using Excel, Google Sheets, HubSpot and Cvent. No real company, delegate or institution data is used anywhere in this repository.

## 🎯 Business problem

An education-services organisation runs regional events for school and university leaders around the world. Delegates register through two forms:

- a Google Form for schools (free entry)
- a Cvent form for universities (paid entry)
  
The incoming data is messy: misspelled institution names, institutions that do not exist, invalid emails and phone numbers, inconsistent country names, and people who register more than once. Before confirmation emails go out, each registration has to be cleaned and verified. At my previous employer this was manual work.

## 🏢 What this project does

I rebuilt that workflow with SQL Server (T-SQL) and Power BI to show how it can be automated, measured and reported:

- Loads raw registrations into SQL Server and never modifies the raw table.
- Standardizes text, countries, phones and types in a staging table.
- Verifies institutions against a reference list: exact match first, then fuzzy match using a Levenshtein distance function.
- Validates names, emails, phone numbers, fees and registration type.
- Detects duplicates with window functions (ROW_NUMBER() OVER (PARTITION BY ...)).
- Classifies every registration as Verified, Needs Review or Rejected, with a stated reason.
- Models the result as a star schema and reports on it in a 5-page Power BI dashboard.

raw_registrations  ->  stg_registrations  ->  registrations_validated  ->  star schema  ->  Power BI
   (untouched)          (standardised)         (matched, validated,       (1 fact +          (5 pages)
                                                deduplicated, status)      6 dimensions)

## 💻 Tech stack

| Area | Tools |
|---|---|
| Database | SQL Server 2025 Express, T-SQL, SSMS |
| Reporting | Power BI Desktop, DAX |

## 🗂️ Dataset (simulated)

- 8,480 registrations across 15 countries and 6 regions, for 7 regional events (January to July)
- A reference table of 450 valid schools and universities
- Errors were injected on purpose to mimic real problems. The full list is in docs/data_dictionary.md

## 🔍 Injected data-quality problems and handling

| Injected problem | Handled by |
|---|---|
| Institution name typos and abbreviations | Standardisation and fuzzy matching |
| Institutions that do not exist | Reference-table check |
| School registered on the university form, or the reverse | Type consistency check |
| Invalid emails (missing `@`, `test@test.com`, blank) | Pattern check and domain blocklist |
| Invalid phone numbers | Length check per country |
| Inconsistent country spellings (USA, US, UK, UAE) | Country mapping table |
| Missing city, country or region | Lookup from reference data |
| Duplicate registrations | Window-function duplicate detection |

## ⚙️ SQL Pipeline

| Script | What it does |
|---|---|
| 01_setup_and_profile.sql | Creates the database and raw tables, loads the CSVs, profiles the raw data |
| 02_standardize.sql | 	Lookup tables, helper functions (clean text, proper case, Levenshtein), staging table |
| 03_match_and_validate.sql | Institution matching, validation flags, duplicates, final status and reasons |
| 04_quality_checks.sql | 	Reconciliation and quality queries |
| 05_star_schema.sql | Dimension and fact tables for Power BI |

## 📋 How a registration gets its status

| Status | Assigned when |
|---|---|
| Rejected | Duplicate registration, institution not found, invalid email, or failed payment |
| Needs Review | Institution name corrected by fuzzy match, type mismatch, invalid phone, incomplete name, missing location, fee not matching type, or payment pending |
| Verified | None of the above |

Institutions are matched on name and country, because the same name can exist in more than one country. The fuzzy-match threshold is a similarity of 0.85 or higher. The earliest registration is kept and later copies are marked as duplicates. Nothing is deleted, so every decision can be traced.

## 🗃️ Data model

A star schema with one fact table and six dimensions:
fact_registrations joined to dim_date, dim_geography, dim_institution, dim_event, dim_registration_type and dim_status.

## 📈 Power BI dashboard

Five pages: Executive overview, Data quality, Geography, Trends and Operations. They use more than 20 DAX measures, including data quality rate, duplicate rate, verified revenue, revenue at risk, month-over-month growth and year-to-date.

Executive overview Data quality Geography Trends Operations

### 1. Education Event Overview
<img width="940" height="452" alt="image" src="https://github.com/user-attachments/assets/958d798c-e399-43c3-bd1c-6f1ee9225f1b" />

### 2. Data Quality
<img width="940" height="469" alt="image" src="https://github.com/user-attachments/assets/660cb661-1a8c-416c-bf17-601d8b714ceb" />

### 3. Geography
<img width="940" height="475" alt="image" src="https://github.com/user-attachments/assets/bfb1ed42-65e5-46be-a9c7-985331da6d70" />

### 4. Trends
<img width="940" height="483" alt="image" src="https://github.com/user-attachments/assets/cf18c7b4-0653-4929-bf3e-4e502e192c5b" />

### 5. Operations
<img width="940" height="488" alt="image" src="https://github.com/user-attachments/assets/f809a0cf-e308-4ea2-872e-c0ea6c9c2197" />

## 💡Key results

These figures come from the simulated dataset, so they describe how the data was generated, not a real organisation.

| Measure | 	Result |
|---|---|
| Total registrations | 8,480 |
| Verified | 55% |
| Needs Review | 14% |
| Rejected | 14% |
| Duplicates flagged | 585 |
| Institution names corrected by fuzzy matching | 360|
| Invalid emails | 7.1% |
| Verified revenue (paid and verified university registrations) | 652K |

## 🚀 Limitations and next steps

- The data is simulated, so the percentages are not real-world benchmarks.
- Institution verification uses a reference table. A production version would use an authoritative institution database.
- Duplicate detection can flag two different people who share a name, institution and country. In a real system these would go to review rather than be rejected.
- Next steps: stored procedures to run the pipeline in one call, a scheduled refresh, and row-level security by region in the Power BI service.

## 📚 Skills demonstrated

T-SQL, data cleaning and validation, fuzzy matching, window functions, CTEs, views, dimensional modelling (star schema), Power BI, DAX, data quality reporting, documentation.

## 👩‍💻 About me

Mansi Dhuri
