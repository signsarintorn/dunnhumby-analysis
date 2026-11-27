-- 01 Data Quality
-- Purpose : check that the loaded data is complete and reliable, decide how to handle abnormal rows, and build the clean views used by every later file.
-- Output:  views transactions_clean (revenue, customers, campaigns) and transactions_basket (basket analysis)
-- Business question: Is the data reliable enough to analyse?

-- 1.1 Row counts after loading
SELECT 'transaction_data' AS tbl, COUNT(*) AS n FROM transaction_data
UNION ALL SELECT 'product', COUNT(*) FROM product
UNION ALL SELECT 'hh_demographic', COUNT(*) FROM hh_demographic
UNION ALL SELECT 'campaign_table', COUNT(*) FROM campaign_table
UNION ALL SELECT 'campaign_desc', COUNT(*) FROM campaign_desc
UNION ALL SELECT 'coupon', COUNT(*) FROM coupon
UNION ALL SELECT 'coupon_redempt', COUNT(*) FROM coupon_redempt;
-- Result: transaction_data 2,595,732 | product 92,353 | hh_demographic 801 | campaign_table 7,208
--         campaign_desc 30 | coupon 124,548 | coupon_redempt 2,318. All match the source files.

-- 1.2 Time range and size
SELECT MIN(day) AS first_day, MAX(day) AS last_day,
       MIN(week_no) AS first_week, MAX(week_no) AS last_week,
       COUNT(DISTINCT household_key) AS households,
       COUNT(DISTINCT basket_id) AS baskets
FROM transaction_data;
-- Result: days 1 to 711, weeks 1 to 102, 2,500 households, 276,484 baskets.
-- Days and weeks are relative numbers, not calendar dates.

-- 1.3 Abnormal rows (zero or negative sales or quantity) 
SELECT COUNT(*) AS bad_rows
FROM transaction_data
WHERE sales_value <= 0 OR quantity <= 0;
-- Result: 18,917 rows (0.73% of all rows).

-- 1.3.1 Classifying those abnormal rows  
SELECT SUM((sales_value < 0)::int) AS neg_sales,
       SUM((sales_value = 0)::int) AS zero_sales,
       SUM((quantity < 0)::int) AS neg_qty,
       SUM((quantity = 0)::int) AS zero_qty
FROM transaction_data;
-- Result: no negative values, so returns are not represented in this dataset.
-- 18,850 are zero sales and 14,466 are zero quantity.

-- 1.3.2 Split abnormal rows by type 
SELECT CASE WHEN sales_value = 0 AND quantity = 0 THEN 'both_zero'
            WHEN sales_value = 0 AND quantity > 0 THEN 'zero_sales_only'
            WHEN quantity = 0 AND sales_value > 0 THEN 'zero_qty_only'
       END AS bad_type,
       COUNT(*) AS n
FROM transaction_data
WHERE sales_value <= 0 OR quantity <= 0
GROUP BY 1
ORDER BY 2 DESC;
-- Result : both_zero = 14,399 , zero_sales_only 4,451 , zero_qty_only 67
-- both_zero rows carry no sale and no item, so they are excluded.
-- zero_qty_only rows (sales with no item) are inconsistent, so they are excluded.
-- zero_sales_only rows may be real items given away, checked below.

SELECT * FROM transaction_data
WHERE sales_value = 0 AND quantity > 0
LIMIT 20;
-- coupon_disc is 0 in these rows, but many have a negative retail_disc.

-- 1.3.3 Do store discounts explain the zero-sales rows?
SELECT CASE WHEN retail_disc < 0 THEN 'retail_disc_applied'
			ELSE 'no_discount_explains_zero'
		END AS reason, 
		COUNT(*) AS n
FROM transaction_data
WHERE sales_value = 0 AND quantity >0
GROUP BY 1 
ORDER BY 2 DESC;
-- Result: retail_disc_applied 3,748 (84%), no_discount_explains_zero 703 (16%).
-- Decision: the 3,748 rows are items sold at no charge under a store discount. They are real
--           items in the basket, so they are kept for basket analysis but not counted as revenue.
--           The 703 rows have no explanation and are excluded.

