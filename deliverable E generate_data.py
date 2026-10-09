#!/usr/bin/env python3
"""
generate_data.py -- ScrollSense synthetic data generator.

Run: python3 generate_data.py [path_to_db]
Loads schema.sql fresh, then populates it inside ONE transaction.
"""
import sqlite3
import random
import sys
import datetime
import json

#parameters 
SEED = 21000000          #replace with your actual roll number
N_USERS = 5_000
N_VIDEOS = 20_000
N_IMPRESSIONS = 300_000
N_AGENT_SESSIONS = 2_000
SCALE = 1                # A2: set to 50


random.seed(SEED)

DB_PATH = sys.argv[1] if len(sys.argv) > 1 else "scrollsense.db"
EPOCH = datetime.datetime(2025, 1, 1, tzinfo=datetime.timezone.utc)


def iso(dt):
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


def random_ts(days_span=365):
    # Daily-rhythm bias: weight toward evening hours (18:00-23:00) to
    # mimic real usage, rather than uniform across 24h.
    day_offset = random.uniform(0, days_span)
    hour_weights = [1]*6 + [2]*6 + [4]*6 + [6]*6  # night/morning/afternoon/evening
    hour = random.choices(range(24), weights=hour_weights, k=1)[0]
    minute = random.randint(0, 59)
    second = random.randint(0, 59)
    dt = EPOCH + datetime.timedelta(days=day_offset)
    dt = dt.replace(hour=hour, minute=minute, second=second)
    return dt


def power_law_int(low, high, exponent=2.0):
    """Roughly power-law distributed integer in [low, high]."""
    u = random.random()
    val = low + (high - low) * (1 - u) ** exponent
    return int(val)


