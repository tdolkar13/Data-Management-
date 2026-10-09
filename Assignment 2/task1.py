# !/usr/bin/env python3
"""
generate_data.py -- ScrollSense synthetic data generator (A2 scale-capable).

Usage
  python3 generate_data.py [db_path]            # everything, ONE transaction
  python3 generate_data.py db_path --phase P    # a single phase (P = 1, 2, 3:<chunk>, 4, 5)

Default mode loads schema.sql fresh and populates every table inside ONE
transaction (PRAGMA foreign_keys = ON). --phase exists only so a runner with a
per-command time limit can load the same data in slices; every phase draws from
its own RNG stream seeded by (SEED, phase[, chunk]), so the phased load and the
one-shot load produce byte-identical databases.

Changelog vs A1 (recorded in the A2 changelog): the A1 generator inserted one row
per Python call. At SCALE=50 (15M impressions) that did not finish in reasonable
time, so the hot loops were rewritten with numpy and executemany. Distributions
and table semantics are unchanged; the schema is untouched.
"""
import argparse
import datetime
import json
import math
import re
import sqlite3

import numpy as np

# ---- parameters (Assignment 2 will change only this block) ----
SEED = 21000000          # <-- replace with your actual roll number
N_USERS = 5_000
N_VIDEOS = 20_000
N_IMPRESSIONS = 300_000
N_AGENT_SESSIONS = 2_000
SCALE = 50               # A2: 50
# ---------------------------------------------------------------

EPOCH64 = np.datetime64("2025-01-01T00:00:00")
EPOCH_DT = datetime.datetime(2025, 1, 1)
HOUR_P = np.array([1] * 6 + [2] * 6 + [4] * 6 + [6] * 6, dtype=float)
HOUR_P /= HOUR_P.sum()
CATEGORIES = ["comedy", "cooking", "fitness", "music", "gaming",
              "study_tips", "fashion", "sports", "travel", "pets"]
TAGS = ["funny", "fyp", "cooking", "trend", "viral", "dance", "study"]
CH = min(1_000_000, N_IMPRESSIONS * SCALE)          # impressions per telemetry chunk
N_CHUNKS = math.ceil(N_IMPRESSIONS * SCALE / CH)


def rng_for(*key):
    return np.random.default_rng([SEED, *key])


def iso(sec):
    """int64 seconds-since-2025-01-01 (numpy array) -> list of ISO-8601 'Z' strings."""
    dt = EPOCH64 + np.asarray(sec, dtype=np.int64).astype("timedelta64[s]")
    return np.datetime_as_string(dt, unit="s", timezone="UTC").tolist()


def iso1(sec):
    return (EPOCH_DT + datetime.timedelta(seconds=int(sec))).strftime("%Y-%m-%dT%H:%M:%SZ")


def ts_seconds(rng, n, days_span):
    """Daily-rhythm timestamps: uniform day, evening-weighted hour (as in A1)."""
    day = np.floor(rng.uniform(0, days_span, n)).astype(np.int64)
    hour = rng.choice(24, n, p=HOUR_P)
    return day * 86400 + hour * 3600 + rng.integers(0, 60, n) * 60 + rng.integers(0, 60, n)


def ins(cur, sql, rows):
    cur.executemany(sql, rows)


# ------------------------------------------------------------------ phases

