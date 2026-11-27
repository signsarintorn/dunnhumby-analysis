-- 02_eda
-- Purpose : explore and describe the data before answering business questions
-- Source : transaction_clean, product table

-- Weekly sales trend 
-- 2.1 Sales and active households per week 
SELECT week_no,
       ROUND(SUM(sales_value)::numeric, 0) AS sales,
       COUNT(DISTINCT household_key) AS active_households
FROM transactions_clean
GROUP BY week_no
ORDER BY week_no;
-- Result: sales and households rise up from near zeron in weeks 1 to 16 to about 1,300 households per week and sales of 80k - 90k per week

-- 2.2 Basic stats, all weeks
WITH weekly AS (
	SELECT week_no, SUM(sales_value) AS sales, COUNT(DISTINCT household_key) AS households
	FROM transactions_clean
	GROUP BY week_no
)
SELECT v.metric, 
		COUNT(*) AS n_weeks,
		ROUND(MIN(v.value), 0) AS min,
		ROUND(PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY v.value)::numeric,0) AS p25,
		ROUND(PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY v.value)::numeric, 0) AS median,
       ROUND(PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY v.value)::numeric, 0) AS p75,
       ROUND(MAX(v.value), 0) AS max,
       ROUND(AVG(v.value), 0) AS mean,
       ROUND(STDDEV_SAMP(v.value), 0) AS std_dev,
       ROUND(100 * STDDEV_SAMP(v.value) / AVG(v.value), 1) AS cv_pct
FROM weekly
CROSS JOIN LATERAL (VALUES ('sales', sales::numeric),
                           ('households', households::numeric)) AS v(metric, value)
GROUP BY v.metric;

-- Result: sales median 84,937, mean 78,995, cv 26.5% | households median 1,311, mean 1,215, cv 24.0%.
--         Mean below median: a few very low early weeks pull it down. The middle half of weeks
--         varies only about 12%, so the volatility comes from the ramp-up, not normal weeks.

-- 2.3 Basic stat (week 17 onward)
WITH weekly AS (
	SELECT week_no, SUM(sales_value) AS sales, COUNT(DISTINCT household_key) AS households
	FROM transactions_clean
	WHERE week_no >= 17
	GROUP BY week_no
)
SELECT v.metric, 
		COUNT(*) AS n_weeks,
		ROUND(MIN(v.value), 0) AS min,
		ROUND(PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY v.value)::numeric,0) AS p25,
		ROUND(PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY v.value)::numeric, 0) AS median,
       ROUND(PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY v.value)::numeric, 0) AS p75,
       ROUND(MAX(v.value), 0) AS max,
       ROUND(AVG(v.value), 0) AS mean,
       ROUND(STDDEV_SAMP(v.value), 0) AS std_dev,
       ROUND(100 * STDDEV_SAMP(v.value) / AVG(v.value), 1) AS cv_pct
FROM weekly
CROSS JOIN LATERAL (VALUES ('sales', sales::numeric),
                           ('households', households::numeric)) AS v(metric, value)
GROUP BY v.metric;
-- Result: sales median 86,428 (p25 83,011, p75 90,463), mean 86,711, cv 7.7%
--         households median 1,318 (p25 1,293, p75 1,343), cv 3.0%.
-- Decision: weeks 1 to 16 are a panel ramp-up and are excluded from all analysis.

-- 2.4 What drives high-sales and low-sales weeks (traffic, frequency or basket value)
WITH weekly AS (
    SELECT week_no,
           SUM(sales_value) AS sales,
           COUNT(DISTINCT household_key) AS households,
           COUNT(DISTINCT basket_id) AS baskets
    FROM transactions_clean
    WHERE week_no >= 17
    GROUP BY week_no
),
parts AS (
    SELECT week_no,
           sales,
           households,
           baskets::numeric / households AS baskets_per_hh,
           sales::numeric / baskets AS value_per_basket
    FROM weekly
)
SELECT week_no,
       ROUND(sales::numeric, 0) AS sales,
       ROUND(100 * (sales / AVG(sales) OVER () - 1)::numeric, 1) AS sales_vs_avg_pct,
       ROUND(100 * (households / AVG(households) OVER () - 1)::numeric, 1) AS hh_vs_avg_pct,
       ROUND(100 * (baskets_per_hh / AVG(baskets_per_hh) OVER () - 1), 1) AS freq_vs_avg_pct,
       ROUND(100 * (value_per_basket / AVG(value_per_basket) OVER () - 1), 1) AS basket_value_vs_avg_pct
