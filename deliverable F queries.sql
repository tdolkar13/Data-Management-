PRAGMA foreign_keys = ON;

-- =====================================================================
-- Tier 1 -- core SQL
-- =====================================================================

-- F1 · Top 10 audio tracks by number of distinct videos in the last 7 days.
-- Intent: "last 7 days" is relative to the most recent upload in the
-- dataset (synthetic data has no real "now").
SELECT
  audio_track_id,
  COUNT(DISTINCT video_id) AS n_videos
FROM Video
WHERE audio_track_id IS NOT NULL
  AND uploaded_at >= (SELECT datetime(MAX(uploaded_at), '-7 days') FROM Video)
GROUP BY audio_track_id
ORDER BY n_videos DESC
LIMIT 10;

-- F2 · Watch hours and completion rate per creator, live clips only.
-- Intent: every creator appears; zero-activity creators show 0, not
-- NULL, not absent. "Creator" = every owner_id that appears in Video.
WITH LatestModState AS (
  SELECT me.video_id, me.state_code
  FROM ModerationEvent me
  JOIN (
    SELECT video_id, MAX(decided_at) AS latest_ts
    FROM ModerationEvent
    GROUP BY video_id
  ) latest ON me.video_id = latest.video_id AND me.decided_at = latest.latest_ts
),
LiveVideo AS (
  SELECT v.video_id, v.owner_id, v.duration_ms
  FROM Video v
  JOIN LatestModState lm ON v.video_id = lm.video_id AND lm.state_code = 'live'
),
ImpressionAgg AS (
  SELECT video_id, COUNT(*) AS n_impressions
  FROM Impression
  GROUP BY video_id
),
WatchAgg AS (
  SELECT i.video_id,
         SUM(vs.segment_end_ms - vs.segment_start_ms) AS watch_ms
  FROM ViewSegment vs
  JOIN Impression i ON vs.impression_id = i.impression_id
  GROUP BY i.video_id
),
CompletionAgg AS (
  SELECT i.video_id, COUNT(DISTINCT i.impression_id) AS n_completed
  FROM ViewSegment vs
  JOIN Impression i ON vs.impression_id = i.impression_id
  JOIN Video v ON i.video_id = v.video_id
  WHERE vs.segment_end_ms >= v.duration_ms
  GROUP BY i.video_id
)
SELECT
  creators.owner_id AS creator_id,
  ROUND(COALESCE(SUM(wa.watch_ms), 0) / 3600000.0, 4) AS total_watch_hours,
  ROUND(AVG(
    CASE WHEN ia.n_impressions > 0
         THEN COALESCE(ca.n_completed, 0) * 1.0 / ia.n_impressions
         ELSE NULL END
  ), 4) AS mean_completion_rate
FROM (SELECT DISTINCT owner_id FROM Video) creators
LEFT JOIN LiveVideo lv     ON lv.owner_id = creators.owner_id
LEFT JOIN WatchAgg wa      ON wa.video_id = lv.video_id
LEFT JOIN CompletionAgg ca ON ca.video_id = lv.video_id
LEFT JOIN ImpressionAgg ia ON ia.video_id = lv.video_id
GROUP BY creators.owner_id
ORDER BY total_watch_hours DESC;

-- F3 · Videos with no audio track -- NOT IN vs NOT EXISTS.
SELECT COUNT(*) AS n_not_in FROM Video
WHERE audio_track_id NOT IN (SELECT track_id FROM AudioTrack);

SELECT COUNT(*) AS n_not_exists FROM Video v
WHERE NOT EXISTS (SELECT 1 FROM AudioTrack a WHERE a.track_id = v.audio_track_id);

-- F4 · Users who liked then retracted a like on the same clip within 60s.
SELECT DISTINCT
  l1.user_id, l1.video_id, l1.occurred_at AS liked_at, l2.occurred_at AS retracted_at
FROM LikeEvent l1
JOIN LikeEvent l2
  ON l1.user_id = l2.user_id AND l1.video_id = l2.video_id
WHERE l1.event_type = 'like' AND l2.event_type = 'retract'
  AND l2.occurred_at > l1.occurred_at
  AND (julianday(l2.occurred_at) - julianday(l1.occurred_at)) * 86400.0 <= 60;

