# DA3406 - Data Management: Assignment 2

**Student:** Thupten Dolkar  **ID:** GE26Z834
**Database:** `scrollsense.db` (SQLite, ScrollSense schema) - not stored in this repo; place it next to these files.

## Submission overview

| Task | What | Where |
|---|---|---|
| 1 Access paths and cost arithmetic | plans + classification (1.1), hand block-I/O calculation (1.2), planner rationale (1.3) | `queries.sql` [F1,F2,F5], `plan_analysis.md`, `report.pdf` |
| 2 Composite index design | three covering composite indexes + one rejected index, before/after plans and timings | `indexes.sql`, `plan_analysis.md` |
| 3 Join algorithms | J1/J2 plans, cost formulas (BNLJ/SMJ/HJ/INLJ), 3-table join order | `queries.sql` [J1,J2,J3], `plan_analysis.md`, `report.pdf` |
| 4 Predicate pushdown | algebra trees, equivalence rule, outer-join exception, naive vs pushed-down SQL | `queries.sql` [N4,O4,A4,B4,C4], `plan_analysis.md`, `report.pdf` |
| 5 Concurrency | precedence graphs, lost-update anomaly, `BEGIN IMMEDIATE` fix | `concurrency_demo.sql`, `concurrency_runner.py`, `plan_analysis.md`, `report.pdf` |

## Files

```
README.md               this file
schema.sql              baseline schema (no Task 2 indexes); loads cleanly into an empty SQLite DB
indexes.sql             Task 2 composite indexes (+ rejected index as comments, + revert section)
queries.sql             all benchmark queries and variants, parameters listed at the top
plan_analysis.md        raw EXPLAIN QUERY PLAN output + timings (before/after) + Task 5 traces
concurrency_demo.sql    Task 5 lost-update timeline and BEGIN IMMEDIATE remediation (two-session script)
concurrency_runner.py   extra helper: replays concurrency_demo.sql with two real connections
report.pdf              the compiled Assignment 2 report
```

## How to reproduce

```bash
sqlite3 scrollsense.db < indexes.sql          # apply Task 2 indexes (idempotent)
python concurrency_runner.py scrollsense.db   # Task 5 demo on a throw-away copy of the DB
```
Queries use named parameters (`:t7`, `:since`, `:h`, ...); values used for the recorded runs are listed at the top of `queries.sql`. Requires SQLite >= 3.35 (`AS MATERIALIZED`).

## Known differences to check before submitting

- **Scale.** Task 1.2 assumes 1,000,000 Video rows and Task 2.2 quotes SCALE=50 timings. The supplied `scrollsense.db` has 20,000 Video / 304,198 Impression / 134,977 ViewSegment rows, so `plan_analysis.md` shows smaller absolute times (plan shapes agree).
- **Task 3.3.** On the supplied schema there is no index on `ToolCall.turn_id`, so SQLite scans ToolCall first instead of AgentSession; with that index it picks the AgentSession -> Turn -> ToolCall order. `plan_analysis.md` shows both plans.
- **Task 4.2.** The supplied data has 0 ToolCall rows with `errored = 1`, so the report's pair returns no rows here. The equal-plan conclusion still holds; a selective supplement (A4/B4/C4) is included where the rewrite visibly matters (about 33 ms without planner statistics, about 0.26 ms with `ANALYZE` or hand-pushed, about 446 ms for the literal naive plan).
- **Task 5.** ScrollSense has no balance column, so `concurrency_demo.sql` adds a small `UserCredit` table. `report.pdf` is an unedited export of the Google Doc and still has the `display_name` screenshots in 5.3 (two blind overwrites, so `BEGIN IMMEDIATE` there does not change the final value), a stray "Wait, if..." line in the 5.2 precedence list, and raw LaTeX in 4.1.
- **F1/F2/F5 and the Task 2/3 benchmark queries** in `queries.sql` were written from the report's descriptions of each query; paste your exact text over them if your screenshots differ.
