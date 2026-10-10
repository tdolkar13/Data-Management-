-- indexes.sql : Task 2 composite index definitions and creation scripts
-- Run AFTER schema.sql / data load.  Re-runnable (IF NOT EXISTS).

-- 2.1 (1) Impression: equality on join key first, then range column, then payload columns (covering).
--     Serves: JOIN Impression.video_id = Video.video_id  +  WHERE occurred_at >= :t
CREATE INDEX IF NOT EXISTS idx_impression_video_time
  ON Impression(video_id, occurred_at, feed_position, model_version);

-- 2.1 (2) Turn: equality column (model_id), then range/ORDER BY column (occurred_at), then aggregated columns (covering).
--     Serves: WHERE model_id = :m AND occurred_at >= :t  ... SUM(input_tokens), SUM(output_tokens)
CREATE INDEX IF NOT EXISTS idx_turn_model_time_tokens
  ON Turn(model_id, occurred_at, input_tokens, output_tokens);

-- 2.1 (3) ViewSegment: join key first, then the two columns used by SUM(segment_end_ms - segment_start_ms) (covering).
CREATE INDEX IF NOT EXISTS idx_viewsegment_imp_start_end
  ON ViewSegment(impression_id, segment_start_ms, segment_end_ms);

ANALYZE;

-- 2.3 REJECTED (do NOT create): wide, write-heavy, low-selectivity.
--   CREATE INDEX idx_toolcall_args_errored ON ToolCall(arguments_json, errored, turn_id, called_at);
--   * arguments_json is a large TEXT/JSON blob  -> index bloat, slower INSERTs on an append-heavy table
--   * json_extract(arguments_json, '$.x') cannot use a plain B-tree (would need an expression index)
--   * errored is a 0/1 flag (very low selectivity) -> almost no filtering power as a leading/early column

-- ===== REVERT TO BASELINE (used by the benchmark harness) =====
DROP INDEX IF EXISTS idx_impression_video_time;
DROP INDEX IF EXISTS idx_turn_model_time_tokens;
DROP INDEX IF EXISTS idx_viewsegment_imp_start_end;
