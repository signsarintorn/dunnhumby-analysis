-- 06 dashboard tables 
-- Purpose: small summary tables for the Power BI dashboard (Import mode).

-- 6.1 Weekly sales with period labels (all weeks, merchandise only)
-- Panel ramp-up (1 to 16): households still joining, not comparable
-- Early weeks (17 to 32): stable but still settling, not used as baseline
-- Holiday season (33 to 49 and 85 to 101): seasonal peak that repeats each year (05 5.1b)
-- Regular (50 to 84): normal trading weeks, used as the baseline
-- Partial week (102): the data ends after 6 days
DROP TABLE IF EXISTS dash_weekly;
CREATE TABLE dash_weekly AS
WITH b AS (
    SELECT t.week_no,
           t.household_key,
           t.basket_id,
           SUM(t.sales_value) AS sales
    FROM transactions_clean t
    LEFT JOIN product_clean p ON p.product_id = t.product_id
    WHERE NOT COALESCE(p.is_nonmerch, FALSE)
    GROUP BY t.week_no, t.household_key, t.basket_id
)
SELECT week_no,
       ROUND(SUM(sales)::numeric, 2) AS sales,
       COUNT(DISTINCT household_key) AS households,
       COUNT(*) AS baskets,
       ROUND(SUM(sales)::numeric / COUNT(*), 2) AS basket_value,
       CASE WHEN week_no <= 16 THEN 'Panel ramp-up'
            WHEN week_no BETWEEN 17 AND 32 THEN 'Early weeks'
            WHEN week_no = 102 THEN 'Partial week'
            WHEN week_no BETWEEN 33 AND 49 OR week_no BETWEEN 85 AND 101 THEN 'Holiday season'
            ELSE 'Regular' END AS period
FROM b
GROUP BY week_no
ORDER BY week_no;

-- 6.2 One row per household: RFM, segment, churn risk, campaign and coupon flags
DROP TABLE IF EXISTS dash_households;
CREATE TABLE dash_households AS
WITH camp AS (
    SELECT household_key,
           COUNT(*) AS campaigns_received,
           BOOL_OR(type = 'TypeA') AS got_typea,
           BOOL_OR(type = 'TypeB') AS got_typeb,
           BOOL_OR(type = 'TypeC') AS got_typec,
           SUM(redemptions) AS coupon_redemptions
    FROM hh_campaign
    GROUP BY household_key
)
SELECT r.household_key,
       r.segment,
       r.rhythm_status,
       r.r_score,
       r.f_score,
       r.m_score,
       r.fm_score,
       r.recency_days,
       r.frequency,
       r.monetary,
       r.avg_gap_days,
       r.gap_ratio,
       COALESCE(c.campaigns_received, 0) AS campaigns_received,
       COALESCE(c.got_typea, FALSE) AS got_typea,
       COALESCE(c.got_typeb, FALSE) AS got_typeb,
       COALESCE(c.got_typec, FALSE) AS got_typec,
       COALESCE(c.coupon_redemptions, 0) AS coupon_redemptions
FROM hh_churn_risk r
LEFT JOIN camp c ON c.household_key = r.household_key;
-- 6.2.1 Check: household count and campaign flags
SELECT COUNT(*) AS households,                                       
       COUNT(*) FILTER (WHERE campaigns_received > 0) AS any_campaign,
       COUNT(*) FILTER (WHERE got_typea) AS typea,                   
       SUM(coupon_redemptions) AS redemptions                         
FROM dash_households;

-- 6.3 Basket value change by commodity (weeks 68 to 84 vs 85 to 101), all commodities
DROP TABLE IF EXISTS dash_basket_drivers;
CREATE TABLE dash_basket_drivers AS
WITH t AS (
    SELECT t.basket_id,
           p.department,
           p.commodity,
           t.sales_value,
           CASE WHEN t.week_no BETWEEN 68 AND 84 THEN 'before' ELSE 'recent' END AS period
    FROM transactions_clean t
    JOIN product_clean p ON p.product_id = t.product_id
    WHERE t.week_no BETWEEN 68 AND 101
      AND NOT p.is_nonmerch
),
n AS (
    SELECT COUNT(DISTINCT basket_id) FILTER (WHERE period = 'before') AS baskets_before,
           COUNT(DISTINCT basket_id) FILTER (WHERE period = 'recent') AS baskets_recent
    FROM t
),
c AS (
    SELECT department,
           commodity,
           SUM(sales_value) FILTER (WHERE period = 'before') AS sales_before,
           SUM(sales_value) FILTER (WHERE period = 'recent') AS sales_recent
    FROM t
    GROUP BY department, commodity
),
d AS (
    SELECT c.department,
           c.commodity,
           COALESCE(c.sales_before, 0) / n.baskets_before AS per_basket_before,
           COALESCE(c.sales_recent, 0) / n.baskets_recent AS per_basket_recent
    FROM c CROSS JOIN n
)
SELECT department,
       commodity,
       ROUND(per_basket_before::numeric, 3) AS per_basket_before,
       ROUND(per_basket_recent::numeric, 3) AS per_basket_recent,
       ROUND((per_basket_recent - per_basket_before)::numeric, 3) AS change,
       ROUND((100 * (per_basket_recent - per_basket_before)
             / SUM(per_basket_recent - per_basket_before) OVER ())::numeric, 2) AS pct_of_increase
FROM d;

-- 6.3.1 Check sums should match 5.3.1 (about 29.05 and 32.13)
SELECT SUM(per_basket_before) AS before, SUM(per_basket_recent) AS recent FROM dash_basket_drivers;