-- F5 · Videos whose caption carries a given hashtag (case-insensitive,
-- tolerant of surrounding punctuation/whitespace). Built from lower(),
-- replace(), instr() -- not GLOB, not a bare LIKE '%...%' (that would
-- match "#funnyvideos" as well as "#funny", which is wrong).
SELECT video_id, caption
FROM Video
WHERE instr(
  ' ' || lower(replace(replace(replace(caption, ',', ' '), '.', ' '), '!', ' ')) || ' ',
  ' ' || lower(trim('#funny')) || ' '
) > 0;

-- F6 · Users shown a creator's clips but never engaged (set operator),
-- then one signal roll-up shown with UNION vs UNION ALL.
WITH CreatorVideos AS (
  SELECT video_id FROM Video WHERE owner_id = (SELECT owner_id FROM Video LIMIT 1)
),
Shown AS (
  SELECT DISTINCT i.user_id FROM Impression i
  WHERE i.video_id IN (SELECT video_id FROM CreatorVideos)
),
Engaged AS (
  SELECT user_id FROM LikeEvent WHERE video_id IN (SELECT video_id FROM CreatorVideos)
  UNION
  SELECT user_id FROM SaveEvent WHERE video_id IN (SELECT video_id FROM CreatorVideos)
  UNION
  SELECT user_id FROM ShareEvent WHERE video_id IN (SELECT video_id FROM CreatorVideos)
  UNION
  SELECT user_id FROM CommentEvent WHERE video_id IN (SELECT video_id FROM CreatorVideos)
  UNION
  SELECT user_id FROM ReportEvent WHERE video_id IN (SELECT video_id FROM CreatorVideos)
  UNION
  SELECT user_id FROM NotInterestedEvent WHERE video_id IN (SELECT video_id FROM CreatorVideos)
)
SELECT user_id FROM Shown
EXCEPT
SELECT user_id FROM Engaged;

-- One signal roll-up, UNION vs UNION ALL (row-count difference is the point):
SELECT user_id FROM LikeEvent WHERE video_id IN (SELECT video_id FROM Video WHERE owner_id = (SELECT owner_id FROM Video LIMIT 1))
UNION
SELECT user_id FROM SaveEvent WHERE video_id IN (SELECT video_id FROM Video WHERE owner_id = (SELECT owner_id FROM Video LIMIT 1));

SELECT user_id FROM LikeEvent WHERE video_id IN (SELECT video_id FROM Video WHERE owner_id = (SELECT owner_id FROM Video LIMIT 1))
UNION ALL
SELECT user_id FROM SaveEvent WHERE video_id IN (SELECT video_id FROM Video WHERE owner_id = (SELECT owner_id FROM Video LIMIT 1));

-- F7 · Cost per agent session last month, broken out by template version,
-- sessions costing more than a chosen threshold. Rates are $ per
-- 1,000,000 tokens (matches real-world vendor pricing scale).
SELECT
  t.session_id, ptv.template_name, ptv.version_no,
  ROUND(SUM(
    (t.input_tokens  * 1.0 / 1000000) * mpp.input_rate +
    (t.output_tokens * 1.0 / 1000000) * mpp.output_rate +
    (t.cached_tokens * 1.0 / 1000000) * mpp.cached_input_rate
  ), 6) AS session_cost_usd
FROM Turn t
JOIN PromptTemplateVersion ptv ON t.template_version_id = ptv.template_version_id
JOIN ModelPricingPeriod mpp
  ON mpp.model_id = t.model_id
  AND t.occurred_at >= mpp.valid_from
  AND (mpp.valid_to IS NULL OR t.occurred_at < mpp.valid_to)
WHERE t.occurred_at >= (SELECT datetime(MAX(occurred_at), '-30 days') FROM Turn)
GROUP BY t.session_id, ptv.template_name, ptv.version_no
HAVING session_cost_usd > 0.0005
ORDER BY session_cost_usd DESC;

-- F8 · Videos whose moderation state changed more than twice, full
-- transition sequence in chronological order (needs SQLite 3.44+).
SELECT
  video_id,
  COUNT(*) AS n_events,
  group_concat(state_code, ' -> ' ORDER BY decided_at) AS sequence
FROM ModerationEvent
GROUP BY video_id
HAVING COUNT(*) > 2
ORDER BY n_events DESC;

-- =====================================================================
-- Tier 2 -- window functions and recursion
-- =====================================================================