FROM parts
ORDER BY sales DESC
LIMIT 10;
-- Result (top 10): basket value moved most in 8 of 10 weeks. Week 92 stands out at +30.5%.

-- Same query, lowest 10 weeks 
WITH weekly AS (
    SELECT week_no,
           SUM(sales_value) AS sales,
           COUNT(DISTINCT household_key) AS households,
           COUNT(DISTINCT basket_id) AS baskets
    FROM transactions_clean
    WHERE week_no >= 17
    GROUP BY week_no
),
parts AS (
    SELECT week_no,
           sales,
           households,
           baskets::numeric / households AS baskets_per_hh,
           sales::numeric / baskets AS value_per_basket
    FROM weekly
)
SELECT week_no,
       ROUND(sales::numeric, 0) AS sales,
       ROUND(100 * (sales / AVG(sales) OVER () - 1)::numeric, 1) AS sales_vs_avg_pct,
       ROUND(100 * (households / AVG(households) OVER () - 1)::numeric, 1) AS hh_vs_avg_pct,
       ROUND(100 * (baskets_per_hh / AVG(baskets_per_hh) OVER () - 1), 1) AS freq_vs_avg_pct,
       ROUND(100 * (value_per_basket / AVG(value_per_basket) OVER () - 1), 1) AS basket_value_vs_avg_pct
FROM parts
ORDER BY sales ASC
LIMIT 10;
-- Result : basket value moved most in most weeks.
-- The lowest weeks cluster in weeks 18 to 32 and the highest in weeks 92 to 99.

-- 2.5 Is the stable window really flat? Average per 17-week block (weeks 17 to 101)
WITH weekly AS (
    SELECT week_no,
           SUM(sales_value) AS sales,
           COUNT(DISTINCT household_key) AS households,
           COUNT(DISTINCT basket_id) AS baskets
    FROM transactions_clean
    WHERE week_no BETWEEN 17 AND 101
    GROUP BY week_no
)
SELECT MIN(week_no) || '-' || MAX(week_no) AS weeks,
       ROUND(AVG(sales)::numeric, 0) AS avg_sales,
       ROUND(AVG(households), 0) AS avg_households,
       ROUND(AVG(baskets::numeric / households), 2) AS avg_baskets_per_hh,
       ROUND(AVG(sales::numeric / baskets), 2) AS avg_basket_value
FROM weekly
GROUP BY FLOOR((week_no - 17) / 17)
ORDER BY MIN(week_no);
-- Result: 17-33  81,016 | 1,304 households | 2.27 trips | 27.37 per basket
--         34-50  86,186 | 1,301 | 2.23 | 29.65
--         51-67  87,675 | 1,331 | 2.26 | 29.20
--         68-84  87,091 | 1,339 | 2.24 | 29.01
--         85-101 92,453 | 1,341 | 2.17 | 31.71
--  Sales flat in the middle blocks and rising in weeks 85 to 101,
--  with bigger baskets and slightly fewer trips.

-- 2.6 Check if week 102 is partial ?
-- Compare days covered and sales per day
SELECT week_no,
       COUNT(DISTINCT day) AS days_with_sales,
       MIN(day) AS first_day,
       MAX(day) AS last_day,
       ROUND(SUM(sales_value)::numeric, 0) AS sales,
       ROUND(SUM(sales_value)::numeric / COUNT(DISTINCT day), 0) AS sales_per_day
FROM transactions_clean
WHERE week_no >= 96
GROUP BY week_no
ORDER BY week_no;
-- Result: week 102 has 6 days (706 to 711, the end of the data). Sales per day 11,995 vs
--         12,058 to 14,481 in weeks 96 to 101. The lower total reflects the missing day.

