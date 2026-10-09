# Assignment 2 - Task 1: Query Plan Analysis

## Selected Queries
1. **Query 1 (F12):** Recommended clips watched to completion (Multi-table High-Volume Join)
2. **Query 2 (F2):** Watch hours and completion rate per creator (Aggregate Join)
3. **Query 3 (F3):** Videos with no audio track (Filtering / Null Checking)

---

## 1.1 Access Path Classification

### Query 1 (F12: Recommended Clips Watched to Completion)
**`EXPLAIN QUERY PLAN` Output:**
```text
SCAN TABLE ViewSegment AS vs
SEARCH TABLE Recommendation AS r USING AUTOMATIC COVERING INDEX (session_id=?)
SEARCH TABLE Impression AS i USING INTEGER PRIMARY KEY (rowid=?)