def phase1(cur):
    """Reference data, users, interests, creators, tracks, videos, moderation, hashtags."""
    rng = rng_for(1)
    n_users, n_videos = N_USERS * SCALE, N_VIDEOS * SCALE

    ins(cur, "INSERT INTO InterestCategory(category_id, name) VALUES (?,?)",
        list(enumerate(CATEGORIES, start=1)))

    # ---- users
    uid = np.arange(1, n_users + 1)
    created = ts_seconds(rng, n_users, 730)
    state = rng.choice(3, n_users, p=[0.92, 0.06, 0.02])
    states = np.array(["active", "deactivated", "pending_deletion"])[state]
    deleted = [None] * n_users
    nz = np.nonzero(state != 0)[0]
    del_ts = iso(created[nz] + rng.integers(1, 701, nz.size) * 86400)
    for k, i in enumerate(nz.tolist()):
        deleted[i] = del_ts[k]
    via_phone = rng.random(n_users) < 0.6                 # ONE draw decides signup method (A1 bug fix)
    phones = rng.integers(6_000_000_000, 10_000_000_000, n_users)
    gsuf = rng.integers(1000, 10_000, n_users)
    hsuf = rng.integers(100, 1000, n_users)
    ul = uid.tolist()
    ins(cur,
        "INSERT INTO AppUser(user_id, phone_number, google_account_id, handle, display_name, account_state, created_at, deleted_at) VALUES (?,?,?,?,?,?,?,?)",
        zip(ul,
            [f"+91{p}" if v else None for p, v in zip(phones.tolist(), via_phone.tolist())],
            [None if v else f"g_{u}_{g}" for u, g, v in zip(ul, gsuf.tolist(), via_phone.tolist())],
            [f"user_{u}_{h}" for u, h in zip(ul, hsuf.tolist())],
            [f"User {u}" for u in ul],
            states.tolist(), iso(created), deleted))

    # ---- declared interests: 1..4 distinct categories per user
    k = rng.integers(1, 5, n_users)
    rank = np.argsort(np.argsort(rng.random((n_users, len(CATEGORIES))), axis=1), axis=1)
    ui, ci = np.nonzero(rank < k[:, None])
    ins(cur, "INSERT INTO UserDeclaredInterest(user_id, category_id, declared_at) VALUES (?,?,?)",
        zip((ui + 1).tolist(), (ci + 1).tolist(), iso(created[ui])))

    # ---- weekly inferred interests (1..6 weeks per user, one inferred category)
    n_weeks = rng.integers(1, 7, n_users)
    inf_cat = rng.integers(1, len(CATEGORIES) + 1, n_users)
    base = rng.uniform(0.2, 0.9, n_users)
    urep = np.repeat(np.arange(n_users), n_weeks)
    widx = np.arange(urep.size) - np.repeat(np.cumsum(n_weeks) - n_weeks, n_weeks)
    score = np.clip(base[urep] + rng.uniform(-0.05, 0.05, urep.size), 0, 1).round(3)
    ins(cur, "INSERT INTO UserInferredInterest(user_id, category_id, as_of_week, confidence_score) VALUES (?,?,?,?)",
        zip((urep + 1).tolist(), inf_cat[urep].tolist(), iso(created[urep] + widx * 7 * 86400), score.tolist()))
    sup = np.nonzero(rng.random(n_users) < 0.04)[0]
    sup_w = (rng.random(sup.size) * n_weeks[sup]).astype(int) + 1
    sup_w = np.minimum(sup_w, n_weeks[sup])
    ins(cur, "INSERT OR IGNORE INTO InterestSuppression(user_id, category_id, suppressed_at) VALUES (?,?,?)",
        zip((sup + 1).tolist(), inf_cat[sup].tolist(), iso(created[sup] + sup_w * 7 * 86400)))

    # ---- creators (~15% of users) and tier history
    creators = np.sort(rng.choice(n_users, int(n_users * 0.15), replace=False) + 1)
    n_tiers = rng.integers(1, 4, creators.size)
    start0 = ts_seconds(rng, creators.size, 600)
    tier_names = ["standard", "rising", "partner"]
    rows, tp = [], 1
    for c, nt, s in zip(creators.tolist(), n_tiers.tolist(), start0.tolist()):
        for j in range(nt):
            last = j == nt - 1
            end = None if last else s + int(rng.integers(30, 121)) * 86400
            rows.append((tp, c, tier_names[j], iso1(s), None if end is None else iso1(end)))
            tp += 1
            if end is not None:
                s = end
    ins(cur, "INSERT INTO CreatorTierPeriod(tier_period_id, creator_id, tier, valid_from, valid_to) VALUES (?,?,?,?,?)", rows)

    # ---- audio tracks (~1 per 50 videos)
    n_tracks = max(1, n_videos // 50)
    lic = rng.random(n_tracks) < 0.4
    ins(cur, "INSERT INTO AudioTrack(track_id, source_type, original_video_id, catalogue_ref) VALUES (?,?,?,?)",
        [(t, "licensed" if l else "original", None, f"catalog_{t}" if l else None)
         for t, l in zip(range(1, n_tracks + 1), lic.tolist())])

    # ---- videos
    vid = np.arange(1, n_videos + 1)
    owner = creators[rng.integers(0, creators.size, n_videos)]
    uploaded = ts_seconds(rng, n_videos, 365)
    uses_track = rng.random(n_videos) < 0.7
    track = rng.integers(1, n_tracks + 1, n_videos)
    dur = rng.integers(20000, 90001, n_videos)
    funny = rng.random(n_videos) < 0.3
    vl = vid.tolist()
    ins(cur, "INSERT INTO Video(video_id, owner_id, duration_ms, caption, audio_track_id, uploaded_at) VALUES (?,?,?,?,?,?)",
        zip(vl, owner.tolist(), dur.tolist(),
            [f"caption for clip {v} #{'funny' if f else 'trend'}" for v, f in zip(vl, funny.tolist())],
            [t if u else None for t, u in zip(track.tolist(), uses_track.tolist())],
            iso(uploaded)))
    # backfill ~0.5% of videos as the "original" video of a random original track
    bf = np.nonzero(rng.random(n_videos) < 0.005)[0]
    ins(cur, "UPDATE AudioTrack SET original_video_id = ? WHERE track_id = ? AND source_type = 'original' AND original_video_id IS NULL",
        zip((bf + 1).tolist(), rng.integers(1, n_tracks + 1, bf.size).tolist()))

    # ---- moderation history: mostly 1 event; 12% have 2, 3% have 3
    n_ev = rng.choice([1, 2, 3], n_videos, p=[0.85, 0.12, 0.03])
    later = np.array(["live", "demoted", "age_restricted", "taken_down"])
    s1 = np.where(n_ev == 1, np.where(rng.random(n_videos) < 0.9, "live", "pending"), "pending")
    s2 = later[rng.integers(0, 4, n_videos)]
    s3 = later[rng.integers(0, 4, n_videos)]
    t1 = uploaded + rng.integers(1, 601, n_videos) * 60
    t2 = t1 + rng.integers(1, 601, n_videos) * 60
    t3 = t2 + rng.integers(1, 601, n_videos) * 60
    for mask, st, tt in ((np.ones(n_videos, bool), s1, t1), (n_ev >= 2, s2, t2), (n_ev >= 3, s3, t3)):
        idx = np.nonzero(mask)[0]
        by_cls = rng.random(idx.size) < 0.8
        by_rev = rng.random(idx.size) < 0.8
        rev = rng.integers(1, 51, idx.size)
        ins(cur, "INSERT INTO ModerationEvent(video_id, state_code, decided_by_type, decided_by_id, decided_at) VALUES (?,?,?,?,?)",
            zip((idx + 1).tolist(), st[idx].tolist(),
                ["classifier" if c else "human" for c in by_cls.tolist()],
                [None if r else f"reviewer_{n}" for r, n in zip(by_rev.tolist(), rev.tolist())],
                iso(tt[idx])))

    # ---- hashtags: 0..4 per video (7 distinct tags; duplicates ignored)
    ins(cur, "INSERT INTO Hashtag(tag_text) VALUES (?)", [(t,) for t in TAGS])
    n_tag = rng.integers(0, 5, n_videos)
    vrep = np.repeat(vid, n_tag)
    trep = rng.integers(1, len(TAGS) + 1, vrep.size)
    pair = np.unique(vrep.astype(np.int64) * 16 + trep)
    ins(cur, "INSERT OR IGNORE INTO VideoHashtag(video_id, hashtag_id) VALUES (?,?)",
        zip((pair // 16).tolist(), (pair % 16).tolist()))


def phase2(cur):
    """Social graph."""
    rng = rng_for(2)
    n_users = N_USERS * SCALE
    m = n_users * 3
    a = rng.integers(1, n_users + 1, m)
    b = (a - 1 + rng.integers(1, n_users, m)) % n_users + 1      # b != a
    start = ts_seconds(rng, m, 500)
    ended = rng.random(m) < 0.1
    end_ts = start + rng.integers(1, 201, m) * 86400
    s_iso, e_iso = iso(start), iso(end_ts)
    ins(cur, "INSERT INTO Follow(follower_id, followee_id, started_at, ended_at) VALUES (?,?,?,?)",
        zip(a.tolist(), b.tolist(), s_iso, [e if x else None for e, x in zip(e_iso, ended.tolist())]))
    for table, cols, frac in (("Block", "blocker_id, blocked_id, blocked_at", 0.02),
                              ("Mute", "muter_id, muted_id, muted_at", 0.08)):
        k = int(n_users * frac)
        x = rng.integers(1, n_users + 1, k)
        y = (x - 1 + rng.integers(1, n_users, k)) % n_users + 1
        ins(cur, f"INSERT OR IGNORE INTO {table}({cols}) VALUES (?,?,?)",
            zip(x.tolist(), y.tolist(), iso(ts_seconds(rng, k, 365))))


def load_durations(cur, n_videos):
    dur = np.zeros(n_videos + 1, dtype=np.int64)
    for v, d in cur.execute("SELECT video_id, duration_ms FROM Video"):
        dur[v] = d
    return dur


def phase3(cur, chunk):
    """One chunk of the watch-telemetry funnel (impressions, view segments, signals)."""
    rng = rng_for(3, chunk)
    n_users, n_videos = N_USERS * SCALE, N_VIDEOS * SCALE
    total = N_IMPRESSIONS * SCALE
    n = min(CH, total - chunk * CH)
    dur = load_durations(cur, n_videos)

    imp_id = chunk * CH + np.arange(1, n + 1)
    uid = rng.integers(1, n_users + 1, n)
    vid = rng.integers(1, n_videos + 1, n)
    occ = ts_seconds(rng, n, 365)
    feed = (50 * (1 - rng.random(n)) ** 2).astype(int)            # A1 power_law_int(0, 50)
    ins(cur, "INSERT INTO Impression(impression_id, video_id, user_id, occurred_at, feed_position, model_version) VALUES (?,?,?,?,?,?)",
        zip(imp_id.tolist(), vid.tolist(), uid.tolist(), iso(occ), feed.tolist(), ["ranker_v14"] * n))

    # ~35% of impressions become 1-3 view segments (funnel leak); Pareto-skewed watch time
    viewed = np.nonzero(rng.random(n) < 0.35)[0]
    nseg = rng.choice([1, 2, 3], viewed.size, p=[0.80, 0.15, 0.05])
    seg_imp = np.repeat(viewed, nseg)
    end_ms = np.minimum(dur[vid[seg_imp]], ((rng.pareto(1.5, seg_imp.size) + 1) * 3000).astype(np.int64))
    end_ms = np.maximum(end_ms, 300)
    seg_id = chunk * 3 * CH + np.arange(1, seg_imp.size + 1)
    ins(cur, "INSERT INTO ViewSegment(view_segment_id, impression_id, segment_start_ms, segment_end_ms) VALUES (?,?,?,?)",
        zip(seg_id.tolist(), imp_id[seg_imp].tolist(), [0] * seg_imp.size, end_ms.tolist()))

    # ~8% of viewed impressions produce one explicit signal
    sig = viewed[rng.random(viewed.size) < 0.08]
    kind = rng.choice(6, sig.size, p=[0.50, 0.15, 0.10, 0.15, 0.05, 0.05])
    sig_ts = occ[sig] + rng.integers(1, 121, sig.size)
    base = chunk * CH

    def pick(k):
        m = kind == k
        return sig[m], sig_ts[m]

    s, t = pick(0)                                              # likes (+ ~5% retracted within 60s)
    retr = rng.random(s.size) < 0.05
    like_rows = []
    lid = base
    for i, r, tt in zip(s.tolist(), retr.tolist(), t.tolist()):
        lid += 1
        like_rows.append((lid, int(vid[i]), int(uid[i]), "like", tt))
        if r:
            lid += 1
            like_rows.append((lid, int(vid[i]), int(uid[i]), "retract", tt + int(rng.integers(1, 60))))
    ins(cur, "INSERT INTO LikeEvent(like_event_id,video_id,user_id,event_type,occurred_at) VALUES (?,?,?,?,?)",
        [(a, b, c, d, iso1(e)) for a, b, c, d, e in like_rows])
    s, t = pick(1)
    ins(cur, "INSERT INTO SaveEvent(save_event_id,video_id,user_id,occurred_at) VALUES (?,?,?,?)",
        zip((base + np.arange(1, s.size + 1)).tolist(), vid[s].tolist(), uid[s].tolist(), iso(t)))
    s, t = pick(2)
    dest = np.array(["whatsapp", "instagram", "copied_link"])[rng.integers(0, 3, s.size)]
    ins(cur, "INSERT INTO ShareEvent(share_event_id,video_id,user_id,destination,occurred_at) VALUES (?,?,?,?,?)",
        zip((base + np.arange(1, s.size + 1)).tolist(), vid[s].tolist(), uid[s].tolist(), dest.tolist(), iso(t)))
    s, t = pick(3)
    ins(cur, "INSERT INTO CommentEvent(comment_id,video_id,user_id,body,occurred_at) VALUES (?,?,?,?,?)",
        zip((base + np.arange(1, s.size + 1)).tolist(), vid[s].tolist(), uid[s].tolist(), ["nice one!"] * s.size, iso(t)))
    s, t = pick(4)
    ins(cur, "INSERT INTO ReportEvent(report_id,video_id,user_id,reason,occurred_at) VALUES (?,?,?,?,?)",
        zip((base + np.arange(1, s.size + 1)).tolist(), vid[s].tolist(), uid[s].tolist(), ["spam"] * s.size, iso(t)))
    s, t = pick(5)
    ins(cur, "INSERT INTO NotInterestedEvent(not_interested_id,video_id,user_id,occurred_at) VALUES (?,?,?,?)",
        zip((base + np.arange(1, s.size + 1)).tolist(), vid[s].tolist(), uid[s].tolist(), iso(t)))


def phase4(cur):
    """Agent layer: templates, pricing, sessions, turns, tool calls (nested), shelves, judge/rating."""
    rng = rng_for(4)
    n_users, n_videos = N_USERS * SCALE, N_VIDEOS * SCALE
    n_sess = N_AGENT_SESSIONS * SCALE
    dur = load_durations(cur, n_videos)
    imp_id = (cur.execute("SELECT COALESCE(MAX(impression_id),0) FROM Impression").fetchone()[0]) + 1
    seg_id = (cur.execute("SELECT COALESCE(MAX(view_segment_id),0) FROM ViewSegment").fetchone()[0]) + 1

    ins(cur, "INSERT INTO PromptTemplateVersion(template_version_id, template_name, version_no, template_text, created_at) VALUES (?,?,?,?,?)",
        [(1, "explainer", 13, "v13 text...", iso1(0)), (2, "explainer", 14, "v14 text...", iso1(200 * 86400))])
    ins(cur, "INSERT INTO ModelPricingPeriod(price_period_id, model_id, input_rate, output_rate, cached_input_rate, valid_from, valid_to) VALUES (?,?,?,?,?,?,?)",
        [(1, "gpt-4o-mini", 0.15, 0.60, 0.075, iso1(0), iso1(300 * 86400)),
         (2, "gpt-4o-mini", 0.18, 0.72, 0.09, iso1(300 * 86400), None)])

    sess_user = rng.integers(1, n_users + 1, n_sess)
    sess_start = ts_seconds(rng, n_sess, 365)
    ins(cur, "INSERT INTO AgentSession(session_id, user_id, started_at) VALUES (?,?,?)",
        zip(range(1, n_sess + 1), sess_user.tolist(), iso(sess_start)))

    n_turns = rng.choice([1, 2, 3, 4], n_sess, p=[0.50, 0.30, 0.15, 0.05])
    T = int(n_turns.sum())
    srep = np.repeat(np.arange(n_sess), n_turns)
    seq = np.arange(T) - np.repeat(np.cumsum(n_turns) - n_turns, n_turns) + 1
    step = rng.integers(5, 61, T)
    cs = np.cumsum(step)
    grp0 = np.repeat(np.cumsum(n_turns) - n_turns, n_turns)
    before = np.where(grp0 > 0, cs[np.maximum(grp0 - 1, 0)], 0)
    t_ts = sess_start[srep] + (cs - before)
    tmpl = np.where(t_ts > 200 * 86400, 2, 1)
    in_tok = rng.integers(80, 2001, T)
    out_tok = rng.integers(20, 601, T)
    cached = (rng.random(T) * (in_tok // 2 + 1)).astype(int)
    ins(cur, """INSERT INTO Turn(turn_id, session_id, sequence_no, user_message, assistant_message,
                template_version_id, model_id, temperature, input_tokens, output_tokens, cached_tokens, occurred_at)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?)""",
        zip(range(1, T + 1), (srep + 1).tolist(), seq.tolist(), ["find me a cat video"] * T,
            ["here are some clips"] * T, tmpl.tolist(), ["gpt-4o-mini"] * T, [0.7] * T,
            in_tok.tolist(), out_tok.tolist(), cached.tolist(), iso(t_ts)))

    # tool calls: 1-2 top-level per turn, ~20% of those spawn 1-2 nested sub-calls
    top = rng.integers(1, 3, T)
    tc_rows, tcid = [], 1
    spawn = rng.random(int(top.sum())) < 0.2
    kids = rng.integers(1, 3, spawn.size)
    lat_top = rng.integers(50, 901, spawn.size)
    lat_kid = rng.integers(20, 301, spawn.size * 2)
    j = 0
    for turn, k in enumerate(top.tolist(), start=1):
        ts_iso = iso1(int(t_ts[turn - 1]))
        for _ in range(k):
            pid = tcid
            tc_rows.append((tcid, turn, None, "search_videos", '{"query": "cat"}', '{"count": 5}', int(lat_top[j]), 0, ts_iso))
            tcid += 1
            if spawn[j]:
                for c in range(int(kids[j])):
                    tc_rows.append((tcid, turn, pid, "fetch_trending_audio", '{"region": "IN"}', '{"tracks": 3}',
                                    int(lat_kid[2 * j + c]), 0, ts_iso))
                    tcid += 1
            j += 1
    ins(cur, """INSERT INTO ToolCall(tool_call_id, turn_id, parent_call_id, tool_name, arguments_json, result_json,
                latency_ms, errored, called_at) VALUES (?,?,?,?,?,?,?,?,?)""", tc_rows)

    # recommendation shelves (2-4 distinct clips); ~40% get a correlated full-length watch afterward
    shelf_n = rng.integers(2, 5, T)
    rec_rows, imp_rows, seg_rows = [], [], []
    rid = 1
    corr = rng.random(int(shelf_n.sum())) < 0.4
    corr_dt = rng.integers(5, 301, corr.size)
    ci = 0
    for turn in range(1, T + 1):
        k = int(shelf_n[turn - 1])
        vids = rng.choice(n_videos, k, replace=False) + 1
        u = int(sess_user[srep[turn - 1]])
        tt = int(t_ts[turn - 1])
        for pos, v in enumerate(vids.tolist()):
            rec_rows.append((rid, turn, v, pos))
            rid += 1
            if corr[ci]:
                imp_rows.append((imp_id, v, u, iso1(tt + int(corr_dt[ci])), pos, "ranker_v14"))
                seg_rows.append((seg_id, imp_id, 0, int(dur[v])))
                imp_id += 1
                seg_id += 1
            ci += 1
    ins(cur, "INSERT INTO Recommendation(recommendation_id, turn_id, video_id, position) VALUES (?,?,?,?)", rec_rows)
    ins(cur, "INSERT INTO Impression(impression_id, video_id, user_id, occurred_at, feed_position, model_version) VALUES (?,?,?,?,?,?)", imp_rows)
    ins(cur, "INSERT INTO ViewSegment(view_segment_id, impression_id, segment_start_ms, segment_end_ms) VALUES (?,?,?,?)", seg_rows)

    # sparse quality signals: ~10% of turns judged, ~3% rated
    judged = np.nonzero(rng.random(T) < 0.10)[0]
    ins(cur, "INSERT INTO JudgeScore(turn_id, helpfulness, groundedness, safety, judged_at) VALUES (?,?,?,?,?)",
        zip((judged + 1).tolist(), rng.uniform(1, 5, judged.size).tolist(), rng.uniform(1, 5, judged.size).tolist(),
            rng.uniform(3, 5, judged.size).tolist(), iso(t_ts[judged])))
    rated = np.nonzero(rng.random(T) < 0.03)[0]
    ins(cur, "INSERT INTO UserRating(turn_id, thumbs, rated_at) VALUES (?,?,?)",
        zip((rated + 1).tolist(), np.where(rng.random(rated.size) < 0.5, "up", "down").tolist(), iso(t_ts[rated])))


# ---------------------------------------------------------------- driver

def secondary_index_ddl(schema_sql):
    """CREATE INDEX ix_* statements (non-unique secondary indexes) from schema.sql."""
    return re.findall(r"CREATE INDEX ix_\w+\s+ON\s+[^;]+;", schema_sql)


def phase5(cur, schema_sql):
    for ddl in secondary_index_ddl(schema_sql):
        cur.execute(ddl)


def open_db(path):
    conn = sqlite3.connect(path, isolation_level=None)          # explicit BEGIN/COMMIT below
    conn.execute("PRAGMA foreign_keys = ON")
    conn.execute("PRAGMA synchronous = NORMAL")                 # load-time only; safe under WAL
    return conn


def run_phase(cur, name, schema_sql):
    if name == "1":
        phase1(cur)
    elif name == "2":
        phase2(cur)
    elif name.startswith("3:"):
        phase3(cur, int(name.split(":")[1]))
    elif name == "4":
        phase4(cur)
    elif name == "5":
        phase5(cur, schema_sql)
    else:
        raise SystemExit(f"unknown phase {name}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("db", nargs="?", default="scrollsense.db")
    ap.add_argument("--phase", help="1 | 2 | 3:<chunk> | 4 | 5  (default: all, one transaction)")
    ap.add_argument("--schema", default="schema.sql")
    ap.add_argument("--check", action="store_true", help="run PRAGMA foreign_key_check at the end (slow at scale)")
    args = ap.parse_args()
    schema_sql = open(args.schema).read()
    conn = open_db(args.db)
    cur = conn.cursor()

    first = args.phase in (None, "1")
    if first:
        conn.executescript(schema_sql)
        # bulk-load practice: build the non-unique secondary indexes once, after the load (phase 5)
        for name in re.findall(r"CREATE INDEX (ix_\w+)", schema_sql):
            cur.execute(f"DROP INDEX {name}")
        conn.execute("PRAGMA foreign_keys = ON")

    conn.execute("BEGIN")
    try:
        if args.phase is None:
            names = ["1", "2"] + [f"3:{c}" for c in range(N_CHUNKS)] + ["4", "5"]
        else:
            names = [args.phase]
        for nm in names:
            run_phase(cur, nm, schema_sql)
        conn.execute("COMMIT")
    except Exception:
        conn.execute("ROLLBACK")
        raise
    print("phase(s) done:", ",".join(names))
    if args.check:
        bad = cur.execute("PRAGMA foreign_key_check").fetchall()
        print("foreign_key_check violations:", len(bad))
    conn.close()


if __name__ == "__main__":
    main()