-- Product & department mix
-- 2.7 structure 
SELECT * FROM product LIMIT 5;
-- Result: department, commodity_desc and sub_commodity_desc are readable names.
--         brand is only National or Private. Blank sizes are stored as a space.

-- 2.8 Sales per department week 17 to 102
SELECT TRIM(p.department) AS department,
       COUNT(DISTINCT t.product_id) AS products,
       COUNT(*) AS n_rows,
       ROUND(SUM(t.sales_value)::numeric, 0) AS sales,
       ROUND(100 * SUM(t.sales_value)::numeric
             / SUM(SUM(t.sales_value)::numeric) OVER (), 2) AS sales_pct,
       ROUND(SUM(t.sales_value)::numeric / COUNT(*), 2) AS avg_sales_per_row
FROM transactions_clean t
LEFT JOIN product p ON p.product_id = t.product_id
WHERE t.week_no >= 17
GROUP BY 1
ORDER BY sales DESC;
-- Result: 7 of 42 departments hold about 93% of sales (GROCERY about 51%).
--         Non-merchandise departments (KIOSK-GAS 6.99%, MISC SALES TRAN 1.54%, MISC. TRANS. 0.13%
--         and three smaller ones) hold about 8.7% of sales but about 1.2% of line items.
--         Fuel sells at 24.92 per line item vs 2.49 for GROCERY, so it would inflate basket value.

-- 2.9 Product view with non-merchandise flag
CREATE OR REPLACE VIEW product_clean AS
SELECT product_id,
       manufacturer,
       TRIM(department) AS department,
       TRIM(brand) AS brand,
       TRIM(commodity_desc) AS commodity,
       TRIM(sub_commodity_desc) AS sub_commodity,
       NULLIF(TRIM(curr_size_of_product), '') AS size,
       COALESCE(
           TRIM(department) IN ('KIOSK-GAS', 'MISC SALES TRAN', 'MISC. TRANS.',
                                'COUP/STR & MFG', 'POSTAL CENTER', 'CHARITABLE CONT')
           OR TRIM(commodity_desc) IN ('COUPON/MISC ITEMS', 'NO COMMODITY DESCRIPTION')
           OR sub_commodity_desc ILIKE '%GASOLINE%',
           FALSE) AS is_nonmerch
FROM product;

-- 2.9.1 Check what the flag catches 
SELECT department, commodity, COUNT(*) AS products
FROM product_clean
WHERE is_nonmerch
GROUP BY 1, 2
ORDER BY 3 DESC;

--2.9.2 Does non-merch explain the rise in basket value? (17-week blocks, weeks 17 to 101)
WITH t AS (
    SELECT t.week_no,
           t.basket_id,
           t.sales_value,
           COALESCE(p.is_nonmerch, FALSE) AS nonmerch
    FROM transactions_clean t
    LEFT JOIN product_clean p ON p.product_id = t.product_id
    WHERE t.week_no BETWEEN 17 AND 101
)
SELECT MIN(week_no) || '-' || MAX(week_no) AS weeks,
       ROUND(100 * SUM(sales_value) FILTER (WHERE nonmerch)::numeric
             / SUM(sales_value)::numeric, 2) AS nonmerch_sales_pct,
       ROUND(SUM(sales_value)::numeric / COUNT(DISTINCT basket_id), 2) AS basket_value_all,
       ROUND(SUM(sales_value) FILTER (WHERE NOT nonmerch)::numeric
             / COUNT(DISTINCT basket_id) FILTER (WHERE NOT nonmerch), 2) AS basket_value_merch
FROM t
GROUP BY FLOOR((week_no - 17) / 17)
ORDER BY MIN(week_no);

-- Result: non-merchandise share fell from 9.76% (68-84) to 7.97% (85-101), while merchandise
--         basket value rose from 29.05 to 32.13 (+10.6%). Fuel does not explain the rise.
--         Merchandise basket value is close to the all-items value because some baskets contain
--         only non-merchandise.

