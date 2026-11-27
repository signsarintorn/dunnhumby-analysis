-- 04 promo lift
-- Purpose: To answer Q2. Do campaigns and promotions add revenue, and is it worth the discount?
-- Source:  transactions_clean (01_data_quality.sql), product_clean and hh_campaign (02_eda.sql),
--          hh_rfm_base (03_rfm_segmentation.sql)
-- Scope:   weeks 17 to 101 for weekly comparisons (week 102 has only 6 days), merchandise only
--
-- Design decisions from 02 eda:
-- 1. Campaigns overlap continuously from week 33, so campaign weeks cannot be compared with
--    non-campaign weeks. Comparisons are made between households instead.
-- 2. Targeting is not random. Before any campaign, TypeA households already spent 5.9 times
--    more. Impact is measured as change from each household's own baseline (weeks 17 to 32),
--    comparing households with similar baseline spend.
-- 3. Only 17% of households ever redeemed a coupon, so impact is measured through purchases,
--    not redemptions.

-- 4.1 Share of week-to-week sales variation explained by each driver
-- Weekly sales = households x trips per household x spend per basket. Taking logs turns this into
-- a sum, so each part's share of the week-to-week variation can be measured. Shares add to 100%.
WITH b AS (
    SELECT t.week_no,
           t.household_key,
           t.basket_id,
           SUM(t.sales_value) AS sales
    FROM transactions_clean t
    LEFT JOIN product_clean p ON p.product_id = t.product_id
    WHERE t.week_no BETWEEN 17 AND 101
      AND NOT COALESCE(p.is_nonmerch, FALSE)
    GROUP BY t.week_no, t.household_key, t.basket_id
),
weekly AS (
    SELECT week_no,
           SUM(sales) AS sales,
           COUNT(DISTINCT household_key) AS households,
           COUNT(*) AS baskets
    FROM b
    GROUP BY week_no
),
logs AS (
    SELECT LN(sales::numeric)::float8 AS l_sales,
           LN(households::numeric)::float8 AS l_hh,
           LN(baskets::numeric / households)::float8 AS l_freq,
           LN(sales::numeric / baskets)::float8 AS l_value
    FROM weekly
)
SELECT ROUND((100 * COVAR_SAMP(l_hh, l_sales) / VAR_SAMP(l_sales))::numeric, 1) AS share_households_pct,
       ROUND((100 * COVAR_SAMP(l_freq, l_sales) / VAR_SAMP(l_sales))::numeric, 1) AS share_frequency_pct,
       ROUND((100 * COVAR_SAMP(l_value, l_sales) / VAR_SAMP(l_sales))::numeric, 1) AS share_basket_value_pct,
       ROUND((100 * (COVAR_SAMP(l_hh, l_sales) + COVAR_SAMP(l_freq, l_sales)
              + COVAR_SAMP(l_value, l_sales)) / VAR_SAMP(l_sales))::numeric, 1) AS check_total
FROM logs;
-- Result : basket value 77.1%, households 25.4%, frequency -2.5%, total 100.0.
-- Weekly sales move mainly with spend per basket.

-- 4.2 Campaign 18 (TypeA, weeks 85 to 92): change in weekly spend vs baseline (weeks 17 to 32),
-- Lift = change in weekly spend of targeted households minus change of non-targeted households
--        in the same baseline-spend decile. This removes the pre-existing gap between the groups
--        and any change that affected everyone (store trends, regression to the mean).
WITH targeted AS (
    SELECT household_key FROM hh_campaign WHERE campaign = 18
),
spend AS (
    SELECT t.household_key,
           SUM(t.sales_value) FILTER (WHERE t.week_no BETWEEN 17 AND 32) / 16.0 AS pre_weekly,
           SUM(t.sales_value) FILTER (WHERE t.week_no BETWEEN 85 AND 92) / 8.0 AS during_weekly
    FROM transactions_clean t
    LEFT JOIN product_clean p ON p.product_id = t.product_id
    WHERE NOT COALESCE(p.is_nonmerch, FALSE)
      AND (t.week_no BETWEEN 17 AND 32 OR t.week_no BETWEEN 85 AND 92)
    GROUP BY t.household_key
),
base AS (
    SELECT r.household_key,
           s.pre_weekly,
           COALESCE(s.during_weekly, 0) AS during_weekly,
           (tg.household_key IS NOT NULL) AS is_targeted
    FROM hh_rfm_base r
    JOIN spend s ON s.household_key = r.household_key
    LEFT JOIN targeted tg ON tg.household_key = r.household_key
    WHERE s.pre_weekly > 0
),
banded AS (
    SELECT *, NTILE(10) OVER (ORDER BY pre_weekly) AS pre_decile
    FROM base
)
SELECT pre_decile,
       COUNT(*) FILTER (WHERE is_targeted) AS n_targeted,
       COUNT(*) FILTER (WHERE NOT is_targeted) AS n_control,
       ROUND(AVG(pre_weekly) FILTER (WHERE is_targeted)::numeric, 1) AS pre_targeted,
       ROUND(AVG(pre_weekly) FILTER (WHERE NOT is_targeted)::numeric, 1) AS pre_control,
       ROUND(AVG(during_weekly - pre_weekly) FILTER (WHERE is_targeted)::numeric, 1) AS change_targeted,
       ROUND(AVG(during_weekly - pre_weekly) FILTER (WHERE NOT is_targeted)::numeric, 1) AS change_control,
       ROUND((AVG(during_weekly - pre_weekly) FILTER (WHERE is_targeted)
            - AVG(during_weekly - pre_weekly) FILTER (WHERE NOT is_targeted))::numeric, 1) AS lift_per_week
