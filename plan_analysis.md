# plan_analysis.md - raw EXPLAIN QUERY PLAN output and execution traces

Engine: SQLite 3.45.1, page size 4096, WAL. Data: Video 20,000 / Impression 304,198 / ViewSegment 134,977 / AgentSession 2,000 / Turn 3,516 / ToolCall 6,979 rows.
Timings = median of 15 warm in-process runs (ms). BEFORE = baseline schema without the Task-2 indexes; AFTER = with indexes.sql applied + ANALYZE.

> Scale note: the report's Task 1.2 hand calculation assumes 1,000,000 Video rows and Task 2.2 quotes SCALE=50 timings. The file `scrollsense.db` supplied has far fewer rows, so the absolute numbers below are smaller than those quoted in the report; the plan *shapes* are the evidence.

## Task 1 - access paths (baseline schema, no Task-2 indexes)

### [F1] Task 1 / F1 - Top 10 audio tracks, last 7 days (filter + group)
```sql
SELECT a.track_id, a.source_type, COUNT(*) AS videos_using_track
FROM Video v
JOIN AudioTrack a ON a.track_id = v.audio_track_id
WHERE v.uploaded_at >= :t7
GROUP BY a.track_id, a.source_type
ORDER BY videos_using_track DESC
LIMIT 10;
```
```
SCAN v
SEARCH a USING INTEGER PRIMARY KEY (rowid=?)
USE TEMP B-TREE FOR GROUP BY
USE TEMP B-TREE FOR ORDER BY
```
result (first row) = `[(74, 'licensed', 4)]`  median = **1.08 ms**

### [F2] Task 1 / F2 - Watch hours + completion rate per creator (joins high-volume telemetry)
```sql
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
```
```
CO-ROUTINE w
SCAN ViewSegment USING INDEX ix_viewsegment_impression
SCAN w
SEARCH i USING INTEGER PRIMARY KEY (rowid=?)
SEARCH v USING INTEGER PRIMARY KEY (rowid=?)
USE TEMP B-TREE FOR GROUP BY
USE TEMP B-TREE FOR ORDER BY
```
result (first row) = `[(1404, 0.935, 0.0943)]`  median = **126.27 ms**

### [F5] Task 1 / F5 - Agent turn latency and tool-error audit
```sql
SELECT t.model_id,
       COUNT(DISTINCT t.turn_id)                 AS turns,
       ROUND(AVG(tc.latency_ms), 1)              AS avg_tool_latency_ms,
       SUM(tc.errored)                           AS tool_errors
FROM Turn t
JOIN ToolCall tc ON tc.turn_id = t.turn_id
WHERE t.occurred_at >= :ts
GROUP BY t.model_id;
```
```
SCAN tc
BLOOM FILTER ON t (turn_id=?)
SEARCH t USING INTEGER PRIMARY KEY (rowid=?)
USE TEMP B-TREE FOR GROUP BY
USE TEMP B-TREE FOR count(DISTINCT)
```
result (first row) = `[('gpt-4o-mini', 3516, 401.0, 0)]`  median = **3.28 ms**

## Task 2.2 - before vs after composite indexes

| Query | Plan BEFORE | ms BEFORE | Plan AFTER | ms AFTER |
|---|---|---|---|---|
| B1: Impression join (idx_impression_video_time) | SEARCH v USING COVERING INDEX ix_video_owner (owner_id=?) / SEARCH i USING INDEX ix_impression_video (video_id=?) | 0.89 | SEARCH v USING COVERING INDEX ix_video_owner (owner_id=?) / SEARCH i USING COVERING INDEX idx_impression_video_time (video_id=? AND occurred_at>?) | 0.06 |
| B2: Turn aggregation (idx_turn_model_time_tokens) | SCAN Turn | 0.54 | SEARCH Turn USING COVERING INDEX idx_turn_model_time_tokens (model_id=? AND occurred_at>?) | 0.40 |
| B3: ViewSegment watch time (idx_viewsegment_imp_start_end) | SEARCH i USING COVERING INDEX ix_impression_video (video_id=?) / SEARCH vs USING INDEX ix_viewsegment_impression (impression_id=?) | 0.01 | SEARCH i USING COVERING INDEX ix_impression_video (video_id=?) / SEARCH vs USING COVERING INDEX idx_viewsegment_imp_start_end (impression_id=?) | 0.01 |

## Task 3 - join strategies (indexed schema)

### [J1] Task 3 / J1 - Impression JOIN ViewSegment
```sql
SELECT COUNT(*) FROM Impression i JOIN ViewSegment vs ON vs.impression_id = i.impression_id
WHERE i.video_id <= 2000;
```
```
SEARCH i USING COVERING INDEX ix_impression_video (video_id<?)
SEARCH vs USING COVERING INDEX ix_viewsegment_impression (impression_id=?)
```
result (first row) = `[(13588,)]`  median = **12.99 ms**

