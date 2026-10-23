# 📊 Education Event Registration: Data Quality & Analytics

Personal project built on simulated data. It is inspired by a registration-management workflow I handled in a previous role, where verification was done by manually using Excel, Google Sheets, HubSpot and Cvent. No real company, delegate or institution data is used anywhere in this repository.

## 🎯 Business problem

An education-services organisation runs regional events for school and university leaders around the world. Delegates register through two forms:

- a Google Form for schools (free entry)
 a Cvent form for universities (paid entry)
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

## Tech stack

Area	       Tools
Database	   SQL Server 2025 Express, T-SQL, SSMS
Reporting	   Power BI Desktop, DAX

## Dataset (simulated)

- 8,480 registrations across 15 countries and 6 regions, for 7 regional events (January to July)
- A reference table of 450 valid schools and universities
- Errors were injected on purpose to mimic real problems. The full list is in docs/data_dictionary.md
