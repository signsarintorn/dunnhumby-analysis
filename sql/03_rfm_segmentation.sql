-- 03 RFM Segmentation Analysis 
-- Purpose: Q1. Which households drive revenue, and which are at risk of leaving?
-- Source: transactions_clean, product_clean (see 01_data_quality.sql, 02_eda.sql)
-- Scope: weeks 17 to 102, merchandise only (non-merch excluded, see EDA 3.4)
-- Design notes from EDA:
--   Frequency counts only baskets with merchandise (9% of baskets are non-merch only)
--   Scores use quintiles, since frequency is heavily skewed (p10 = 15, p90 = 193) ให้คะเเนนตาม Percentiles
--   Churn risk is judged against each household's own gap between trips (H6) เทียบ benchmark ตัวเอง คือ เฉลี่ยมาทุกกี่วัน 

-- 3.1 Household base: recency, frequency, monatary and usual gap between the trips
CREATE OR REPLACE VIEW hh_rfm_base AS
WITH b AS (
    SELECT t.household_key,
           t.basket_id,
           MIN(t.day) AS day,
           SUM(t.sales_value) FILTER (WHERE NOT COALESCE(p.is_nonmerch, FALSE)) AS merch_sales
    FROM transactions_clean t
    LEFT JOIN product_clean p ON p.product_id = t.product_id
    WHERE t.week_no >= 17
    GROUP BY t.household_key, t.basket_id
)
SELECT household_key,
       COUNT(*) AS frequency,
       ROUND(SUM(merch_sales)::numeric, 2) AS monetary,
       MIN(day) AS first_day,
       MAX(day) AS last_day,
       (SELECT MAX(day) FROM transaction_data) - MAX(day) AS recency_days,
       ROUND((MAX(day) - MIN(day))::numeric / NULLIF(COUNT(*) - 1, 0), 1) AS avg_gap_days
FROM b
WHERE merch_sales > 0
GROUP BY household_key;


-- 3.2 Sanity check: frequency percentiles should match 8.5 ({15,32,67,120,193})
SELECT COUNT(*) AS households,
       PERCENTILE_CONT(ARRAY[0.10, 0.25, 0.50, 0.75, 0.90])
           WITHIN GROUP (ORDER BY frequency) AS freq_pctiles,
       PERCENTILE_CONT(ARRAY[0.10, 0.25, 0.50, 0.75, 0.90])
           WITHIN GROUP (ORDER BY recency_days) AS recency_pctiles,
       PERCENTILE_CONT(ARRAY[0.10, 0.25, 0.50, 0.75, 0.90])
           WITHIN GROUP (ORDER BY monetary) AS monetary_pctiles
FROM hh_rfm_base;
-- Result: 2,492 households, frequency {15, 32.75, 67, 120, 193}.
--         One household fewer than 2.5: household 1727 made a single non-merchandise purchase
--         after week 17, so it has no merchandise trips. p25 moves from 32 to 32.75 because of
--         interpolation with one fewer household. The view is correct.
--         Recency {0, 2, 6, 20, 62} days. Monetary {309, 804, 1,873, 3,756, 6,144}.

-- 3.3 RFM scores 1 to 5 by quintile cut-offs (ties always get the same score)
CREATE OR REPLACE VIEW hh_rfm_scores AS
WITH cuts AS (
    SELECT PERCENTILE_CONT(ARRAY[0.2, 0.4, 0.6, 0.8]) WITHIN GROUP (ORDER BY recency_days) AS r,
           PERCENTILE_CONT(ARRAY[0.2, 0.4, 0.6, 0.8]) WITHIN GROUP (ORDER BY frequency) AS f,
           PERCENTILE_CONT(ARRAY[0.2, 0.4, 0.6, 0.8]) WITHIN GROUP (ORDER BY monetary) AS m
    FROM hh_rfm_base
)
SELECT b.*,
       CASE WHEN b.recency_days <= c.r[1] THEN 5
            WHEN b.recency_days <= c.r[2] THEN 4
            WHEN b.recency_days <= c.r[3] THEN 3
            WHEN b.recency_days <= c.r[4] THEN 2
            ELSE 1 END AS r_score,
       CASE WHEN b.frequency <= c.f[1] THEN 1
            WHEN b.frequency <= c.f[2] THEN 2
            WHEN b.frequency <= c.f[3] THEN 3
            WHEN b.frequency <= c.f[4] THEN 4
            ELSE 5 END AS f_score,
       CASE WHEN b.monetary <= c.m[1] THEN 1
            WHEN b.monetary <= c.m[2] THEN 2
            WHEN b.monetary <= c.m[3] THEN 3
            WHEN b.monetary <= c.m[4] THEN 4
            ELSE 5 END AS m_score
