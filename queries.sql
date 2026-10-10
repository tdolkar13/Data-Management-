-- queries.sql : Task 1, 2, 3, 4 queries and optimisation variants (named parameters shown as :name)
-- NOTE: F1/F2/F5 and the Task-2/3 benchmark texts are written against the real schema from the report's
--       descriptions of each query; if your screenshots show different text, paste yours over these.
-- Parameter values used for the recorded runs:
--   :t7 = '2025-12-24T00:00:00Z'
--   :since = '2025-12-01T00:00:00Z'
--   :m = 'gpt-4o-mini'
--   :ts = '2025-01-01T00:00:00Z'
--   :owner = 1404
--   :h = 'user_1404_563'
--   :vid = 1014

-- [F1] Task 1 / F1 - Top 10 audio tracks, last 7 days (filter + group)
SELECT a.track_id, a.source_type, COUNT(*) AS videos_using_track
FROM Video v
JOIN AudioTrack a ON a.track_id = v.audio_track_id
WHERE v.uploaded_at >= :t7
GROUP BY a.track_id, a.source_type
ORDER BY videos_using_track DESC
LIMIT 10;

-- [F2] Task 1 / F2 - Watch hours + completion rate per creator (joins high-volume telemetry)
-- completion = impression whose watched segments cover >= 90% of the video's duration
SELECT v.owner_id,
       ROUND(SUM(w.watched_ms) / 3600000.0, 3)                                   AS watch_hours,
       ROUND(AVG(CASE WHEN w.watched_ms >= 0.9 * v.duration_ms THEN 1.0 ELSE 0 END), 4) AS completion_rate
FROM Video v
JOIN Impression i ON i.video_id = v.video_id
JOIN (SELECT impression_id, SUM(segment_end_ms - segment_start_ms) AS watched_ms
      FROM ViewSegment GROUP BY impression_id) w ON w.impression_id = i.impression_id
GROUP BY v.owner_id
ORDER BY watch_hours DESC
LIMIT 20;

-- [F5] Task 1 / F5 - Agent turn latency and tool-error audit
SELECT t.model_id,
       COUNT(DISTINCT t.turn_id)                 AS turns,
       ROUND(AVG(tc.latency_ms), 1)              AS avg_tool_latency_ms,
       SUM(tc.errored)                           AS tool_errors
FROM Turn t
JOIN ToolCall tc ON tc.turn_id = t.turn_id
WHERE t.occurred_at >= :ts
GROUP BY t.model_id;

-- [B1] Task 2.2 / Q1 - Impression join (idx_impression_video_time)
SELECT i.video_id, i.occurred_at, i.feed_position, i.model_version
FROM Video v JOIN Impression i ON i.video_id = v.video_id
WHERE v.owner_id = :owner AND i.occurred_at >= :since;

-- [B2] Task 2.2 / Q2 - Turn aggregation (idx_turn_model_time_tokens)
SELECT model_id, SUM(input_tokens) AS in_tok, SUM(output_tokens) AS out_tok
FROM Turn WHERE model_id = :m AND occurred_at >= :ts GROUP BY model_id;

-- [B3] Task 2.2 / Q3 - ViewSegment watch time (idx_viewsegment_imp_start_end)
SELECT SUM(vs.segment_end_ms - vs.segment_start_ms) / 3600000.0 AS watch_hours
FROM Impression i JOIN ViewSegment vs ON vs.impression_id = i.impression_id
WHERE i.video_id = :vid;

-- [J1] Task 3 / J1 - Impression JOIN ViewSegment
SELECT COUNT(*) FROM Impression i JOIN ViewSegment vs ON vs.impression_id = i.impression_id
WHERE i.video_id <= 2000;

-- [J2] Task 3 / J2 - AgentSession JOIN Turn
SELECT COUNT(*) FROM AgentSession s JOIN Turn t ON t.session_id = s.session_id
WHERE s.started_at >= :ts;

-- [J3] Task 3.3 - 3-table join order (AgentSession -> Turn -> ToolCall)
SELECT s.session_id, COUNT(tc.tool_call_id) AS calls
FROM AgentSession s
JOIN Turn t      ON t.session_id = s.session_id
JOIN ToolCall tc ON tc.turn_id   = t.turn_id
WHERE s.started_at >= :since
GROUP BY s.session_id;

-- [N4] Task 4.2 - NAIVE: join in a derived table, selective filters applied afterwards
SELECT COUNT(*), AVG(latency_ms)
FROM (SELECT t.turn_id, t.occurred_at, tc.errored, tc.latency_ms
      FROM Turn t JOIN ToolCall tc ON tc.turn_id = t.turn_id)
WHERE errored = 1 AND occurred_at >= :ts;

-- [O4] Task 4.2 - OPTIMAL: selections pushed onto the base relations before the join
SELECT COUNT(*), AVG(tc.latency_ms)
FROM (SELECT turn_id FROM Turn WHERE occurred_at >= :ts) t
JOIN (SELECT turn_id, latency_ms FROM ToolCall WHERE errored = 1) tc ON tc.turn_id = t.turn_id;

-- [A4] Task 4 supplement - plain SQL, WHERE after the joins (Impression x Video x AppUser)
SELECT COUNT(*), COUNT(DISTINCT i.user_id), ROUND(AVG(i.feed_position),3)
FROM Impression i JOIN Video v ON v.video_id = i.video_id JOIN AppUser u ON u.user_id = v.owner_id
WHERE u.handle = :h AND i.occurred_at >= :since;

-- [B4] Task 4 supplement - NAIVE literal (MATERIALIZED join, filter afterwards)
WITH joined AS MATERIALIZED (
  SELECT i.user_id, i.occurred_at, i.feed_position, u.handle
  FROM Impression i JOIN Video v ON v.video_id = i.video_id JOIN AppUser u ON u.user_id = v.owner_id)
SELECT COUNT(*), COUNT(DISTINCT user_id), ROUND(AVG(feed_position),3)
FROM joined WHERE handle = :h AND occurred_at >= :since;

-- [C4] Task 4 supplement - PUSHED-DOWN literal (filter AppUser -> Video, then index-probe Impression)
WITH u AS MATERIALIZED (SELECT user_id FROM AppUser WHERE handle = :h),
     v AS MATERIALIZED (SELECT video_id FROM Video WHERE owner_id IN (SELECT user_id FROM u))
SELECT COUNT(*), COUNT(DISTINCT i.user_id), ROUND(AVG(i.feed_position),3)
FROM v CROSS JOIN Impression i ON i.video_id = v.video_id AND i.occurred_at >= :since;