-- 6.4 Commodity pairs for all year (weeks 17 to 101) and holiday (weeks 85 to 92), lift of at least 2
-- pair_type: Cross-sell candidate = lift 4 or more and in at least 1% of baskets
--            Strong but niche = lift 4 or more, under 1% of baskets
--            Loosely linked = lift 2 to 4
DROP TABLE IF EXISTS dash_pairs;
CREATE TABLE dash_pairs AS
WITH bc AS (
    SELECT DISTINCT 'All year' AS period, t.basket_id, p.commodity
    FROM transactions_basket t
    JOIN product_clean p ON p.product_id = t.product_id
    WHERE t.week_no BETWEEN 17 AND 101
      AND NOT p.is_nonmerch
    UNION ALL
    SELECT DISTINCT 'Holiday', t.basket_id, p.commodity
    FROM transactions_basket t
    JOIN product_clean p ON p.product_id = t.product_id
    WHERE t.week_no BETWEEN 85 AND 92
      AND NOT p.is_nonmerch
),
n AS (
    SELECT period, COUNT(DISTINCT basket_id) AS total_baskets
    FROM bc
    GROUP BY period
),
single AS (
    SELECT period, commodity, COUNT(*) AS baskets
    FROM bc
    GROUP BY period, commodity
),
pairs AS (
    SELECT a.period,
           a.commodity AS commodity_a,
           b.commodity AS commodity_b,
           COUNT(*) AS baskets_both
    FROM bc a
    JOIN bc b ON b.period = a.period
             AND b.basket_id = a.basket_id
             AND b.commodity > a.commodity
    GROUP BY a.period, a.commodity, b.commodity
    HAVING COUNT(*) >= CASE WHEN a.period = 'Holiday' THEN 100 ELSE 500 END
),
m AS (
    SELECT pr.period,
           pr.commodity_a,
           pr.commodity_b,
           pr.baskets_both,
           n.total_baskets,
           sa.baskets AS baskets_a,
           sb.baskets AS baskets_b,
           pr.baskets_both::numeric * n.total_baskets / (sa.baskets::numeric * sb.baskets) AS lift
    FROM pairs pr
    JOIN n ON n.period = pr.period
    JOIN single sa ON sa.period = pr.period AND sa.commodity = pr.commodity_a
    JOIN single sb ON sb.period = pr.period AND sb.commodity = pr.commodity_b
)
SELECT period,
       commodity_a,
       commodity_b,
       baskets_both,
       ROUND(100.0 * baskets_both / total_baskets, 2) AS support_pct,
       ROUND(100.0 * baskets_both / baskets_a, 1) AS conf_a_to_b_pct,
       ROUND(100.0 * baskets_both / baskets_b, 1) AS conf_b_to_a_pct,
       ROUND(lift, 2) AS lift,
       CASE WHEN lift >= 4 AND 100.0 * baskets_both / total_baskets >= 1 THEN 'Cross-sell candidate'
            WHEN lift >= 4 THEN 'Strong but niche'
            ELSE 'Loosely linked' END AS pair_type
FROM m
WHERE lift >= 2;



-- 6.4.1 Check: pairs per period and type
SELECT period, pair_type, COUNT(*) AS pairs
FROM dash_pairs
GROUP BY period, pair_type
ORDER BY period, pair_type;

-- Baseline check: regular weeks 50 to 84 vs holiday season 85 to 101 (all sales)
SELECT ROUND(AVG(sales) FILTER (WHERE week_no BETWEEN 50 AND 84), 0) AS regular_avg,
       ROUND(AVG(sales) FILTER (WHERE week_no BETWEEN 85 AND 101), 0) AS holiday_avg,
       ROUND(100 * (AVG(sales) FILTER (WHERE week_no BETWEEN 85 AND 101)
                  / AVG(sales) FILTER (WHERE week_no BETWEEN 50 AND 84) - 1), 1) AS uplift_pct
FROM (SELECT week_no, SUM(sales_value)::numeric AS sales
      FROM transactions_clean
      GROUP BY week_no) w;

-- 6.5 Weekly sales of four seasonal commodities (all weeks, zero-filled)
DROP TABLE IF EXISTS dash_seasonal;
CREATE TABLE dash_seasonal AS
WITH grp AS (
    SELECT t.week_no,
           CASE WHEN p.commodity ILIKE '%CHRISTMAS%' THEN 'Christmas seasonal'
                WHEN p.commodity = 'TURKEY' THEN 'Turkey'
                WHEN p.commodity = 'BAKING NEEDS' THEN 'Baking needs'
                WHEN p.commodity = 'COLD AND FLU' THEN 'Cold and flu' END AS commodity_group,
           t.sales_value
    FROM transactions_clean t
    JOIN product_clean p ON p.product_id = t.product_id
    WHERE p.commodity ILIKE '%CHRISTMAS%'
       OR p.commodity IN ('TURKEY', 'BAKING NEEDS', 'COLD AND FLU')
),
weeks AS (
    SELECT generate_series(1, 102) AS week_no
),
groups AS (
    SELECT DISTINCT commodity_group FROM grp
)
SELECT w.week_no,
       g.commodity_group,
       COALESCE(ROUND(SUM(grp.sales_value)::numeric, 0), 0) AS sales
FROM weeks w
CROSS JOIN groups g
LEFT JOIN grp ON grp.week_no = w.week_no AND grp.commodity_group = g.commodity_group
GROUP BY w.week_no, g.commodity_group
ORDER BY g.commodity_group, w.week_no;

-- 6.5.1 Check: 102 weeks x 4 groups
SELECT COUNT(*) FROM dash_seasonal;