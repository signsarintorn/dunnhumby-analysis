-- 05 basket analysis
-- Purpose: To answer Q3. What fills larger baskets, and which products are bought together?
-- Source:  transactions_clean, product_clean
-- Scope:   weeks 17 to 101, merchandise only, analysed at commodity level

-- 5.1 Which commodities drive the rise in basket value? (weeks 68 to 84 vs 85 to 101)
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
             / SUM(per_basket_recent - per_basket_before) OVER ())::numeric, 1) AS pct_of_increase
FROM d
ORDER BY change DESC
LIMIT 15;
-- Result: top 15 commodities account for about 47% of the rise. Almost all are holiday or winter
--         items: soup 5.3%, turkey 3.8%, cheese 3.6%, milk 3.6%, Christmas seasonal 3.5%,
--         smoked meats, cold and flu, packaged candy, baking needs, citrus, wine.
--         Christmas seasonal grew about 16 times (0.007 to 0.114 per basket).
--         The rest of the rise is spread across many commodities.

-- 5.1.1 Seasonality check: weekly sales of holiday and winter commodities (all weeks)
-- If the rise is seasonal, peaks should appear about 52 weeks apart.
SELECT t.week_no,
       ROUND(SUM(t.sales_value) FILTER (WHERE p.commodity ILIKE '%CHRISTMAS%')::numeric, 0) AS christmas,
       ROUND(SUM(t.sales_value) FILTER (WHERE p.commodity = 'TURKEY')::numeric, 0) AS turkey,
       ROUND(SUM(t.sales_value) FILTER (WHERE p.commodity = 'BAKING NEEDS')::numeric, 0) AS baking,
       ROUND(SUM(t.sales_value) FILTER (WHERE p.commodity = 'COLD AND FLU')::numeric, 0) AS cold_flu
FROM transactions_clean t
JOIN product_clean p ON p.product_id = t.product_id
GROUP BY t.week_no
ORDER BY t.week_no;
-- Result: peaks exactly 52 weeks apart. Turkey peaks in weeks 35 and 87 (Thanksgiving),
--         Christmas items in weeks 40 and 92 (Christmas), baking in weeks 39 and 92.
--         Cold and flu products rise in the weeks after each holiday.
--         Week 92, the highest sales week in the data, is most likely Christmas, so weeks 85 to 101
--         cover roughly November to February.
-- Conclusion: the late rise in sales is the holiday season, not new growth. A similar rise appears
--         a year earlier (weeks 34 to 50).
-- This changed earlier work: the business trigger, the reading of 02_eda.sql 1.5, and the
--         baseline for weekly comparisons (now regular weeks 50 to 84).

-- 5.2 Commodity pairs bought together (weeks 17 to 101, merchandise only)
-- Support: share of all baskets that contain both.
-- Confidence: share of baskets with one item that also contain the other. It has two directions
--             and does not show which item was picked first.
-- Lift: how many times more often the two appear together than if they were unrelated
--       (1 = no link).
WITH bc AS (
    SELECT DISTINCT t.basket_id, p.commodity
    FROM transactions_basket t
    JOIN product_clean p ON p.product_id = t.product_id
    WHERE t.week_no BETWEEN 17 AND 101
      AND NOT p.is_nonmerch
),
n AS (
    SELECT COUNT(DISTINCT basket_id) AS total_baskets FROM bc
),
single AS (
    SELECT commodity, COUNT(*) AS baskets
    FROM bc
    GROUP BY commodity
),
pairs AS (
    SELECT a.commodity AS commodity_a,
           b.commodity AS commodity_b,
           COUNT(*) AS baskets_both
    FROM bc a
    JOIN bc b ON b.basket_id = a.basket_id
             AND b.commodity > a.commodity
    GROUP BY a.commodity, b.commodity
    HAVING COUNT(*) >= 500
)
SELECT pr.commodity_a,
       pr.commodity_b,
       pr.baskets_both,
       ROUND(100.0 * pr.baskets_both / n.total_baskets, 2) AS support_pct,
       ROUND(100.0 * pr.baskets_both / sa.baskets, 1) AS conf_a_to_b_pct,
       ROUND(100.0 * pr.baskets_both / sb.baskets, 1) AS conf_b_to_a_pct,
       ROUND(pr.baskets_both::numeric * n.total_baskets / (sa.baskets::numeric * sb.baskets), 2) AS lift