-- 2.10 Shopping frequency per household, all baskets vs baskets with merchandise
WITH b AS (
    SELECT t.household_key,
           t.basket_id,
           BOOL_OR(NOT COALESCE(p.is_nonmerch, FALSE)) AS has_merch
    FROM transactions_clean t
    LEFT JOIN product_clean p ON p.product_id = t.product_id
    WHERE t.week_no >= 17
    GROUP BY t.household_key, t.basket_id
),
h AS (
    SELECT household_key,
           COUNT(*) AS baskets_all,
           COUNT(*) FILTER (WHERE has_merch) AS baskets_merch
    FROM b
    GROUP BY household_key
)
SELECT COUNT(*) AS households,
       ROUND(100.0 * (SUM(baskets_all) - SUM(baskets_merch)) / SUM(baskets_all), 2) AS nonmerch_only_baskets_pct,
       PERCENTILE_CONT(ARRAY[0.10, 0.25, 0.50, 0.75, 0.90])
           WITHIN GROUP (ORDER BY baskets_merch) AS merch_baskets_p10_p25_p50_p75_p90
FROM h;

-- Result: 2,493 households. 9.19% of baskets contain only non-merchandise (for example a fuel stop).
--         Baskets with merchandise per household: p10 15, p25 32, median 67, p75 120, p90 193.
--         The median household shops about every 9 days, light shoppers about every 40 days,
--         heavy shoppers about every 3 days.
-- Decisions for Q1: count only baskets with merchandise as visits, score frequency by quintile,
--         and judge churn against each household's own rhythm.

-- Campaign and coupon 

-- 2.11 Table  structure
SELECT * FROM campaign_desc LIMIT 5;
SELECT * FROM campaign_table LIMIT 5;
SELECT * FROM coupon LIMIT 5;
SELECT * FROM coupon_redempt LIMIT 5;
-- Result: campaign_desc has type and start and end day per campaign. campaign_table lists
--         targeted households. coupon maps each coupon to many products, so it must not be joined
--         directly to transactions (rows would multiply). coupon_redempt records each redemption.


-- 2.11.1 Check the day-to-week for each campaign
SELECT COUNT(*) AS mismatched_rows
FROM transaction_data
WHERE week_no <> (day + 8) / 7;

-- 2.12 full campaign list with duration and week range
SELECT d.campaign,
       d.description AS type,
       d.start_day,
       d.end_day,
       d.end_day - d.start_day + 1 AS duration_days,
       (d.start_day + 8) / 7 AS start_week,
       (d.end_day + 8) / 7 AS end_week,
       COUNT(DISTINCT ct.household_key) AS households_targeted,
       ROUND(100.0 * COUNT(DISTINCT ct.household_key) / 2500, 1) AS pct_of_panel
FROM campaign_desc d
LEFT JOIN campaign_table ct ON ct.campaign = d.campaign
GROUP BY d.campaign, d.description, d.start_day, d.end_day
ORDER BY d.start_day;
-- Result: 30 campaigns. TypeA (5) reach 13 to 45% of households each. TypeB (19) and TypeC (6)
--         are small, often under 20 households. The first campaign starts in week 33, and from
--         then on campaigns overlap continuously. Weeks 17 to 32 have no campaign at all.
-- Implication: campaign weeks cannot be compared with non-campaign weeks. Q2 compares households.

-- 2.13 Consistency check: redemptions by households not listed as targeted (expect 0 or close)
SELECT COUNT(*) AS redemptions,
       COUNT(*) FILTER (WHERE ct.household_key IS NULL) AS redeemed_without_target
FROM coupon_redempt r
LEFT JOIN campaign_table ct
       ON ct.household_key = r.household_key
      AND ct.campaign = r.campaign;
-- Result: 0 

-- 2.14  Is campaign_table one row per household x campaign? (expect two equal numbers)
SELECT COUNT(*) AS n_rows,
       COUNT(DISTINCT (household_key, campaign)) AS n_household_campaign
FROM campaign_table;
-- Result: No duplicates

-- 2.14.1 Create view: one row per household x campaign with type, dates and number of redemptions.
CREATE OR REPLACE VIEW hh_campaign AS
SELECT ct.household_key,
       ct.campaign,
       d.description AS type,
       d.start_day,
       d.end_day,
       (d.start_day + 8) / 7 AS start_week,
       (d.end_day + 8) / 7 AS end_week,
       COALESCE(r.redemptions, 0) AS redemptions