FROM banded
GROUP BY pre_decile
ORDER BY pre_decile;
-- Result: baseline spend is close between groups in every decile, so matching works.
--         Lift is positive in all deciles (12.2 to 31.4 per week), weighted average 16.2 per
--         targeted household per week, about 145,000 over 8 weeks (1,117 households).
-- Concern: decile 1 rises from 1.9 to about 41.5 per week (lift 31.4). These households barely
--         shopped a year earlier and may have reactivated before the campaign. A year-old
--         baseline would count that as campaign effect, so this is treated as an upper bound.

-- 4.2.1 Same as 4.2, baseline weeks 77 to 84 (the 8 weeks just before campaign 18)
-- Baseline overlaps campaign 13 and some TypeB campaigns, so this version may understate the lift. Treated as the lower bound.
WITH targeted AS (
    SELECT household_key FROM hh_campaign WHERE campaign = 18
),
spend AS (
    SELECT t.household_key,
           SUM(t.sales_value) FILTER (WHERE t.week_no BETWEEN 77 AND 84) / 8.0 AS pre_weekly,
           SUM(t.sales_value) FILTER (WHERE t.week_no BETWEEN 85 AND 92) / 8.0 AS during_weekly
    FROM transactions_clean t
    LEFT JOIN product_clean p ON p.product_id = t.product_id
    WHERE NOT COALESCE(p.is_nonmerch, FALSE)
      AND (t.week_no BETWEEN 77 AND 84 OR t.week_no BETWEEN 85 AND 92)
    GROUP BY t.household_key
),
base AS (
    SELECT r.household_key,
           s.pre_weekly,
           COALESCE(s.during_weekly, 0) AS during_weekly,
           (tg.household_key IS NOT NULL) AS is_targeted
    FROM hh_rfm_base r
    JOIN spend s ON s.household_key = r.household_key
    LEFT JOIN targeted tg ON tg.household_key = r.household_key
    WHERE s.pre_weekly > 0
),
banded AS (
    SELECT *, NTILE(10) OVER (ORDER BY pre_weekly) AS pre_decile
    FROM base
)
SELECT pre_decile,
       COUNT(*) FILTER (WHERE is_targeted) AS n_targeted,
       COUNT(*) FILTER (WHERE NOT is_targeted) AS n_control,
       ROUND(AVG(pre_weekly) FILTER (WHERE is_targeted)::numeric, 1) AS pre_targeted,
       ROUND(AVG(pre_weekly) FILTER (WHERE NOT is_targeted)::numeric, 1) AS pre_control,
       ROUND(AVG(during_weekly - pre_weekly) FILTER (WHERE is_targeted)::numeric, 1) AS change_targeted,
       ROUND(AVG(during_weekly - pre_weekly) FILTER (WHERE NOT is_targeted)::numeric, 1) AS change_control,
       ROUND((AVG(during_weekly - pre_weekly) FILTER (WHERE is_targeted)
            - AVG(during_weekly - pre_weekly) FILTER (WHERE NOT is_targeted))::numeric, 1) AS lift_per_week