-- F9 · Each user's longest streak of consecutive active days.
-- Classic gaps-and-islands: subtracting a row number from the date
-- (in julian days) is constant within a run of consecutive days.
WITH ActiveDays AS (
  SELECT DISTINCT user_id, date(occurred_at) AS activity_date
  FROM Impression
),
Numbered AS (
  SELECT user_id, activity_date,
         julianday(activity_date) - ROW_NUMBER() OVER (
           PARTITION BY user_id ORDER BY activity_date
         ) AS grp
  FROM ActiveDays
)
SELECT user_id, MAX(streak_len) AS longest_streak
FROM (
  SELECT user_id, grp, COUNT(*) AS streak_len
  FROM Numbered
  GROUP BY user_id, grp
)
GROUP BY user_id
ORDER BY longest_streak DESC;

-- F10 · Rank creators by 7-day rolling watch time, week-over-week change.
-- "7 days" = seven CALENDAR days (RANGE over julianday), not the seven
-- most recent days the creator happened to have activity -- and the
-- week-over-week comparison uses an explicit self-join on
-- date(-7 days), not LAG(,7), because LAG counts activity ROWS and
-- silently answers a different question when a creator has gaps.
WITH DailyCreatorWatch AS (
  SELECT v.owner_id AS creator_id, date(i.occurred_at) AS activity_date,
         SUM(vs.segment_end_ms - vs.segment_start_ms) AS watch_ms
  FROM ViewSegment vs
  JOIN Impression i ON vs.impression_id = i.impression_id
  JOIN Video v ON i.video_id = v.video_id
  GROUP BY v.owner_id, date(i.occurred_at)
),
RollingWatch AS (
  SELECT creator_id, activity_date, watch_ms,
    SUM(watch_ms) OVER (
      PARTITION BY creator_id
      ORDER BY julianday(activity_date)
      RANGE BETWEEN 6 PRECEDING AND CURRENT ROW
    ) AS rolling_7d_watch_ms
  FROM DailyCreatorWatch
)
SELECT
  r1.creator_id, r1.activity_date, r1.rolling_7d_watch_ms,
  r2.rolling_7d_watch_ms AS rolling_7d_watch_ms_prior_week,
  r1.rolling_7d_watch_ms - r2.rolling_7d_watch_ms AS wow_change_ms
FROM RollingWatch r1
LEFT JOIN RollingWatch r2
  ON r1.creator_id = r2.creator_id
  AND date(r2.activity_date) = date(r1.activity_date, '-7 days')
ORDER BY r1.creator_id, r1.activity_date;

-- F11 · Full nesting tree for a given session's tool calls, with depth.
WITH RECURSIVE ToolTree AS (
  SELECT tc.tool_call_id, tc.turn_id, tc.parent_call_id, tc.tool_name, 0 AS depth
  FROM ToolCall tc
  JOIN Turn t ON tc.turn_id = t.turn_id
  WHERE t.session_id = 1 AND tc.parent_call_id IS NULL
  UNION ALL
  SELECT tc.tool_call_id, tc.turn_id, tc.parent_call_id, tc.tool_name, tt.depth + 1
  FROM ToolCall tc
  JOIN ToolTree tt ON tc.parent_call_id = tt.tool_call_id
)
SELECT * FROM ToolTree ORDER BY turn_id, depth;

-- F12 · Sessions where the agent recommended a clip the user watched to
-- completion -- reporting the clip's position in the shelf. The spine
-- query: Recommendation -> Turn -> AgentSession -> matching Impression
-- (same user+video, at or after the turn) -> ViewSegment reaching the
-- clip's duration.
SELECT DISTINCT
  s.session_id, r.video_id, r.position
FROM Recommendation r
JOIN Turn t         ON r.turn_id = t.turn_id
JOIN AgentSession s ON t.session_id = s.session_id
JOIN Impression i   ON i.video_id = r.video_id AND i.user_id = s.user_id
                       AND i.occurred_at >= t.occurred_at
JOIN ViewSegment vs ON vs.impression_id = i.impression_id
JOIN Video v        ON v.video_id = r.video_id
WHERE vs.segment_end_ms >= v.duration_ms
ORDER BY s.session_id, r.position;

-- F13 · Turns where the LLM judge scored above 4 but the user thumbed down.
SELECT
  t.turn_id, t.session_id, js.helpfulness, js.groundedness, js.safety, ur.thumbs
FROM Turn t
JOIN JudgeScore js ON js.turn_id = t.turn_id
JOIN UserRating ur ON ur.turn_id = t.turn_id
WHERE js.helpfulness > 4 AND ur.thumbs = 'down';