FROM hh_rfm_base b
CROSS JOIN cuts c;

-- 3.3.1 Check: how many households per score (expect roughly 500 each, R may be uneven)
SELECT 'R' AS metric, r_score AS score, COUNT(*) AS households FROM hh_rfm_scores GROUP BY r_score
UNION ALL
SELECT 'F', f_score, COUNT(*) FROM hh_rfm_scores GROUP BY f_score
UNION ALL
SELECT 'M', m_score, COUNT(*) FROM hh_rfm_scores GROUP BY m_score
ORDER BY metric, score;

-- Result : F 489 to 508 and M 498 to 499 per score.
-- R is uneven (score 5 = 598, score 3 = 444) because many households share the same recency (0 or 1 day). 
-- Ties are kept in the same score by design. Accepted (no score above 30%).

-- We would like to arrange the segmentation FxM 
-- 3.3.2 Do F and M move together? (justifies combining them into one FM score)
SELECT ROUND(CORR(frequency, monetary)::numeric, 2) AS corr_raw,
       ROUND(CORR(f_score, m_score)::numeric, 2) AS corr_scores,
       ROUND(100.0 * COUNT(*) FILTER (WHERE ABS(f_score - m_score) <= 1) / COUNT(*), 1) AS pct_f_m_within_1
FROM hh_rfm_scores;

-- Result : corr raw 0.65, corr scores 0.80, 91.0% of households have F and M within 1 point. F and M are combined into one FM score. The 9% with a gap of 2+ points
-- (for example infrequent but high-spend households) lose some detail. Accepted.

-- 3.4 Segments from R and FM (FM = average of F and M, rounded)
-- R shows whether a household is still active, FM shows how valuable it is.
-- Champions: recent and high value | Loyal: high value, slightly less recent
-- Potential: active, mid value | Light: active, low value
-- At risk: high value, not recent | Lapsed: low value, not recent
CREATE OR REPLACE VIEW hh_rfm_segments AS
WITH s AS (
    SELECT *,
           ROUND((f_score + m_score) / 2.0)::int AS fm_score
    FROM hh_rfm_scores
)
SELECT *,
       CASE WHEN r_score >= 4 AND fm_score >= 4 THEN 'Champions'
            WHEN r_score = 3  AND fm_score >= 4 THEN 'Loyal'
            WHEN r_score >= 3 AND fm_score BETWEEN 2 AND 3 THEN 'Potential'
            WHEN r_score >= 3 AND fm_score = 1 THEN 'Light'
            WHEN r_score <= 2 AND fm_score >= 3 THEN 'At risk'
            ELSE 'Lapsed' END AS segment
FROM s;

-- 3.5 Segment size and revenue share
SELECT segment,
       COUNT(*) AS households,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS pct_households,
       ROUND(SUM(monetary), 0) AS revenue,
       ROUND(100 * SUM(monetary) / SUM(SUM(monetary)) OVER (), 1) AS pct_revenue,
       ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY monetary)::numeric, 0) AS median_spend,
       ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY frequency)::numeric, 0) AS median_trips,
       ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY recency_days)::numeric, 0) AS median_recency_days
FROM hh_rfm_segments
GROUP BY segment
ORDER BY revenue DESC;