FROM banded
GROUP BY pre_decile
ORDER BY pre_decile;
-- Result: weighted average 6.7 per targeted household per week, about 60,000 over 8 weeks
--         (1,114 households). Deciles are rebuilt on recent spend, so they hold different households
--         from 4.2.
--         By band: light (deciles 1 to 3) 4.9 | middle (4 to 6) 4.5 | upper-middle (7 to 9) 10.5
--         | top (10) 1.6. Decile 1 lift drops from 31.4 to -0.7, confirming the concern in 4.2.
--         Single deciles are noisy (36 to 192 control households), so results are read by band.
-- At this point the estimate was a range of 60,000 to 145,000. See 4.4 for why it cannot be confirmed.

-- 4.3: were the extra sales new, or borrowed from later weeks?
-- If targeted households bought more during campaign 18 only because they stocked up, they should buy less after it ends.
-- Pull-forward check for campaign 18: lift during (weeks 85 to 92) and after (weeks 93 to 100)
-- Baseline weeks 77 to 84
WITH targeted AS (
    SELECT household_key FROM hh_campaign WHERE campaign = 18
),
spend AS (
    SELECT t.household_key,
           SUM(t.sales_value) FILTER (WHERE t.week_no BETWEEN 77 AND 84) / 8.0  AS pre_weekly,
           SUM(t.sales_value) FILTER (WHERE t.week_no BETWEEN 85 AND 92) / 8.0  AS during_weekly,
           SUM(t.sales_value) FILTER (WHERE t.week_no BETWEEN 93 AND 100) / 8.0 AS post_weekly
    FROM transactions_clean t
    LEFT JOIN product_clean p ON p.product_id = t.product_id
    WHERE NOT COALESCE(p.is_nonmerch, FALSE)
      AND t.week_no BETWEEN 77 AND 100
    GROUP BY t.household_key
),
base AS (
    SELECT r.household_key,
           s.pre_weekly,
           COALESCE(s.during_weekly, 0) AS during_weekly,
           COALESCE(s.post_weekly, 0) AS post_weekly,
           (tg.household_key IS NOT NULL) AS is_targeted
    FROM hh_rfm_base r
    JOIN spend s ON s.household_key = r.household_key
    LEFT JOIN targeted tg ON tg.household_key = r.household_key
    WHERE s.pre_weekly > 0
),
banded AS (
    SELECT *, NTILE(10) OVER (ORDER BY pre_weekly) AS pre_decile
    FROM base
),
dec AS (
    SELECT pre_decile,
           COUNT(*) FILTER (WHERE is_targeted) AS n_targeted,
           AVG(during_weekly - pre_weekly) FILTER (WHERE is_targeted)
         - AVG(during_weekly - pre_weekly) FILTER (WHERE NOT is_targeted) AS lift_during,
           AVG(post_weekly - pre_weekly) FILTER (WHERE is_targeted)
         - AVG(post_weekly - pre_weekly) FILTER (WHERE NOT is_targeted) AS lift_post
    FROM banded
    GROUP BY pre_decile
)
SELECT pre_decile::text AS decile,
       n_targeted,
       ROUND(lift_during::numeric, 1) AS lift_during_per_week,
       ROUND(lift_post::numeric, 1) AS lift_post_per_week
FROM dec
UNION ALL
SELECT 'All (weighted)',
       SUM(n_targeted),
       ROUND((SUM(n_targeted * lift_during) / SUM(n_targeted))::numeric, 1),
       ROUND((SUM(n_targeted * lift_post) / SUM(n_targeted))::numeric, 1)
FROM dec;
-- Result: Positive in every decile, no dip.
-- Caution: weeks 93 to 100 overlap campaigns 15 and 20 to 25. The post-campaign lift may come
--          from later campaigns, which could also hide a dip. Checked in 4.3.1 and 4.3.2.

-- 4.3.1 Did campaign 18 households get more campaigns in weeks 93 to 100 than control?
WITH t18 AS (
    SELECT household_key FROM hh_campaign WHERE campaign = 18
),
later AS (
    SELECT household_key, COUNT(DISTINCT campaign) AS n_campaigns
    FROM hh_campaign
    WHERE campaign <> 18
      AND start_week <= 100
      AND end_week >= 93
    GROUP BY household_key
)
SELECT (t.household_key IS NOT NULL) AS got_campaign_18,
       COUNT(*) AS households,
       ROUND(100.0 * COUNT(l.household_key) / COUNT(*), 1) AS pct_with_later_campaign,
       ROUND(AVG(COALESCE(l.n_campaigns, 0)), 2) AS avg_later_campaigns
