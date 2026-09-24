PRAGMA foreign_keys = ON;
PRAGMA journal_mode = WAL;

-- =====================================================================
-- Users & Interests (\u00a72.1)
-- =====================================================================

CREATE TABLE AppUser (
  user_id             INTEGER PRIMARY KEY,
  phone_number        TEXT,
  google_account_id   TEXT,
  handle              TEXT NOT NULL,
  display_name        TEXT NOT NULL,
  account_state       TEXT NOT NULL DEFAULT 'active',
  created_at          TEXT NOT NULL,   -- ISO-8601: 'YYYY-MM-DDTHH:MM:SSZ'
  deleted_at          TEXT,            -- NULL = not deleted / not pending deletion
  CHECK (account_state IN ('active','deactivated','pending_deletion')),
  CHECK (phone_number IS NOT NULL OR google_account_id IS NOT NULL),
  CHECK (length(trim(handle)) > 0)
) STRICT;

-- A5: unique among ACTIVE accounts only. A partial index expresses this
-- declaratively -- no application-layer check needed after all (a more
-- optimistic answer than the one given in C.1/D.1's inline notes).
CREATE UNIQUE INDEX ux_appuser_handle_active
  ON AppUser(handle COLLATE NOCASE)
  WHERE account_state = 'active';

-- Handle changes are limited to twice per rolling year (\u00a72.1). SQLite's
-- CHECK constraints can't run a cross-row COUNT, so this needs a log
-- table plus a trigger. The trigger keys off the log row's OWN
-- changed_at (supplied by the application in the same statement) rather
-- than datetime('now'), so it works correctly against historical/
-- synthetic timestamps, not just real wall-clock time.
CREATE TABLE HandleChangeLog (
  change_id   INTEGER PRIMARY KEY,
  user_id     INTEGER NOT NULL,
  changed_at  TEXT NOT NULL,
  old_handle  TEXT NOT NULL,
  new_handle  TEXT NOT NULL,
  FOREIGN KEY (user_id) REFERENCES AppUser(user_id) ON DELETE CASCADE
) STRICT;

CREATE TRIGGER trg_handle_change_limit
BEFORE INSERT ON HandleChangeLog
WHEN (
  SELECT COUNT(*) FROM HandleChangeLog
  WHERE user_id = NEW.user_id
    AND changed_at >= date(NEW.changed_at, '-365 days')
) >= 2
BEGIN
  SELECT RAISE(ABORT, 'handle change limit: max 2 per rolling year');
END;

CREATE TABLE InterestCategory (
  category_id   INTEGER PRIMARY KEY,
  name          TEXT NOT NULL UNIQUE
) STRICT;

CREATE TABLE UserDeclaredInterest (
  user_id       INTEGER NOT NULL,
  category_id   INTEGER NOT NULL,
  declared_at   TEXT NOT NULL,
  PRIMARY KEY (user_id, category_id),
  FOREIGN KEY (user_id) REFERENCES AppUser(user_id) ON DELETE CASCADE,
  FOREIGN KEY (category_id) REFERENCES InterestCategory(category_id) ON DELETE RESTRICT
) STRICT;

CREATE TABLE UserInferredInterest (
  user_id            INTEGER NOT NULL,
  category_id        INTEGER NOT NULL,
  as_of_week         TEXT NOT NULL,   -- ISO-8601 date, Monday of the refresh week
  confidence_score   REAL NOT NULL,
  PRIMARY KEY (user_id, category_id, as_of_week),
  FOREIGN KEY (user_id) REFERENCES AppUser(user_id) ON DELETE CASCADE,
  FOREIGN KEY (category_id) REFERENCES InterestCategory(category_id) ON DELETE RESTRICT,
  CHECK (confidence_score BETWEEN 0.0 AND 1.0)
) STRICT;

-- A4: suppression is its own durable fact, never overwritten by the
-- weekly refresh job that writes UserInferredInterest rows.
CREATE TABLE InterestSuppression (
  user_id         INTEGER NOT NULL,
  category_id     INTEGER NOT NULL,
  suppressed_at   TEXT NOT NULL,
  PRIMARY KEY (user_id, category_id),
  FOREIGN KEY (user_id) REFERENCES AppUser(user_id) ON DELETE CASCADE,
  FOREIGN KEY (category_id) REFERENCES InterestCategory(category_id) ON DELETE RESTRICT
) STRICT;

CREATE TABLE CreatorTierPeriod (
  tier_period_id   INTEGER PRIMARY KEY,
  creator_id       INTEGER NOT NULL,
  tier             TEXT NOT NULL,
  valid_from       TEXT NOT NULL,
  valid_to         TEXT,              -- NULL = currently in force
  FOREIGN KEY (creator_id) REFERENCES AppUser(user_id) ON DELETE CASCADE,
  CHECK (tier IN ('standard','rising','partner','elite')),
  CHECK (valid_to IS NULL OR valid_to > valid_from)
) STRICT;

-- =====================================================================
-- Creators & Content (\u00a72.2)
-- =====================================================================
-- Video and AudioTrack reference each other (a video optionally uses a
-- track; a track optionally names the video it originated on). SQLite
-- resolves FK targets at INSERT/PRAGMA-check time, not CREATE TABLE
-- time, so plain forward references between the two tables work --
-- DEFERRABLE INITIALLY DEFERRED is reserved below for the one place a
-- single INSERT genuinely needs it (none here, since both FKs are
-- nullable and can be populated after the fact).

CREATE TABLE Video (
  video_id        INTEGER PRIMARY KEY,
  owner_id        INTEGER NOT NULL,
  duration_ms     INTEGER NOT NULL,
  caption         TEXT NOT NULL DEFAULT '',
  audio_track_id  INTEGER,           -- NULL = no audio track attached
  uploaded_at     TEXT NOT NULL,
  FOREIGN KEY (owner_id) REFERENCES AppUser(user_id) ON DELETE RESTRICT,
  FOREIGN KEY (audio_track_id) REFERENCES AudioTrack(track_id) ON DELETE SET NULL,
  CHECK (duration_ms BETWEEN 20000 AND 90000),
  CHECK (length(caption) <= 2200)
) STRICT;

CREATE TABLE AudioTrack (
  track_id            INTEGER PRIMARY KEY,
  source_type         TEXT NOT NULL,
  original_video_id   INTEGER,        -- set when source_type = 'original'
  catalogue_ref       TEXT,           -- set when source_type = 'licensed'
  FOREIGN KEY (original_video_id) REFERENCES Video(video_id) ON DELETE SET NULL,
  CHECK (source_type IN ('original','licensed')),
  CHECK (
    (source_type = 'original' AND catalogue_ref IS NULL)
    OR
    (source_type = 'licensed' AND original_video_id IS NULL AND catalogue_ref IS NOT NULL)
  )
) STRICT;

CREATE TABLE Hashtag (
  hashtag_id   INTEGER PRIMARY KEY,
  tag_text     TEXT NOT NULL UNIQUE COLLATE NOCASE,  -- normalised lowercase on insert
  CHECK (tag_text = lower(tag_text))
) STRICT;

CREATE TABLE VideoHashtag (
  video_id     INTEGER NOT NULL,
  hashtag_id   INTEGER NOT NULL,
  PRIMARY KEY (video_id, hashtag_id),
  FOREIGN KEY (video_id) REFERENCES Video(video_id) ON DELETE CASCADE,
  FOREIGN KEY (hashtag_id) REFERENCES Hashtag(hashtag_id) ON DELETE RESTRICT
) STRICT;

-- A6: no current_state column anywhere on Video. This table IS the
-- source of truth; "current state" is a read (see v_video_current_state
-- in Deliverable G), never a write.
-- Moderation states get a lookup table, not a CHECK -- Trust & Safety
-- is explicitly named as a group that may want to add a new state
-- (\u00a72.6), so this is the "queryable and extensible" case, not the
-- "cheap and invisible, never changes" case the task sheet contrasts it
-- with.
CREATE TABLE ModerationStateLookup (
  state_code   TEXT PRIMARY KEY
) STRICT;
INSERT INTO ModerationStateLookup(state_code) VALUES
  ('pending'), ('live'), ('age_restricted'), ('demoted'), ('taken_down');

CREATE TABLE ModerationEvent (
  moderation_event_id   INTEGER PRIMARY KEY,
  video_id              INTEGER NOT NULL,
  state_code            TEXT NOT NULL,
  decided_by_type       TEXT NOT NULL,
  decided_by_id         TEXT,          -- NULL only when decided_by_type = 'classifier'
                                        -- and the classifier run has no stable ID
  decided_at            TEXT NOT NULL,
  FOREIGN KEY (video_id) REFERENCES Video(video_id) ON DELETE CASCADE,
  FOREIGN KEY (state_code) REFERENCES ModerationStateLookup(state_code) ON DELETE RESTRICT,
  CHECK (decided_by_type IN ('classifier','human'))
) STRICT;

-- =====================================================================
-- The Social Graph (\u00a72.3)
-- =====================================================================

-- A7: ended, never deleted -- the graph must be reconstructable as of
-- any past timestamp (\u00a73).
CREATE TABLE Follow (
  follow_id     INTEGER PRIMARY KEY,
  follower_id   INTEGER NOT NULL,
  followee_id   INTEGER NOT NULL,
  started_at    TEXT NOT NULL,
  ended_at      TEXT,                 -- NULL = still following
  FOREIGN KEY (follower_id) REFERENCES AppUser(user_id) ON DELETE CASCADE,
  FOREIGN KEY (followee_id) REFERENCES AppUser(user_id) ON DELETE CASCADE,
  CHECK (follower_id <> followee_id),
  CHECK (ended_at IS NULL OR ended_at > started_at)
) STRICT;

CREATE TABLE Block (
  blocker_id   INTEGER NOT NULL,
  blocked_id   INTEGER NOT NULL,
  blocked_at   TEXT NOT NULL,
  PRIMARY KEY (blocker_id, blocked_id),
  FOREIGN KEY (blocker_id) REFERENCES AppUser(user_id) ON DELETE CASCADE,
  FOREIGN KEY (blocked_id) REFERENCES AppUser(user_id) ON DELETE CASCADE,
  CHECK (blocker_id <> blocked_id)
) STRICT;

CREATE TABLE Mute (
  muter_id   INTEGER NOT NULL,
  muted_id   INTEGER NOT NULL,
  muted_at   TEXT NOT NULL,
  PRIMARY KEY (muter_id, muted_id),
  FOREIGN KEY (muter_id) REFERENCES AppUser(user_id) ON DELETE CASCADE,
  FOREIGN KEY (muted_id) REFERENCES AppUser(user_id) ON DELETE CASCADE,
  CHECK (muter_id <> muted_id)
) STRICT;

-- =====================================================================
-- Watch Telemetry (\u00a72.4)
-- =====================================================================

-- A12: always a stored row, whether or not the clip crosses the 300ms
-- view threshold -- this is the funnel's denominator.
CREATE TABLE Impression (
  impression_id   INTEGER PRIMARY KEY,
  video_id        INTEGER NOT NULL,
  user_id         INTEGER NOT NULL,
  occurred_at     TEXT NOT NULL,
  feed_position   INTEGER NOT NULL,
  model_version   TEXT NOT NULL,
  FOREIGN KEY (video_id) REFERENCES Video(video_id) ON DELETE CASCADE,
  FOREIGN KEY (user_id) REFERENCES AppUser(user_id) ON DELETE CASCADE,
  CHECK (feed_position >= 0)
) STRICT;

-- A2: an impression can produce zero, one, or many segments.
CREATE TABLE ViewSegment (
  view_segment_id    INTEGER PRIMARY KEY,
  impression_id      INTEGER NOT NULL,
  segment_start_ms   INTEGER NOT NULL,
  segment_end_ms     INTEGER NOT NULL,
  FOREIGN KEY (impression_id) REFERENCES Impression(impression_id) ON DELETE CASCADE,
  CHECK (segment_end_ms > segment_start_ms),
  CHECK (segment_start_ms >= 0)
) STRICT;

-- A8: retraction is a first-class negative signal, not a deleted like.
CREATE TABLE LikeEvent (
  like_event_id   INTEGER PRIMARY KEY,
  video_id        INTEGER NOT NULL,
  user_id         INTEGER NOT NULL,
  event_type      TEXT NOT NULL,
  occurred_at     TEXT NOT NULL,
  FOREIGN KEY (video_id) REFERENCES Video(video_id) ON DELETE CASCADE,
  FOREIGN KEY (user_id) REFERENCES AppUser(user_id) ON DELETE CASCADE,
  CHECK (event_type IN ('like','retract'))
) STRICT;

CREATE TABLE SaveEvent (
  save_event_id   INTEGER PRIMARY KEY,
  video_id        INTEGER NOT NULL,
  user_id         INTEGER NOT NULL,
  occurred_at     TEXT NOT NULL,
  FOREIGN KEY (video_id) REFERENCES Video(video_id) ON DELETE CASCADE,
  FOREIGN KEY (user_id) REFERENCES AppUser(user_id) ON DELETE CASCADE
) STRICT;

CREATE TABLE ShareEvent (
  share_event_id   INTEGER PRIMARY KEY,
  video_id         INTEGER NOT NULL,
  user_id          INTEGER NOT NULL,
  destination      TEXT NOT NULL,
  occurred_at      TEXT NOT NULL,
  FOREIGN KEY (video_id) REFERENCES Video(video_id) ON DELETE CASCADE,
  FOREIGN KEY (user_id) REFERENCES AppUser(user_id) ON DELETE CASCADE,
  CHECK (destination IN ('whatsapp','instagram','copied_link'))
) STRICT;

-- A10: RESTRICT while the deleting user is inside the 30-day recovery
-- window, SET NULL once it lapses. SQLite has one ON DELETE action per
-- FK, not a time-conditional one, so the *declarative* choice here is
-- RESTRICT (the safer default); the SET-NULL-after-30-days half of A10
-- is enforced by a scheduled application job that runs after the
-- window closes, not by this constraint alone.
CREATE TABLE CommentEvent (
  comment_id    INTEGER PRIMARY KEY,
  video_id      INTEGER NOT NULL,
  user_id       INTEGER,             -- NULL = commenter's account was later anonymised
  body          TEXT NOT NULL,
  occurred_at   TEXT NOT NULL,
  FOREIGN KEY (video_id) REFERENCES Video(video_id) ON DELETE CASCADE,
  FOREIGN KEY (user_id) REFERENCES AppUser(user_id) ON DELETE RESTRICT,
  CHECK (length(body) <= 500)
) STRICT;

CREATE TABLE ReportEvent (
  report_id     INTEGER PRIMARY KEY,
  video_id      INTEGER NOT NULL,
  user_id       INTEGER NOT NULL,
  reason        TEXT NOT NULL,
  occurred_at   TEXT NOT NULL,
  FOREIGN KEY (video_id) REFERENCES Video(video_id) ON DELETE CASCADE,
  FOREIGN KEY (user_id) REFERENCES AppUser(user_id) ON DELETE CASCADE
) STRICT;

CREATE TABLE NotInterestedEvent (
  not_interested_id   INTEGER PRIMARY KEY,
  video_id            INTEGER NOT NULL,
  user_id             INTEGER NOT NULL,
  occurred_at         TEXT NOT NULL,
  FOREIGN KEY (video_id) REFERENCES Video(video_id) ON DELETE CASCADE,
  FOREIGN KEY (user_id) REFERENCES AppUser(user_id) ON DELETE CASCADE
) STRICT;

-- =====================================================================
-- The Agent Layer (\u00a72.5)
-- =====================================================================

CREATE TABLE PromptTemplateVersion (
  template_version_id   INTEGER PRIMARY KEY,
  template_name         TEXT NOT NULL,
  version_no            INTEGER NOT NULL,
  template_text         TEXT NOT NULL,
  created_at            TEXT NOT NULL,
  UNIQUE (template_name, version_no)
) STRICT;

CREATE TABLE ModelPricingPeriod (
  price_period_id     INTEGER PRIMARY KEY,
  model_id            TEXT NOT NULL,
  input_rate          REAL NOT NULL,
  output_rate         REAL NOT NULL,
  cached_input_rate   REAL NOT NULL,
  valid_from          TEXT NOT NULL,
  valid_to            TEXT,          -- NULL = currently in force
  CHECK (valid_to IS NULL OR valid_to > valid_from),
  CHECK (input_rate >= 0 AND output_rate >= 0 AND cached_input_rate >= 0)
) STRICT;

CREATE TABLE AgentSession (
  session_id   INTEGER PRIMARY KEY,
  user_id      INTEGER NOT NULL,
  started_at   TEXT NOT NULL,
  FOREIGN KEY (user_id) REFERENCES AppUser(user_id) ON DELETE CASCADE
) STRICT;

CREATE TABLE Turn (
  turn_id               INTEGER PRIMARY KEY,
  session_id            INTEGER NOT NULL,
  sequence_no           INTEGER NOT NULL,
  user_message          TEXT NOT NULL,
  assistant_message     TEXT NOT NULL,
  template_version_id   INTEGER NOT NULL,
  model_id              TEXT NOT NULL,
  temperature           REAL NOT NULL,
  input_tokens          INTEGER NOT NULL,
  output_tokens         INTEGER NOT NULL,
  cached_tokens         INTEGER NOT NULL DEFAULT 0,
  occurred_at           TEXT NOT NULL,
  FOREIGN KEY (session_id) REFERENCES AgentSession(session_id) ON DELETE CASCADE,
  FOREIGN KEY (template_version_id) REFERENCES PromptTemplateVersion(template_version_id) ON DELETE RESTRICT,
  UNIQUE (session_id, sequence_no),
  CHECK (temperature >= 0.0),
  CHECK (input_tokens >= 0 AND output_tokens >= 0 AND cached_tokens >= 0)
) STRICT;

-- E.4: the one deliberately-chosen JSON column pair in the schema.
-- arguments_json/result_json genuinely vary in shape per tool
-- (search_videos vs get_user_history vs fetch_trending_audio), so a
-- fixed relational shape would mean either a wide sparse table or one
-- side-table per tool -- both worse than a guarded JSON blob here.
CREATE TABLE ToolCall (
  tool_call_id     INTEGER PRIMARY KEY,
  turn_id          INTEGER NOT NULL,
  parent_call_id   INTEGER,          -- NULL = top-level call for this turn
  tool_name        TEXT NOT NULL,
  arguments_json   TEXT NOT NULL,
  result_json      TEXT,             -- NULL = call errored before returning a result
  latency_ms       INTEGER NOT NULL,
  errored          INTEGER NOT NULL DEFAULT 0,
  called_at        TEXT NOT NULL,
  FOREIGN KEY (turn_id) REFERENCES Turn(turn_id) ON DELETE CASCADE,
  FOREIGN KEY (parent_call_id) REFERENCES ToolCall(tool_call_id) ON DELETE CASCADE,
  CHECK (errored IN (0,1)),
  CHECK (latency_ms >= 0),
  CHECK (json_valid(arguments_json)),
  CHECK (result_json IS NULL OR json_valid(result_json))
) STRICT;

CREATE TABLE Recommendation (
  recommendation_id   INTEGER PRIMARY KEY,
  turn_id             INTEGER NOT NULL,
  video_id            INTEGER NOT NULL,
  position            INTEGER NOT NULL,
  FOREIGN KEY (turn_id) REFERENCES Turn(turn_id) ON DELETE CASCADE,
  FOREIGN KEY (video_id) REFERENCES Video(video_id) ON DELETE RESTRICT,
  UNIQUE (turn_id, position),
  CHECK (position >= 0)
) STRICT;

CREATE TABLE JudgeScore (
  judge_score_id   INTEGER PRIMARY KEY,
  turn_id          INTEGER NOT NULL UNIQUE,
  helpfulness      REAL NOT NULL,
  groundedness     REAL NOT NULL,
  safety           REAL NOT NULL,
  judged_at        TEXT NOT NULL,
  FOREIGN KEY (turn_id) REFERENCES Turn(turn_id) ON DELETE CASCADE,
  CHECK (helpfulness BETWEEN 0 AND 5),
  CHECK (groundedness BETWEEN 0 AND 5),
  CHECK (safety BETWEEN 0 AND 5)
) STRICT;

CREATE TABLE UserRating (
  rating_id   INTEGER PRIMARY KEY,
  turn_id     INTEGER NOT NULL UNIQUE,
  thumbs      TEXT NOT NULL,
  rated_at    TEXT NOT NULL,
  FOREIGN KEY (turn_id) REFERENCES Turn(turn_id) ON DELETE CASCADE,
  CHECK (thumbs IN ('up','down'))
) STRICT;

-- =====================================================================
-- Indexes supporting the Deliverable F query set (not exhaustive)
-- =====================================================================
CREATE INDEX ix_video_owner            ON Video(owner_id);
CREATE INDEX ix_impression_video       ON Impression(video_id);
CREATE INDEX ix_impression_user_time   ON Impression(user_id, occurred_at);
CREATE INDEX ix_viewsegment_impression ON ViewSegment(impression_id);
CREATE INDEX ix_moderationevent_video  ON ModerationEvent(video_id, decided_at);
CREATE INDEX ix_toolcall_parent        ON ToolCall(parent_call_id);
CREATE INDEX ix_turn_session           ON Turn(session_id, sequence_no);