FROM pairs pr
JOIN single sa ON sa.commodity = pr.commodity_a
JOIN single sb ON sb.commodity = pr.commodity_b
CROSS JOIN n
ORDER BY lift DESC
LIMIT 20;
-- Result: the most strongly linked pairs are items used together: cat food and cat litter
--         (lift 16.4), baby food and infant formula (16.3), baby care and diapers (15.0), laundry
--         detergent and additives (12.6). They are niche, each in under 1% of baskets.
--         Confidence is often low in one direction because one item is bought less often
--         (43% of litter baskets have cat food, but only 20% of cat food baskets have litter).
--         Pasta and sauce (lift 9.7, 2.6% of baskets) and deli cheese and deli meats (9.2, 2.9%)
--         stand out as both strongly linked and frequent.

-- 5.2.1 What are the FROZEN and REFRIGERATED commodities at the top of 5.2?
SELECT DISTINCT department, commodity FROM product_clean
WHERE commodity IN ('FROZEN', 'REFRIGERATED');
-- Result: both sit in the NUTRITION department, likely health food freezer and chiller sections.

--  5.2.2 Frequent commodity pairs that are still clearly linked (lift of at least 2)
WITH bc AS (
    SELECT DISTINCT t.basket_id, p.commodity
    FROM transactions_basket t
    JOIN product_clean p ON p.product_id = t.product_id
    WHERE t.week_no BETWEEN 17 AND 101
      AND NOT p.is_nonmerch
),
n AS (
    SELECT COUNT(DISTINCT basket_id) AS total_baskets FROM bc
),
single AS (
    SELECT commodity, COUNT(*) AS baskets
    FROM bc
    GROUP BY commodity
),
pairs AS (
    SELECT a.commodity AS commodity_a,
           b.commodity AS commodity_b,
           COUNT(*) AS baskets_both
    FROM bc a
    JOIN bc b ON b.basket_id = a.basket_id
             AND b.commodity > a.commodity
    GROUP BY a.commodity, b.commodity
    HAVING COUNT(*) >= 500
)
SELECT pr.commodity_a,
       pr.commodity_b,
       pr.baskets_both,
       ROUND(100.0 * pr.baskets_both / n.total_baskets, 2) AS support_pct,
       ROUND(100.0 * pr.baskets_both / sa.baskets, 1) AS conf_a_to_b_pct,
       ROUND(100.0 * pr.baskets_both / sb.baskets, 1) AS conf_b_to_a_pct,
       ROUND(pr.baskets_both::numeric * n.total_baskets / (sa.baskets::numeric * sb.baskets), 2) AS lift
FROM pairs pr
JOIN single sa ON sa.commodity = pr.commodity_a
JOIN single sb ON sb.commodity = pr.commodity_b
CROSS JOIN n
WHERE pr.baskets_both::numeric * n.total_baskets / (sa.baskets::numeric * sb.baskets) >= 2
ORDER BY pr.baskets_both DESC
LIMIT 20;
-- Result: all top 20 are everyday staples (bread, cheese, milk, eggs, beef), each pair in 4 to 10%
--         of baskets, but lift is only 2.0 to 3.0. Part of this comes from large shopping trips
--         that contain many staples at once. Some reflect clear meals: 67% of cereal baskets
--         contain milk, 57% of lunchmeat baskets contain bread.
-- Implication: these pairs already sell together without promotion. They suit shelf placement,
--         not bundle discounts.

-- 5.2.3 Linked pairs (lift of at least 4) sorted by number of baskets
WITH bc AS (
    SELECT DISTINCT t.basket_id, p.commodity
    FROM transactions_basket t
    JOIN product_clean p ON p.product_id = t.product_id
    WHERE t.week_no BETWEEN 17 AND 101
      AND NOT p.is_nonmerch
),
n AS (
    SELECT COUNT(DISTINCT basket_id) AS total_baskets FROM bc
),
single AS (
    SELECT commodity, COUNT(*) AS baskets
    FROM bc
    GROUP BY commodity
),
pairs AS (
    SELECT a.commodity AS commodity_a,
           b.commodity AS commodity_b,
           COUNT(*) AS baskets_both
    FROM bc a
    JOIN bc b ON b.basket_id = a.basket_id
             AND b.commodity > a.commodity
    GROUP BY a.commodity, b.commodity
    HAVING COUNT(*) >= 500
)
SELECT pr.commodity_a,
       pr.commodity_b,
       pr.baskets_both,
       ROUND(100.0 * pr.baskets_both / n.total_baskets, 2) AS support_pct,
       ROUND(100.0 * pr.baskets_both / sa.baskets, 1) AS conf_a_to_b_pct,
       ROUND(100.0 * pr.baskets_both / sb.baskets, 1) AS conf_b_to_a_pct,
       ROUND(pr.baskets_both::numeric * n.total_baskets / (sa.baskets::numeric * sb.baskets), 2) AS lift