FROM hh_rfm_base r
LEFT JOIN t18 t ON t.household_key = r.household_key
LEFT JOIN later l ON l.household_key = r.household_key
GROUP BY 1;
-- Result: campaign 18 households 47.3% received a later campaign (0.83 on average)
--         vs 6.5% of other households (0.10). The post-campaign window is mixed with later campaigns.

-- 4.3.2 Excluding households with any other campaign in weeks 93 to 100
-- Pull-forward check for campaign 18: lift during (weeks 85 to 92) and after (weeks 93 to 100)
-- Baseline weeks 77 to 84. Both groups exclude households that received another campaign
-- in the post window, so the post-campaign comparison is not mixed with later campaigns.
WITH targeted AS (
    SELECT household_key FROM hh_campaign WHERE campaign = 18
),
later AS (
    SELECT DISTINCT household_key
    FROM hh_campaign
    WHERE campaign <> 18
      AND start_week <= 100
      AND end_week >= 93
),
spend AS (
    SELECT t.household_key,
           SUM(t.sales_value) FILTER (WHERE t.week_no BETWEEN 77 AND 84) / 8.0  AS pre_weekly,
           SUM(t.sales_value) FILTER (WHERE t.week_no BETWEEN 85 AND 92) / 8.0  AS during_weekly,
           SUM(t.sales_value) FILTER (WHERE t.week_no BETWEEN 93 AND 100) / 8.0 AS post_weekly
    FROM transactions_clean t
    LEFT JOIN product_clean p ON p.product_id = t.product_id
    WHERE NOT COALESCE(p.is_nonmerch, FALSE)
      AND t.week_no BETWEEN 77 AND 100
    GROUP BY t.household_key
),
base AS (
    SELECT r.household_key,
           s.pre_weekly,
           COALESCE(s.during_weekly, 0) AS during_weekly,
           COALESCE(s.post_weekly, 0) AS post_weekly,
           (tg.household_key IS NOT NULL) AS is_targeted
    FROM hh_rfm_base r
    JOIN spend s ON s.household_key = r.household_key
    LEFT JOIN targeted tg ON tg.household_key = r.household_key
    LEFT JOIN later lt ON lt.household_key = r.household_key
    WHERE s.pre_weekly > 0
      AND lt.household_key IS NULL
),
banded AS (
    SELECT *, NTILE(10) OVER (ORDER BY pre_weekly) AS pre_decile
    FROM base
),
dec AS (
    SELECT pre_decile,
           COUNT(*) FILTER (WHERE is_targeted) AS n_targeted,
           COUNT(*) FILTER (WHERE NOT is_targeted) AS n_control,
           AVG(during_weekly - pre_weekly) FILTER (WHERE is_targeted)
         - AVG(during_weekly - pre_weekly) FILTER (WHERE NOT is_targeted) AS lift_during,
           AVG(post_weekly - pre_weekly) FILTER (WHERE is_targeted)
         - AVG(post_weekly - pre_weekly) FILTER (WHERE NOT is_targeted) AS lift_post
    FROM banded
    GROUP BY pre_decile
)
SELECT pre_decile::text AS decile,
       n_targeted,
       n_control,
       ROUND(lift_during::numeric, 1) AS lift_during_per_week,
       ROUND(lift_post::numeric, 1) AS lift_post_per_week
FROM dec
UNION ALL
SELECT 'All (weighted)',
       SUM(n_targeted),
       SUM(n_control),
       ROUND((SUM(n_targeted * lift_during) / SUM(n_targeted))::numeric, 1),
       ROUND((SUM(n_targeted * lift_post) / SUM(n_targeted))::numeric, 1)
FROM dec;
-- Result: 578 targeted and 997 control households remain. Lift during 4.7, lift after +5.9.
--         Still no dip after the campaign.
-- Conclusion: no evidence of pull-forward. This subgroup responds less than all targeted
--         households (4.7 vs 6.7).

