PRAGMA foreign_keys = ON;

-- v_public_profile · mobile client
-- Exposes handle, display name, follower count. Never phone/email;
-- never a deactivated or pending-deletion account.
CREATE VIEW v_public_profile AS
SELECT
  u.user_id,
  u.handle,
  u.display_name,
  (SELECT COUNT(*) FROM Follow f
     WHERE f.followee_id = u.user_id AND f.ended_at IS NULL) AS follower_count
FROM AppUser u
WHERE u.account_state = 'active';

-- v_video_current_state · Trust & Safety
-- Current moderation state of every video, in one lookup, derived from
-- the append-only ModerationEvent log (no stored current_state column
-- exists anywhere -- see A6 / B.2 / C.2).
CREATE VIEW v_video_current_state AS
SELECT
  me.video_id,
  me.state_code AS current_state,
  me.decided_at AS state_since
FROM ModerationEvent me
JOIN (
  SELECT video_id, MAX(decided_at) AS latest_ts
  FROM ModerationEvent
  GROUP BY video_id
) latest ON me.video_id = latest.video_id AND me.decided_at = latest.latest_ts;

-- v_creator_tier_current · Growth
-- Each creator's tier as of now -- the currently-open validity interval.
CREATE VIEW v_creator_tier_current AS
SELECT creator_id, tier, valid_from
FROM CreatorTierPeriod
WHERE valid_to IS NULL;

-- v_video_daily_engagement · Growth analysts
-- Per video per day: impressions, view segments, watch seconds, net
-- likes. Days with impressions but no engagement appear with zeros --
-- the day grain comes from Impression, everything else LEFT JOINs in.
CREATE VIEW v_video_daily_engagement AS
WITH ImpDays AS (
  SELECT video_id, date(occurred_at) AS activity_date, COUNT(*) AS n_impressions
  FROM Impression
  GROUP BY video_id, date(occurred_at)
),
ViewsPerDay AS (
  SELECT i.video_id, date(i.occurred_at) AS activity_date,
         COUNT(DISTINCT vs.view_segment_id) AS n_view_segments,
         SUM(vs.segment_end_ms - vs.segment_start_ms) AS watch_ms
  FROM ViewSegment vs
  JOIN Impression i ON vs.impression_id = i.impression_id
  GROUP BY i.video_id, date(i.occurred_at)
),
LikesPerDay AS (
  SELECT video_id, date(occurred_at) AS activity_date,
         SUM(CASE WHEN event_type = 'like' THEN 1 ELSE 0 END)
           - SUM(CASE WHEN event_type = 'retract' THEN 1 ELSE 0 END) AS net_likes
  FROM LikeEvent
  GROUP BY video_id, date(occurred_at)
)
SELECT
  d.video_id,
  d.activity_date,
  d.n_impressions,
  COALESCE(v.n_view_segments, 0) AS n_view_segments,
  COALESCE(v.watch_ms, 0) / 1000.0 AS watch_seconds,
  COALESCE(l.net_likes, 0) AS net_likes
FROM ImpDays d
LEFT JOIN ViewsPerDay v ON v.video_id = d.video_id AND v.activity_date = d.activity_date
LEFT JOIN LikesPerDay l ON l.video_id = d.video_id AND l.activity_date = d.activity_date;

-- v_turn_cost · Finance
-- Cost per turn, computed against the price that was in force AT THE
-- TURN'S OWN TIMESTAMP -- not today's ModelPricingPeriod row.
CREATE VIEW v_turn_cost AS
SELECT
  t.turn_id,
  t.session_id,
  t.occurred_at,
  (t.input_tokens  * 1.0 / 1000000) * mpp.input_rate
    + (t.output_tokens * 1.0 / 1000000) * mpp.output_rate
    + (t.cached_tokens * 1.0 / 1000000) * mpp.cached_input_rate AS cost_usd
FROM Turn t
JOIN ModelPricingPeriod mpp
  ON mpp.model_id = t.model_id
  AND t.occurred_at >= mpp.valid_from
  AND (mpp.valid_to IS NULL OR t.occurred_at < mpp.valid_to);
