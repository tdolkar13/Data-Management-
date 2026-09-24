PRAGMA foreign_keys = ON;

-- =====================================================================
-- T1 · A block breaks a follow, atomically.
--
-- The task sheet's own template scenario ("a like is retracted: the
-- like row is ended and a negative-signal row is written") does not
-- apply to this schema: LikeEvent is append-only by design (A8/B.2),
-- so a retraction is a SINGLE INSERT and cannot half-fail. The block-
-- breaks-follow operation (\u00a72.3/A7) is the genuine two-write hazard
-- that actually exists here: INSERT into Block, then UPDATE Follow to
-- close both directions. NOTE: SQLite's integer division does NOT
-- raise on 1/0 (it returns NULL, unlike most other engines) -- the
-- deliberate failure below uses a real CHECK violation instead.
-- =====================================================================

BEGIN;
  INSERT INTO Block(blocker_id, blocked_id, blocked_at)
    VALUES (1, 2, '2025-01-03T00:00:00Z');
  UPDATE Follow SET ended_at = '2025-01-03T00:00:00Z'
    WHERE ((follower_id = 1 AND followee_id = 2)
        OR (follower_id = 2 AND followee_id = 1))
      AND ended_at IS NULL;
  -- deliberate failure: violates CHECK (blocker_id <> blocked_id)
  INSERT INTO Block(blocker_id, blocked_id, blocked_at)
    VALUES (1, 1, '2025-01-03T00:00:00Z');
COMMIT; -- never reached

-- Proof of consistency (run after the above rolls back):
SELECT COUNT(*) AS block_row_should_be_zero
  FROM Block WHERE blocker_id = 1 AND blocked_id = 2;
SELECT follower_id, followee_id, ended_at AS should_still_be_null
  FROM Follow WHERE (follower_id, followee_id) IN ((1,2),(2,1));


-- =====================================================================
-- T2 · Moderation decision -- half-applied writes must be invisible.
--
-- Run the BEGIN block on connection 1 and leave it uncommitted. From
-- a SEPARATE connection (connection 2), run the SELECT below WHILE
-- connection 1's transaction is still open.
-- =====================================================================

-- -- connection 1 --
BEGIN;
  INSERT INTO ModerationEvent(video_id, state_code, decided_by_type, decided_at)
    VALUES (1, 'taken_down', 'human', '2025-01-02T00:00:00Z');
  -- do NOT commit yet

-- -- connection 2, run while connection 1 is still open --
SELECT * FROM ModerationEvent WHERE video_id = 1 AND state_code = 'taken_down';
-- Empirically confirmed: returns 0 rows under WAL. journal_mode=WAL is
-- what makes this a snapshot read rather than a blocked one -- see the
-- write-up for the measured (and more subtle than expected) comparison
-- against the default rollback-journal mode.

-- -- back on connection 1 --
COMMIT;

-- -- connection 2 again --
SELECT * FROM ModerationEvent WHERE video_id = 1 AND state_code = 'taken_down';
-- now returns the row.


-- =====================================================================
-- T3 · Handle change: twice-a-year limit, and SQLITE_BUSY.
-- =====================================================================

-- (a) Three attempts within one rolling year -- the third must fail.
BEGIN;
  INSERT INTO HandleChangeLog(user_id, changed_at, old_handle, new_handle)
    VALUES (1, '2025-02-01T00:00:00Z', 'user_1_397', 'handle_v2');
  UPDATE AppUser SET handle = 'handle_v2' WHERE user_id = 1;
COMMIT;

BEGIN;
  INSERT INTO HandleChangeLog(user_id, changed_at, old_handle, new_handle)
    VALUES (1, '2025-05-01T00:00:00Z', 'handle_v2', 'handle_v3');
  UPDATE AppUser SET handle = 'handle_v3' WHERE user_id = 1;
COMMIT;

BEGIN;
  -- this INSERT is rejected by trg_handle_change_limit -- 2 prior
  -- changes already exist within the last 365 days of this timestamp
  INSERT INTO HandleChangeLog(user_id, changed_at, old_handle, new_handle)
    VALUES (1, '2025-08-01T00:00:00Z', 'handle_v3', 'handle_v4');
  UPDATE AppUser SET handle = 'handle_v4' WHERE user_id = 1;
COMMIT; -- never reached -- ROLLBACK after the INSERT's IntegrityError

-- Proof: handle is still handle_v3, not handle_v4.
SELECT handle FROM AppUser WHERE user_id = 1;

-- (b) From a second connection, attempt a write while another
-- connection holds an open BEGIN IMMEDIATE transaction:
-- connection 1: BEGIN IMMEDIATE; UPDATE AppUser SET display_name='x' WHERE user_id=2;
-- connection 2 (while 1 is still open): BEGIN IMMEDIATE; UPDATE AppUser SET display_name='y' WHERE user_id=3; COMMIT;
-- Empirically confirmed: connection 2 raises "database is locked"
-- (SQLITE_BUSY surfaced through the Python driver). SQLite allows
-- exactly one writer at a time, even in WAL mode -- this sidesteps
-- the class of write-write conflict a multi-writer engine (e.g.
-- Postgres with concurrent transactions) has to resolve with row-
-- or table-level locking protocols and possible deadlock detection;
-- SQLite instead just serialises all writers, at the cost of
-- throughput under concurrent write load.