-- 4.4 Placebo test: same method on two campaign-free periods (weeks 17 to 24 vs 25 to 32)
-- Lift should be close to 0. A clearly positive value means campaign 18 households were
-- already growing faster than comparable households, which would inflate the lift estimates.
WITH targeted AS (
    SELECT household_key FROM hh_campaign WHERE campaign = 18
),
spend AS (
    SELECT t.household_key,
           SUM(t.sales_value) FILTER (WHERE t.week_no BETWEEN 17 AND 24) / 8.0 AS pre_weekly,
           SUM(t.sales_value) FILTER (WHERE t.week_no BETWEEN 25 AND 32) / 8.0 AS fake_during_weekly
    FROM transactions_clean t
    LEFT JOIN product_clean p ON p.product_id = t.product_id
    WHERE NOT COALESCE(p.is_nonmerch, FALSE)
      AND t.week_no BETWEEN 17 AND 32
    GROUP BY t.household_key
),
base AS (
    SELECT r.household_key,
           s.pre_weekly,
           COALESCE(s.fake_during_weekly, 0) AS fake_during_weekly,
           (tg.household_key IS NOT NULL) AS is_targeted
    FROM hh_rfm_base r
    JOIN spend s ON s.household_key = r.household_key
    LEFT JOIN targeted tg ON tg.household_key = r.household_key
    WHERE s.pre_weekly > 0
),
banded AS (
    SELECT *, NTILE(10) OVER (ORDER BY pre_weekly) AS pre_decile
    FROM base
),
dec AS (
    SELECT pre_decile,
           COUNT(*) FILTER (WHERE is_targeted) AS n_targeted,
           COUNT(*) FILTER (WHERE NOT is_targeted) AS n_control,
           AVG(fake_during_weekly - pre_weekly) FILTER (WHERE is_targeted)
         - AVG(fake_during_weekly - pre_weekly) FILTER (WHERE NOT is_targeted) AS placebo_lift
    FROM banded
    GROUP BY pre_decile
)
SELECT pre_decile::text AS decile,
       n_targeted,
       n_control,
       ROUND(placebo_lift::numeric, 1) AS placebo_lift_per_week
FROM dec
UNION ALL
SELECT 'All (weighted)',
       SUM(n_targeted),
       SUM(n_control),
       ROUND((SUM(n_targeted * placebo_lift) / SUM(n_targeted))::numeric, 1)
FROM dec;
-- Result: placebo lift +11.7 per week, positive in every decile (5.5 to 20.8).
--         Targeted households were already growing faster with no campaign running, by more than
--         the lift measured during campaign 18 (4.7 to 6.7 with a recent baseline).
-- Conclusion: the effect of campaign 18 cannot be separated from the natural growth of the
--         households chosen for it, so it cannot be confirmed with this data.
-- Recommendation: keep a random holdout group (for example 10% of selected households
--         not contacted) in future campaigns.

-- 4.5 Discounts by 17-week block (weeks 17 to 101), merchandise only. Descriptive.
-- Discounts are stored as negative values, shown here as positive amounts.
SELECT MIN(t.week_no) || '-' || MAX(t.week_no) AS weeks,
       ROUND(SUM(t.sales_value)::numeric, 0) AS sales,
       ROUND(-SUM(t.retail_disc)::numeric, 0) AS retail_disc,
       ROUND(-SUM(t.coupon_disc)::numeric, 0) AS coupon_disc,
       ROUND(100 * -SUM(t.retail_disc)::numeric / SUM(t.sales_value)::numeric, 2) AS retail_disc_pct,
       ROUND(100 * -SUM(t.coupon_disc)::numeric / SUM(t.sales_value)::numeric, 2) AS coupon_disc_pct,
       ROUND(100.0 * COUNT(*) FILTER (WHERE t.retail_disc < 0) / COUNT(*), 1) AS pct_items_on_promo
FROM transactions_clean t
LEFT JOIN product_clean p ON p.product_id = t.product_id
WHERE t.week_no BETWEEN 17 AND 101
  AND NOT COALESCE(p.is_nonmerch, FALSE)
GROUP BY FLOOR((t.week_no - 17) / 17)
ORDER BY MIN(t.week_no);

-- Result: store discounts are about 18% of sales in every block. Coupon discounts are 0.38 to 0.51%.
--         Totals: store discounts 1,237,159 | coupon discounts 29,803 (2.4% of all discounts).
--         About half of all items are bought on a store discount (49.1 to 51.1%).
--         Weeks 85 to 101 sales +8.3% vs 68 to 84, with no deeper discounting (17.90% vs 18.08%).

-- Q2 summary
-- 1. Weekly sales move mainly with spend per basket (77% of variation), not traffic.
-- 2. Campaign 18's effect cannot be confirmed: targeted households were already growing faster
--    before any campaign, by as much as the measured lift.
-- 3. No pull-forward: targeted households did not spend less after the campaign. But we still cannot conclude if it is from the campaign 18's lasting effect.
-- 4. Coupons are about 2% of all discounts. Store discounts are steady at about 18% of sales.