-- Result : Champions 28% of households, 53% of revenue.
-- Champions, Loyal, Potential and At risk = 74% of households, 95% of revenue.
-- Lapsed and Light = 26% of households, 5% of revenue.
-- "At risk" median recency is only 19 days vs a usual gap of about 8 to 9 days (missing 2 rounds):
-- R alone may overstate risk. Checked against each household's own rhythm in 9.6.

-- 3.6 How overdue is each household compared with its own usual gap between trips?
CREATE OR REPLACE VIEW hh_churn_risk AS
SELECT *,
       ROUND(recency_days / NULLIF(avg_gap_days, 0), 1) AS gap_ratio,
       CASE WHEN avg_gap_days IS NULL OR avg_gap_days = 0 THEN 'Unknown'
            WHEN recency_days <= avg_gap_days     THEN '1 On schedule'
            WHEN recency_days <= 2 * avg_gap_days THEN '2 Slightly late'
            WHEN recency_days <= 3 * avg_gap_days THEN '3 Late'
            ELSE '4 Overdue' END AS rhythm_status
FROM hh_rfm_segments;

SELECT segment, rhythm_status, COUNT(*) AS households, ROUND(SUM(monetary), 0) AS revenue
FROM hh_churn_risk
GROUP BY segment, rhythm_status
ORDER BY revenue DESC;
-- Result: At risk 424 households: 279 Late or Overdue, 145 within two of their usual gaps.
--         Champions 698 households: 644 (92%) on schedule, only 4 Late or Overdue.
--         Loyal 230 households: 34 Late or Overdue.
--         Lapsed: most are on schedule or one trip late, they simply shop infrequently.
--         8 households (all Lapsed) have a single trip and are Unknown.
-- Total at risk: 317 high-value households (At risk, Loyal, Champions) are Late or Overdue,
--         worth 1,044,386 over 86 weeks (15.3% of revenue).

-- 3.7 Robustness: Late or Overdue counts using average gap vs median gap
WITH days AS (
    SELECT DISTINCT t.household_key, t.day
    FROM transactions_clean t
    LEFT JOIN product_clean p ON p.product_id = t.product_id
    WHERE t.week_no >= 17
      AND NOT COALESCE(p.is_nonmerch, FALSE)
),
gaps AS (
    SELECT household_key,
           day - LAG(day) OVER (PARTITION BY household_key ORDER BY day) AS gap
    FROM days
),
med AS (
    SELECT household_key,
           PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY gap) AS median_gap
    FROM gaps
    WHERE gap IS NOT NULL
    GROUP BY household_key
)
SELECT r.segment,
       COUNT(*) AS households,
       COUNT(*) FILTER (WHERE r.rhythm_status IN ('3 Late', '4 Overdue')) AS late_overdue_avg_gap,
       COUNT(*) FILTER (WHERE r.recency_days > 2 * m.median_gap) AS late_overdue_median_gap,
       ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY r.avg_gap_days)::numeric, 1) AS typical_avg_gap,
       ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY m.median_gap)::numeric, 1) AS typical_median_gap,
	   ROUND(SUM(r.monetary) FILTER (WHERE r.rhythm_status IN ('3 Late', '4 Overdue')), 0) AS revenue_avg_gap,
       ROUND(SUM(r.monetary) FILTER (WHERE r.recency_days > 2 * m.median_gap)::numeric, 0) AS revenue_median_gap
FROM hh_churn_risk r
LEFT JOIN med m ON m.household_key = r.household_key
GROUP BY r.segment
ORDER BY households DESC;

-- Result: median gaps are shorter than average gaps in every segment (At risk 6.0 vs 7.8 days).
--         High-value households Late or Overdue: 317 (average gap) vs 372 (median gap).
--         Revenue: 1,044,386 vs 1,145,162 (15.3% vs 16.8% of revenue).
--         The extra households flagged by the median method spend less, so revenue moves only ~10%.
-- Decision: report as a range. The average-based list (317) is used for targeting because it
--         flags fewer households by mistake.