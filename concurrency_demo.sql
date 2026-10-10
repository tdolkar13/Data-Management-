-- concurrency_demo.sql : Task 5.2 / 5.3  LOST UPDATE reproduction and BEGIN IMMEDIATE remediation
-- Two sessions (A = AI-turn billing, B = admin credit top-up) touch the SAME balance row.
-- Open two sqlite3 shells (or two DBeaver connections in AUTO-COMMIT mode) on the same file and run the
-- numbered steps in the order shown.  concurrency_runner.py replays exactly this timeline with threads.
--
-- NOTE: ScrollSense has no balance column, so Task 5 adds one small demo table (no existing table is altered).

PRAGMA journal_mode = WAL;
CREATE TABLE IF NOT EXISTS UserCredit (
  user_id  INTEGER PRIMARY KEY REFERENCES AppUser(user_id),
  balance  INTEGER NOT NULL CHECK (balance >= 0)
) STRICT;
DELETE FROM UserCredit WHERE user_id = 1;
INSERT INTO UserCredit(user_id, balance) VALUES (1, 100);   -- start: 100 credits. Correct end state: 100 - 20 + 50 = 130

-- =====================================================================================================
-- PART 1 - THE BUG (autocommit: the read is its own statement, the write is a later statement)
-- Schedule S_bad :  R_A(bal) R_B(bal) W_A(bal) W_B(bal)      precedence graph has the cycle T_A <-> T_B
-- =====================================================================================================
-- step 1  [Session A]  SELECT balance FROM UserCredit WHERE user_id = 1;            -- sees 100
-- step 2  [Session B]  SELECT balance FROM UserCredit WHERE user_id = 1;            -- sees 100
-- step 3  [Session A]  UPDATE UserCredit SET balance = 80  WHERE user_id = 1;       -- 100 - 20 (AI turn cost)
-- step 4  [Session B]  UPDATE UserCredit SET balance = 150 WHERE user_id = 1;       -- 100 + 50 (top-up)  overwrites A
-- step 5  [either]     SELECT balance FROM UserCredit WHERE user_id = 1;            -- 150  (should be 130)  -> LOST UPDATE

-- =====================================================================================================
-- PART 2 - THE FIX: BEGIN IMMEDIATE takes SQLite's write lock BEFORE the read
-- =====================================================================================================
UPDATE UserCredit SET balance = 100 WHERE user_id = 1;   -- reset
-- step 1  [Session A]  BEGIN IMMEDIATE;                                              -- granted
-- step 2  [Session A]  SELECT balance FROM UserCredit WHERE user_id = 1;            -- 100
-- step 3  [Session B]  BEGIN IMMEDIATE;                                              -- BLOCKS (busy_timeout) until A commits
-- step 4  [Session A]  UPDATE UserCredit SET balance = 80 WHERE user_id = 1;  COMMIT;
-- step 5  [Session B]  (lock granted)  SELECT balance FROM UserCredit WHERE user_id = 1;   -- now sees 80
-- step 6  [Session B]  UPDATE UserCredit SET balance = 130 WHERE user_id = 1;  COMMIT;     -- 80 + 50  -> correct
-- step 7  SELECT balance FROM UserCredit WHERE user_id = 1;                         -- 130

-- =====================================================================================================
-- PART 3 - ALTERNATIVES (also tested in the runner)
-- (a) plain BEGIN (deferred): the loser gets "database is locked" when it tries to write on a stale snapshot -> ROLLBACK and retry.
-- (b) single atomic statement, no read-modify-write in the application at all:
--       UPDATE UserCredit SET balance = balance - 20 WHERE user_id = 1;   -- session A
--       UPDATE UserCredit SET balance = balance + 50 WHERE user_id = 1;   -- session B
-- =====================================================================================================