FROM campaign_table ct
JOIN campaign_desc d ON d.campaign = ct.campaign
LEFT JOIN (SELECT household_key, campaign, COUNT(*) AS redemptions
           FROM coupon_redempt
           GROUP BY household_key, campaign) r
       ON r.household_key = ct.household_key
      AND r.campaign = ct.campaign;

-- 2.15 Coupon redemption overview 
SELECT COUNT(*) AS redemptions,
       COUNT(DISTINCT household_key) AS households_redeemed,
       ROUND(100.0 * COUNT(DISTINCT household_key) / 2500, 1) AS pct_of_panel,
       COUNT(DISTINCT campaign) AS campaigns_with_redemptions,
       ROUND(COUNT(*)::numeric / COUNT(DISTINCT household_key), 1) AS redemptions_per_redeeming_hh
FROM coupon_redempt;
-- Result: 2,318 redemptions by 434 households (17.4%), 5.3 each on average. All 30 campaigns had
--         at least one redemption.
-- Implication: most targeted households never redeem, so campaign impact must be measured
--         through purchases, not redemptions.

-- 2.16 Target vs. actual redeeming households by campaign type
WITH targeted AS (
    SELECT d.description AS type,
           COUNT(DISTINCT ct.household_key) AS hh_targeted
    FROM campaign_table ct
    JOIN campaign_desc d ON d.campaign = ct.campaign
    GROUP BY d.description
),
redeemed AS (
    SELECT d.description AS type,
           COUNT(*) AS redemptions,
           COUNT(DISTINCT r.household_key) AS hh_redeemed
    FROM coupon_redempt r
    JOIN campaign_desc d ON d.campaign = r.campaign
    GROUP BY d.description
)
SELECT t.type,
       t.hh_targeted,
       COALESCE(r.hh_redeemed, 0) AS hh_redeemed,
       ROUND(100.0 * COALESCE(r.hh_redeemed, 0) / t.hh_targeted, 1) AS redeem_rate_pct,
       COALESCE(r.redemptions, 0) AS redemptions
FROM targeted t
LEFT JOIN redeemed r ON r.type = t.type
ORDER BY t.type;
-- Result: TypeA 1,513 targeted, 383 redeemed (25.3%) | TypeB 1,023, 141 (13.8%)
--         TypeC 397, 38 (9.6%). 

-- 2.16.1 were TypeA households already heavier shoppers before any campaign? (Because from 3.5 Type A campaing is being redeemed the most)
WITH typea AS (
    SELECT DISTINCT ct.household_key
    FROM campaign_table ct
    JOIN campaign_desc d ON d.campaign = ct.campaign
    WHERE d.description = 'TypeA'
),
pre AS (
    SELECT t.household_key,
           COUNT(DISTINCT t.basket_id) AS baskets,
           SUM(t.sales_value) AS sales
    FROM transactions_clean t
    LEFT JOIN product_clean p ON p.product_id = t.product_id
    WHERE t.week_no BETWEEN 17 AND 32
      AND NOT COALESCE(p.is_nonmerch, FALSE)
    GROUP BY t.household_key
),
base AS (
    SELECT DISTINCT household_key FROM transactions_clean
)
SELECT (a.household_key IS NOT NULL) AS got_typea,
       COUNT(*) AS households,
       ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY COALESCE(pre.sales, 0))::numeric, 0) AS median_pre_sales,
       ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY COALESCE(pre.baskets, 0))::numeric, 0) AS median_pre_baskets,
       ROUND(100.0 * COUNT(*) FILTER (WHERE pre.household_key IS NULL) / COUNT(*), 1) AS pct_no_pre_purchase
FROM base b
LEFT JOIN typea a ON a.household_key = b.household_key
LEFT JOIN pre ON pre.household_key = b.household_key
GROUP BY 1;

-- Result: later TypeA 1,513 households, median spend 516, 18 trips, 1.3% no purchase
--         others 987 households, median spend 88, 4 trips, 13.1% no purchase.
-- Conclusion: targeting is not random. Targeted households already shopped much more before
--         any campaign, so Q2 measures change from each household's own baseline and compares
--         households with similar baseline spend.