### [J2] Task 3 / J2 - AgentSession JOIN Turn
```sql
SELECT COUNT(*) FROM AgentSession s JOIN Turn t ON t.session_id = s.session_id
WHERE s.started_at >= :ts;
```
```
SCAN s
SEARCH t USING COVERING INDEX ix_turn_session (session_id=?)
```
result (first row) = `[(3516,)]`  median = **0.48 ms**

### [J3] Task 3.3 - 3-table join order (AgentSession -> Turn -> ToolCall)
```sql
SELECT s.session_id, COUNT(tc.tool_call_id) AS calls
FROM AgentSession s
JOIN Turn t      ON t.session_id = s.session_id
JOIN ToolCall tc ON tc.turn_id   = t.turn_id
WHERE s.started_at >= :since
GROUP BY s.session_id;
```
```
SCAN tc
SEARCH t USING INTEGER PRIMARY KEY (rowid=?)
BLOOM FILTER ON s (session_id=?)
SEARCH s USING INTEGER PRIMARY KEY (rowid=?)
USE TEMP B-TREE FOR GROUP BY
```
result (first row) = `[(6, 4)]`  median = **0.78 ms**

## Task 4.2 - predicate pushdown

## Task 4.2 pair from the report (Turn x ToolCall) - indexed schema

### [N4] Task 4.2 - NAIVE: join in a derived table, selective filters applied afterwards
```sql
SELECT COUNT(*), AVG(latency_ms)
FROM (SELECT t.turn_id, t.occurred_at, tc.errored, tc.latency_ms
      FROM Turn t JOIN ToolCall tc ON tc.turn_id = t.turn_id)
WHERE errored = 1 AND occurred_at >= :ts;
```
```
SCAN tc
SEARCH t USING INTEGER PRIMARY KEY (rowid=?)
```
result (first row) = `[(0, None)]`  median = **0.25 ms**

### [O4] Task 4.2 - OPTIMAL: selections pushed onto the base relations before the join
```sql
SELECT COUNT(*), AVG(tc.latency_ms)
FROM (SELECT turn_id FROM Turn WHERE occurred_at >= :ts) t
JOIN (SELECT turn_id, latency_ms FROM ToolCall WHERE errored = 1) tc ON tc.turn_id = t.turn_id;
```
```
SCAN ToolCall
SEARCH Turn USING INTEGER PRIMARY KEY (rowid=?)
```
result (first row) = `[(0, None)]`  median = **0.25 ms**

> Data caveat: this database has **0** ToolCall rows with errored = 1, so the report's predicate is empty here and both timings are dominated by fixed overhead. Equal plans are still valid evidence of flattening; the supplement below uses a selective predicate that has data.

## Task 4 supplement - selective filter where the rewrite matters (indexed schema)

### [A4] Task 4 supplement - plain SQL, WHERE after the joins (Impression x Video x AppUser)
```sql
SELECT COUNT(*), COUNT(DISTINCT i.user_id), ROUND(AVG(i.feed_position),3)
FROM Impression i JOIN Video v ON v.video_id = i.video_id JOIN AppUser u ON u.user_id = v.owner_id
WHERE u.handle = :h AND i.occurred_at >= :since;
```
```
USE TEMP B-TREE FOR count(DISTINCT)
SCAN u
SEARCH v USING COVERING INDEX ix_video_owner (owner_id=?)
SEARCH i USING INDEX idx_impression_video_time (video_id=? AND occurred_at>?)
```
result (first row) = `[(62, 61, 18.935)]`  median = **0.26 ms**

### [B4] Task 4 supplement - NAIVE literal (MATERIALIZED join, filter afterwards)
```sql
WITH joined AS MATERIALIZED (
  SELECT i.user_id, i.occurred_at, i.feed_position, u.handle
  FROM Impression i JOIN Video v ON v.video_id = i.video_id JOIN AppUser u ON u.user_id = v.owner_id)
SELECT COUNT(*), COUNT(DISTINCT user_id), ROUND(AVG(feed_position),3)
FROM joined WHERE handle = :h AND occurred_at >= :since;
```
```
MATERIALIZE joined
SCAN v USING COVERING INDEX ix_video_owner
SEARCH u USING INTEGER PRIMARY KEY (rowid=?)
SEARCH i USING INDEX ix_impression_video (video_id=?)
USE TEMP B-TREE FOR count(DISTINCT)
SCAN joined
```
result (first row) = `[(62, 61, 18.935)]`  median = **431.94 ms**