-- 1.4 Households with demographic data
SELECT COUNT(*) AS hh_with_demo FROM hh_demographic;

-- 1.4.1 hh_without_demo
SELECT COUNT(*) AS hh_total,
       COUNT(d.household_key) AS hh_with_demo,
       COUNT(*) - COUNT(d.household_key) AS hh_without_demo,
       ROUND(100.0 * COUNT(d.household_key) / COUNT(*), 1) AS pct_with_demo
FROM (SELECT DISTINCT household_key FROM transaction_data) t
LEFT JOIN hh_demographic d ON d.household_key = t.household_key;
-- Result: 801 of 2,500 households (32.0%) have demographic data. Column names are anonymised.

-- 1.4.2 Is hh_with_demo representative ? compare the average sales and baskets between hh_with_demo and hh_without_demo 
SELECT (d.household_key IS NOT NULL) AS has_demo,
       COUNT(*) AS households,
       ROUND(AVG(s.total_sales)::numeric, 2) AS avg_sales,
       ROUND(AVG(s.baskets)::numeric, 1) AS avg_baskets
FROM (SELECT household_key,
             SUM(sales_value) AS total_sales,
             COUNT(DISTINCT basket_id) AS baskets
      FROM transaction_data
      GROUP BY household_key) s
LEFT JOIN hh_demographic d ON d.household_key = s.household_key
GROUP BY 1;
-- Result: with demographics 5,615 avg spend, 175.2 baskets | without 2,095 avg spend, 80.1 baskets.

-- 1.4.2.1 Same comparison but using median because the spend is skewed. 
SELECT (d.household_key IS NOT NULL) AS has_demo,
       ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY s.total_sales)::numeric, 2) AS median_sales
FROM (SELECT household_key, SUM(sales_value) AS total_sales
      FROM transaction_data
      GROUP BY household_key) s
LEFT JOIN hh_demographic d ON d.household_key = s.household_key
GROUP BY 1;
-- Result : median with demo 4,676 and without 1.387 (3 times less). Mean and median align.
-- Decision: households with demographics are much heavier shoppers and not representative,
--           so demographics are not used in the analysis.

-- 1.5. Clean views
-- transactions_clean: rows with a real sale and a real item. Used for revenue, customers, campaigns.
CREATE OR REPLACE VIEW transactions_clean AS
SELECT *
FROM transaction_data
WHERE sales_value > 0 AND quantity > 0;

-- transactions_basket keeps items given away under a store discount (1.2.4).
CREATE OR REPLACE VIEW transactions_basket AS
SELECT *
FROM transaction_data
WHERE quantity > 0
  AND (sales_value > 0 OR retail_disc < 0);

-- 1.5.1 Check the views
SELECT (SELECT COUNT(*) FROM transaction_data) AS rows_raw,
       (SELECT COUNT(*) FROM transactions_clean) AS rows_clean,
       (SELECT COUNT(*) FROM transactions_basket) AS rows_basket,
       (SELECT ROUND(SUM(sales_value)::numeric, 2) FROM transaction_data) AS sales_raw,
       (SELECT ROUND(SUM(sales_value)::numeric, 2) FROM transactions_clean) AS sales_clean;
-- Result: rows_clean 2,576,815 , rows_basket 2,580,563 (clean + 3,748 discounted items).
--         Sales differ by 19.28 out of 8,057,463.08, explained by the next query.

SELECT COUNT(*) AS n, ROUND(SUM(sales_value)::numeric, 2) AS total_sales
FROM transaction_data
WHERE quantity = 0 AND sales_value > 0;
-- Result: 67 rows, 19.28 in sales (the zero_qty_only rows) are excluded. 

-- 1.6 Checking the duplicate rows 
SELECT COUNT(*) AS dup_groups
FROM (SELECT household_key, basket_id, product_id, day, trans_time,
             quantity, sales_value, COUNT(*) AS n
      FROM transaction_data
      GROUP BY 1, 2, 3, 4, 5, 6, 7
      HAVING COUNT(*) > 1) d;
-- Result: No duplicate rows. 