def main():
    conn = sqlite3.connect(DB_PATH)
    conn.execute("PRAGMA foreign_keys = ON")
    conn.executescript(open("schema.sql").read())
    cur = conn.cursor()

    try:
        #  Users & Interests 
        categories = ["comedy", "cooking", "fitness", "music", "gaming",
                      "study_tips", "fashion", "sports", "travel", "pets"]
        for i, name in enumerate(categories, start=1):
            cur.execute("INSERT INTO InterestCategory(category_id, name) VALUES (?,?)", (i, name))

        n_users = N_USERS * SCALE
        for uid in range(1, n_users + 1):
            created = random_ts(days_span=730)
            account_state = random.choices(
                ["active", "deactivated", "pending_deletion"], weights=[92, 6, 2], k=1
            )[0]
            deleted_at = iso(created + datetime.timedelta(days=random.randint(1, 700))) \
                if account_state != "active" else None
            signup_via_phone = random.random() < 0.6
            cur.execute(
                """INSERT INTO AppUser(user_id, phone_number, google_account_id, handle,
                       display_name, account_state, created_at, deleted_at)
                   VALUES (?,?,?,?,?,?,?,?)""",
                (uid,
                 f"+91{random.randint(6000000000, 9999999999)}" if signup_via_phone else None,
                 f"g_{uid}_{random.randint(1000,9999)}" if not signup_via_phone else None,
                 f"user_{uid}_{random.randint(100,999)}",
                 f"User {uid}",
                 account_state,
                 iso(created),
                 deleted_at),
            )
            # each user declares 1-4 interests
            declared_cats = random.sample(range(1, len(categories) + 1), k=random.randint(1, 4))
            for cat_id in declared_cats:
                cur.execute(
                    "INSERT INTO UserDeclaredInterest(user_id, category_id, declared_at) VALUES (?,?,?)",
                    (uid, cat_id, iso(created)),
                )

            # weekly-refreshed inferred interests: a few weeks of history per user,
            # scores drifting slightly week to week
            n_weeks = random.randint(1, 6)
            inferred_cat = random.choice(range(1, len(categories) + 1))
            base_score = random.uniform(0.2, 0.9)
            for w in range(n_weeks):
                week_ts = iso(created + datetime.timedelta(weeks=w))
                score = min(1.0, max(0.0, base_score + random.uniform(-0.05, 0.05)))
                cur.execute(
                    "INSERT OR IGNORE INTO UserInferredInterest(user_id, category_id, as_of_week, confidence_score) VALUES (?,?,?,?)",
                    (uid, inferred_cat, week_ts, round(score, 3)),
                )
            # ~4% of users suppress their inferred interest -- must survive later refreshes (A4)
            if random.random() < 0.04:
                cur.execute(
                    "INSERT OR IGNORE INTO InterestSuppression(user_id, category_id, suppressed_at) VALUES (?,?,?)",
                    (uid, inferred_cat, iso(created + datetime.timedelta(weeks=random.randint(1, n_weeks)))),
                )

        # Creators & tiers 
        # ~15% of users are creators (own at least one video, get a tier history)
        creator_ids = random.sample(range(1, n_users + 1), k=int(n_users * 0.15))
        tier_period_id = 1
        for cid in creator_ids:
            tiers = random.choice([["standard"], ["standard", "rising"], ["standard", "rising", "partner"]])
            start = random_ts(days_span=600)
            for j, tier in enumerate(tiers):
                is_last = j == len(tiers) - 1
                end = None if is_last else iso(start + datetime.timedelta(days=random.randint(30, 120)))
                cur.execute(
                    "INSERT INTO CreatorTierPeriod(tier_period_id, creator_id, tier, valid_from, valid_to) VALUES (?,?,?,?,?)",
                    (tier_period_id, cid, tier, iso(start), end),
                )
                tier_period_id += 1
                if end:
                    start = datetime.datetime.strptime(end, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)

        #Audio tracks & videos 
        n_videos = N_VIDEOS * SCALE
        n_tracks = max(1, n_videos // 50)  # like ~50,000 clips per trending sound, scaled down
        for tid in range(1, n_tracks + 1):
            is_licensed = random.random() < 0.4
            cur.execute(
                "INSERT INTO AudioTrack(track_id, source_type, original_video_id, catalogue_ref) VALUES (?,?,?,?)",
                (tid, "licensed" if is_licensed else "original", None,
                 f"catalog_{tid}" if is_licensed else None),
            )

        video_ids = list(range(1, n_videos + 1))
        for vid in video_ids:
            owner = random.choice(creator_ids)
            uploaded = random_ts(days_span=365)
            uses_track = random.random() < 0.7
            cur.execute(
                """INSERT INTO Video(video_id, owner_id, duration_ms, caption, audio_track_id, uploaded_at)
                   VALUES (?,?,?,?,?,?)""",
                (vid, owner, random.randint(20000, 90000),
                 f"caption for clip {vid} #{'funny' if random.random()<0.3 else 'trend'}",
                 random.randint(1, n_tracks) if uses_track else None,
                 iso(uploaded)),
            )
            # Backfill ~1 in 200 tracks' "original" video now that videos exist
            if random.random() < 0.005:
                cur.execute(
                    "UPDATE AudioTrack SET original_video_id = ? WHERE track_id = ? AND source_type = 'original' AND original_video_id IS NULL",
                    (vid, random.randint(1, n_tracks)),
                )

            # Moderation history: mostly 1 event (auto-approved live), some longer sequences
            n_events = random.choices([1, 2, 3], weights=[85, 12, 3], k=1)[0]
            state_seq = ["pending"]
            for _ in range(n_events - 1):
                state_seq.append(random.choice(["live", "demoted", "age_restricted", "taken_down"]))
            if n_events == 1:
                state_seq = ["live"] if random.random() < 0.9 else ["pending"]
            t = uploaded
            for k, state in enumerate(state_seq):
                t = t + datetime.timedelta(minutes=random.randint(1, 600))
                cur.execute(
                    """INSERT INTO ModerationEvent(video_id, state_code, decided_by_type, decided_by_id, decided_at)
                       VALUES (?,?,?,?,?)""",
                    (vid, state,
                     "classifier" if random.random() < 0.8 else "human",
                     None if random.random() < 0.8 else f"reviewer_{random.randint(1,50)}",
                     iso(t)),
                )

            # Hashtags: 0-4 per video
            for _ in range(random.randint(0, 4)):
                tag = random.choice(["funny", "fyp", "cooking", "trend", "viral", "dance", "study"])
                cur.execute("INSERT OR IGNORE INTO Hashtag(tag_text) VALUES (?)", (tag,))
                htag_id = cur.execute("SELECT hashtag_id FROM Hashtag WHERE tag_text = ?", (tag,)).fetchone()[0]
                cur.execute("INSERT OR IGNORE INTO VideoHashtag(video_id, hashtag_id) VALUES (?,?)", (vid, htag_id))

        # Social graph
        for _ in range(n_users * 3):
            a, b = random.sample(range(1, n_users + 1), 2)
            start = random_ts(days_span=500)
            ended = random.random() < 0.1
            cur.execute(
                "INSERT INTO Follow(follower_id, followee_id, started_at, ended_at) VALUES (?,?,?,?)",
                (a, b, iso(start), iso(start + datetime.timedelta(days=random.randint(1, 200))) if ended else None),
            )
        for _ in range(int(n_users * 0.02)):
            a, b = random.sample(range(1, n_users + 1), 2)
            cur.execute("INSERT OR IGNORE INTO Block(blocker_id, blocked_id, blocked_at) VALUES (?,?,?)",
                        (a, b, iso(random_ts())))
        # Mute is weaker/more common than Block -- content hides, profile stays visible
        for _ in range(int(n_users * 0.08)):
            a, b = random.sample(range(1, n_users + 1), 2)
            cur.execute("INSERT OR IGNORE INTO Mute(muter_id, muted_id, muted_at) VALUES (?,?,?)",
                        (a, b, iso(random_ts())))

        # Watch telemetry (the funnel) 
        # Realistic funnel: most impressions -> no view; most views -> no signal.
        n_impressions = N_IMPRESSIONS * SCALE
        impression_id = 1
        view_segment_id = 1
        like_id = save_id = share_id = comment_id = report_id = ni_id = 1
        for _ in range(n_impressions):
            uid = random.randint(1, n_users)
            vid = random.choice(video_ids)
            occurred = random_ts(days_span=365)
            cur.execute(
                """INSERT INTO Impression(impression_id, video_id, user_id, occurred_at, feed_position, model_version)
                   VALUES (?,?,?,?,?,?)""",
                (impression_id, vid, uid, iso(occurred), power_law_int(0, 50), "ranker_v14"),
            )
            # ~35% of impressions become at least one view segment (funnel leak)
            if random.random() < 0.35:
                n_segments = random.choices([1, 2, 3], weights=[80, 15, 5], k=1)[0]
                clip_dur = cur.execute("SELECT duration_ms FROM Video WHERE video_id=?", (vid,)).fetchone()[0]
                for _ in range(n_segments):
                    # right-skewed watch time: most segments short, a tail watches to completion+
                    start_ms = 0
                    end_ms = min(clip_dur, int(random.paretovariate(1.5) * 3000))
                    end_ms = max(end_ms, 300)
                    cur.execute(
                        "INSERT INTO ViewSegment(view_segment_id, impression_id, segment_start_ms, segment_end_ms) VALUES (?,?,?,?)",
                        (view_segment_id, impression_id, start_ms, end_ms),
                    )
                    view_segment_id += 1

                # ~8% of viewed impressions produce an explicit signal
                if random.random() < 0.08:
                    signal = random.choices(
                        ["like", "save", "share", "comment", "report", "not_interested"],
                        weights=[50, 15, 10, 15, 5, 5], k=1
                    )[0]
                    sig_ts = iso(occurred + datetime.timedelta(seconds=random.randint(1, 120)))
                    if signal == "like":
                        cur.execute("INSERT INTO LikeEvent(like_event_id,video_id,user_id,event_type,occurred_at) VALUES (?,?,?,?,?)",
                                    (like_id, vid, uid, "like", sig_ts))
                        # ~5% of likes are retracted within 60s (feeds F4)
                        if random.random() < 0.05:
                            like_id += 1
                            cur.execute("INSERT INTO LikeEvent(like_event_id,video_id,user_id,event_type,occurred_at) VALUES (?,?,?,?,?)",
                                        (like_id, vid, uid, "retract",
                                         iso(datetime.datetime.strptime(sig_ts, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc) + datetime.timedelta(seconds=random.randint(1, 59)))))
                        like_id += 1
                    elif signal == "save":
                        cur.execute("INSERT INTO SaveEvent(save_event_id,video_id,user_id,occurred_at) VALUES (?,?,?,?)",
                                    (save_id, vid, uid, sig_ts)); save_id += 1
                    elif signal == "share":
                        dest = random.choice(["whatsapp", "instagram", "copied_link"])
                        cur.execute("INSERT INTO ShareEvent(share_event_id,video_id,user_id,destination,occurred_at) VALUES (?,?,?,?,?)",
                                    (share_id, vid, uid, dest, sig_ts)); share_id += 1
                    elif signal == "comment":
                        cur.execute("INSERT INTO CommentEvent(comment_id,video_id,user_id,body,occurred_at) VALUES (?,?,?,?,?)",
                                    (comment_id, vid, uid, "nice one!", sig_ts)); comment_id += 1
                    elif signal == "report":
                        cur.execute("INSERT INTO ReportEvent(report_id,video_id,user_id,reason,occurred_at) VALUES (?,?,?,?,?)",
                                    (report_id, vid, uid, "spam", sig_ts)); report_id += 1
                    else:
                        cur.execute("INSERT INTO NotInterestedEvent(not_interested_id,video_id,user_id,occurred_at) VALUES (?,?,?,?)",
                                    (ni_id, vid, uid, sig_ts)); ni_id += 1
            impression_id += 1

        #  Agent layer 
        cur.execute(
            "INSERT INTO PromptTemplateVersion(template_version_id, template_name, version_no, template_text, created_at) VALUES (1,'explainer',13,'v13 text...', ?)",
            (iso(EPOCH),),
        )
        cur.execute(
            "INSERT INTO PromptTemplateVersion(template_version_id, template_name, version_no, template_text, created_at) VALUES (2,'explainer',14,'v14 text...', ?)",
            (iso(EPOCH + datetime.timedelta(days=200)),),
        )
        cur.execute(
            "INSERT INTO ModelPricingPeriod(price_period_id, model_id, input_rate, output_rate, cached_input_rate, valid_from, valid_to) VALUES (1,'gpt-4o-mini',0.15,0.60,0.075,?,?)",
            (iso(EPOCH), iso(EPOCH + datetime.timedelta(days=300))),
        )
        cur.execute(
            "INSERT INTO ModelPricingPeriod(price_period_id, model_id, input_rate, output_rate, cached_input_rate, valid_from, valid_to) VALUES (2,'gpt-4o-mini',0.18,0.72,0.09,?,NULL)",
            (iso(EPOCH + datetime.timedelta(days=300)),),
        )

        n_sessions = N_AGENT_SESSIONS * SCALE
        turn_id = 1
        tool_call_id = 1
        rec_id = 1
        for sid in range(1, n_sessions + 1):
            uid = random.randint(1, n_users)
            started = random_ts(days_span=365)
            cur.execute("INSERT INTO AgentSession(session_id, user_id, started_at) VALUES (?,?,?)",
                        (sid, uid, iso(started)))
            n_turns = random.choices([1, 2, 3, 4], weights=[50, 30, 15, 5], k=1)[0]
            t = started
            for seq in range(1, n_turns + 1):
                t = t + datetime.timedelta(seconds=random.randint(5, 60))
                template = 2 if t > EPOCH + datetime.timedelta(days=200) else 1
                in_tok = random.randint(80, 2000)
                out_tok = random.randint(20, 600)
                cached_tok = random.randint(0, in_tok // 2)
                cur.execute(
                    """INSERT INTO Turn(turn_id, session_id, sequence_no, user_message, assistant_message,
                           template_version_id, model_id, temperature, input_tokens, output_tokens,
                           cached_tokens, occurred_at)
                       VALUES (?,?,?,?,?,?,?,?,?,?,?,?)""",
                    (turn_id, sid, seq, "find me a cat video", "here are some clips",
                     template, "gpt-4o-mini", 0.7, in_tok, out_tok, cached_tok, iso(t)),
                )
                # 1-2 top-level tool calls per turn; ~20% of those spawn 1-2 nested sub-calls
                for _ in range(random.randint(1, 2)):
                    cur.execute(
                        """INSERT INTO ToolCall(tool_call_id, turn_id, parent_call_id, tool_name,
                               arguments_json, result_json, latency_ms, errored, called_at)
                           VALUES (?,?,?,?,?,?,?,?,?)""",
                        (tool_call_id, turn_id, None, "search_videos",
                         json.dumps({"query": "cat"}), json.dumps({"count": 5}),
                         random.randint(50, 900), 0, iso(t)),
                    )
                    parent_id = tool_call_id
                    tool_call_id += 1
                    if random.random() < 0.2:
                        for _ in range(random.randint(1, 2)):
                            cur.execute(
                                """INSERT INTO ToolCall(tool_call_id, turn_id, parent_call_id, tool_name,
                                       arguments_json, result_json, latency_ms, errored, called_at)
                                   VALUES (?,?,?,?,?,?,?,?,?)""",
                                (tool_call_id, turn_id, parent_id, "fetch_trending_audio",
                                 json.dumps({"region": "IN"}), json.dumps({"tracks": 3}),
                                 random.randint(20, 300), 0, iso(t)),
                            )
                            tool_call_id += 1

                # Recommendation shelf (2-4 clips)
                shelf_videos = random.sample(video_ids, k=random.randint(2, 4))
                for pos, vid in enumerate(shelf_videos):
                    cur.execute("INSERT INTO Recommendation(recommendation_id, turn_id, video_id, position) VALUES (?,?,?,?)",
                                (rec_id, turn_id, vid, pos))
                    rec_id += 1
                    # ~40% of recommended clips get an explicit, correlated watch-to-completion
                    # afterward -- without this, F12 has nothing to find by pure chance, since
                    # Impression generation above draws videos independently of Recommendation.
                    if random.random() < 0.4:
                        watch_ts = t + datetime.timedelta(seconds=random.randint(5, 300))
                        clip_dur = cur.execute("SELECT duration_ms FROM Video WHERE video_id=?", (vid,)).fetchone()[0]
                        cur.execute(
                            """INSERT INTO Impression(impression_id, video_id, user_id, occurred_at, feed_position, model_version)
                               VALUES (?,?,?,?,?,?)""",
                            (impression_id, vid, uid, iso(watch_ts), pos, "ranker_v14"),
                        )
                        cur.execute(
                            "INSERT INTO ViewSegment(view_segment_id, impression_id, segment_start_ms, segment_end_ms) VALUES (?,?,?,?)",
                            (view_segment_id, impression_id, 0, clip_dur),
                        )
                        impression_id += 1
                        view_segment_id += 1


                # sparse judge/rating coverage
                if random.random() < 0.1:
                    cur.execute(
                        "INSERT INTO JudgeScore(turn_id, helpfulness, groundedness, safety, judged_at) VALUES (?,?,?,?,?)",
                        (turn_id, random.uniform(1, 5), random.uniform(1, 5), random.uniform(3, 5), iso(t)),
                    )
                if random.random() < 0.03:
                    cur.execute(
                        "INSERT INTO UserRating(turn_id, thumbs, rated_at) VALUES (?,?,?)",
                        (turn_id, random.choice(["up", "down"]), iso(t)),
                    )
                turn_id += 1

        conn.commit()
        print("Generation complete.")
        for row in cur.execute("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"):
            n = cur.execute(f"SELECT COUNT(*) FROM {row[0]}").fetchone()[0]
            print(f"  {row[0]:24s} {n:>8,} rows")

    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


if __name__ == "__main__":
    main()