FROM pairs pr
JOIN single sa ON sa.commodity = pr.commodity_a
JOIN single sb ON sb.commodity = pr.commodity_b
CROSS JOIN n
WHERE pr.baskets_both::numeric * n.total_baskets / (sa.baskets::numeric * sb.baskets) >= 4
ORDER BY pr.baskets_both DESC
LIMIT 20;
-- Result: pairs form recognisable shopping missions: pantry cooking (canned vegetables with pasta,
--         beans, rice, dinner mixes), fresh cooking (onions, tomatoes, potatoes), salads, deli,
--         breakfast and paper goods. Some canned-food pairs likely reflect stock-up trips.
-- Cross-sell candidates (frequent, strongly linked, used up at the same pace, room to grow):
--         pasta and pasta sauce 5,875 baskets, lift 9.7, 54% of pasta baskets have no sauce
--         deli cheese and deli meats 6,543, lift 9.2, 58% of deli meat baskets have no cheese
--         salad mix and dressing 4,012, lift 4.3, 72% of salad mix baskets have no dressing
--         dinner mixes and shelf-stable meat 3,789, lift 5.5, 69% of dinner mix baskets have no meat

-- 5.2.4 Linked pairs in the holiday period (weeks 85 to 92), lift of at least 4
WITH bc AS (
    SELECT DISTINCT t.basket_id, p.commodity
    FROM transactions_basket t
    JOIN product_clean p ON p.product_id = t.product_id
    WHERE t.week_no BETWEEN 85 AND 92
      AND NOT p.is_nonmerch
),
n AS (
    SELECT COUNT(DISTINCT basket_id) AS total_baskets FROM bc
),
single AS (
    SELECT commodity, COUNT(*) AS baskets
    FROM bc
    GROUP BY commodity
),
pairs AS (
    SELECT a.commodity AS commodity_a,
           b.commodity AS commodity_b,
           COUNT(*) AS baskets_both
    FROM bc a
    JOIN bc b ON b.basket_id = a.basket_id
             AND b.commodity > a.commodity
    GROUP BY a.commodity, b.commodity
    HAVING COUNT(*) >= 100
)
SELECT pr.commodity_a,
       pr.commodity_b,
       pr.baskets_both,
       ROUND(100.0 * pr.baskets_both / n.total_baskets, 2) AS support_pct,
       ROUND(100.0 * pr.baskets_both / sa.baskets, 1) AS conf_a_to_b_pct,
       ROUND(100.0 * pr.baskets_both / sb.baskets, 1) AS conf_b_to_a_pct,
       ROUND(pr.baskets_both::numeric * n.total_baskets / (sa.baskets::numeric * sb.baskets), 2) AS lift
FROM pairs pr
JOIN single sa ON sa.commodity = pr.commodity_a
JOIN single sb ON sb.commodity = pr.commodity_b
CROSS JOIN n
WHERE pr.baskets_both::numeric * n.total_baskets / (sa.baskets::numeric * sb.baskets) >= 4
ORDER BY pr.baskets_both DESC
LIMIT 20;

-- Result: the main shopping missions stay the same in the holiday weeks, with similar lift and
--         support, so the cross-sell candidates in 5.2.3 apply all year.
--         Two holiday-specific groups appear: baking (baking needs with sugar and baking mixes,
--         lift 4.3 to 4.8) and large holiday meals (gravy with canned vegetables, lift 5.2,
--         beef with pork, lift 4.0).
--         Turkey forms no strong one-to-one pair, since it sits in large baskets with many items.

-- Q3 summary
-- 1. Bigger baskets in weeks 85 to 101 are seasonal: holiday and winter items drive about half of
--    the rise, and the same items peak 52 weeks apart.
-- 2. Everyday staples are often bought together but only loosely linked (lift 2 to 3). They suit
--    shelf placement, not bundle discounts. [both items are already popular, contributing the discount on them would make us lose the money]
-- 3. Best cross-sell candidates: pasta and sauce, deli cheese and meats, salad mix and dressing,
--    dinner mixes and shelf-stable meat.
-- 4. Baking and holiday meal items suit seasonal displays before Thanksgiving and Christmas.
-- 5. Basket data shows association, not cause. Bundles should be tested with a holdout group.