### [C4] Task 4 supplement - PUSHED-DOWN literal (filter AppUser -> Video, then index-probe Impression)
```sql
WITH u AS MATERIALIZED (SELECT user_id FROM AppUser WHERE handle = :h),
     v AS MATERIALIZED (SELECT video_id FROM Video WHERE owner_id IN (SELECT user_id FROM u))
SELECT COUNT(*), COUNT(DISTINCT i.user_id), ROUND(AVG(i.feed_position),3)
FROM v CROSS JOIN Impression i ON i.video_id = v.video_id AND i.occurred_at >= :since;
```
```
MATERIALIZE v
SEARCH Video USING COVERING INDEX ix_video_owner (owner_id=?)
LIST SUBQUERY 2
MATERIALIZE u
SCAN AppUser
SCAN u
USE TEMP B-TREE FOR count(DISTINCT)
SCAN v
SEARCH i USING INDEX idx_impression_video_time (video_id=? AND occurred_at>?)
```
result (first row) = `[(62, 61, 18.935)]`  median = **0.27 ms**

### [A4 without sqlite_stat1] same plain query, planner statistics removed (as in the supplied scrollsense.db)
```
USE TEMP B-TREE FOR count(DISTINCT)
SCAN i
SEARCH v USING INTEGER PRIMARY KEY (rowid=?)
SEARCH u USING INTEGER PRIMARY KEY (rowid=?)
```
result = `[(62, 61, 18.935)]`  median = **33.04 ms**

Reading: SQLite flattens the derived tables in N4/O4, so both give the same plan (pushdown already happened). In the supplement the plain query (A4) matches the hand-pushed form (C4) only when planner statistics exist (`ANALYZE`); with no `sqlite_stat1` it drives from Impression and is far slower. `MATERIALIZED` (B4) removes SQLite's ability to push the filter inside, which gives the literal naive plan. Outer-join exception (Task 4.1): Video LEFT JOIN ModerationEvent WHERE state_code='taken_down' returns 924 rows, filter pushed into the right input returns 20,032.

## Task 3.3 follow-up - same 3-table join after adding an index on ToolCall(turn_id) (NOT part of the Task 2 set)
```
SCAN s
SEARCH t USING COVERING INDEX ix_turn_session (session_id=?)
SEARCH tc USING COVERING INDEX ix_toolcall_turn (turn_id=?)
```
The supplied schema has no index on ToolCall.turn_id, so SQLite cannot start from AgentSession and probe ToolCall; with the extra index it can (Option A in the report).

## Task 5 - concurrency traces (concurrency_runner.py, two real connections, WAL)

```

### Run 1  UNPROTECTED (autocommit read, then write)
  t=    1.1 ms  T_B: READ balance = 100
  t=    1.5 ms  T_A: READ balance = 100
  t=    2.1 ms  T_A: WRITE balance = 80
  t=    3.2 ms  T_B: WRITE balance = 150
  FINAL balance = 150  (correct = 130)  -> LOST UPDATE

### Run 2  FIX: BEGIN IMMEDIATE around read-modify-write
  t=    0.7 ms  T_A: BEGIN IMMEDIATE requested
  t=    0.7 ms  T_A: BEGIN IMMEDIATE granted (waited 0 ms)
  t=    0.8 ms  T_A: READ balance = 100
  t=   50.9 ms  T_B: BEGIN IMMEDIATE requested
  t=  301.0 ms  T_A: WRITE balance = 80
  t=  301.6 ms  T_A: COMMIT
  t=  381.1 ms  T_B: BEGIN IMMEDIATE granted (waited 330 ms)
  t=  381.2 ms  T_B: READ balance = 80
  t=  681.6 ms  T_B: WRITE balance = 130
  t=  682.4 ms  T_B: COMMIT
  FINAL balance = 130  (correct = 130)  -> OK

### Run 3  ALTERNATIVE: plain BEGIN + retry on 'database is locked'
  t=    1.0 ms  T_B: READ balance = 100 (try 1)
  t=    1.8 ms  T_A: READ balance = 100 (try 1)
  t=    1.9 ms  T_A: WRITE balance = 80
  t=    2.1 ms  T_B: !! database is locked -> ROLLBACK, retry
  t=    2.3 ms  T_A: COMMIT
  t=   12.3 ms  T_B: READ balance = 80 (try 2)
  t=   12.3 ms  T_B: WRITE balance = 130
  t=   12.8 ms  T_B: COMMIT
  FINAL balance = 130  (correct = 130)  -> OK
  attempts: {'T_A': 1, 'T_B': 2}

### Run 4  ALTERNATIVE: atomic UPDATE balance = balance + delta (no read in the app)
  t=    1.9 ms  T_B: UPDATE balance = balance +50
  t=    3.0 ms  T_A: UPDATE balance = balance -20
  FINAL balance = 130  (correct = 130)  -> OK```

Cost of the fix: BEGIN IMMEDIATE makes T_B wait for T_A's whole critical section (330 ms in Run 2) and, because SQLite has one write lock per database, it blocks *every* other writer in that window; with plain BEGIN nobody waits up front but the loser's work is rolled back and redone (T_B needed 2 attempts in Run 3).
