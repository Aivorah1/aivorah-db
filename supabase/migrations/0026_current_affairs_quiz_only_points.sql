-- Current Affairs: points come ONLY from the weekly quiz.
--   +20 for completing the quiz, +10 more at 80% or above (both decided by
--   the service and passed in p_points together with p_quizzes = 1).
--   Reading the daily digest or a story gives no points. Those calls still
--   count the digest / story and build the daily streak and the 7-day
--   streak badge, which never depended on points.
--
-- The service (aivorah-world-and-you-service) already sends p_points = 0 for
-- reading. This makes the rule hold in the database too, so an older
-- service version that still sends +10 / +5 for reading cannot add them.
--
-- Points already earned stay as they are: no existing row is changed.
-- Same signature as 0023, so the grants (service_role only) are kept.

create or replace function "public"."ca_apply_progress"(
  p_student_email       text,
  p_age_group           text,
  p_points              integer default 0,
  p_digests             integer default 0,
  p_stories             integer default 0,
  p_quizzes             integer default 0,
  p_current_streak      integer default null,
  p_last_digest_date    date    default null,
  p_last_story_date     date    default null,
  p_quiz_score          integer default null,
  p_last_quiz_date      date    default null,
  p_badge_excellence    boolean default false,
  p_badge_weekly_streak boolean default false,
  p_badge_growth        boolean default false
) returns "public"."ca_progress"
language sql
as $$
  insert into "public"."ca_progress" as p (
    student_email, age_group, points, digests_completed, stories_read, quizzes_completed,
    current_streak, longest_streak, last_digest_date, last_story_date,
    best_quiz_score, last_quiz_score, last_quiz_date,
    badge_excellence, badge_weekly_streak, badge_growth
  ) values (
    lower(trim(p_student_email)), p_age_group,
    -- Points only with a completed quiz; reading alone adds none.
    case when coalesce(p_quizzes, 0) > 0 then greatest(coalesce(p_points, 0), 0) else 0 end,
    greatest(coalesce(p_digests, 0), 0),
    greatest(coalesce(p_stories, 0), 0), greatest(coalesce(p_quizzes, 0), 0),
    coalesce(p_current_streak, 0), coalesce(p_current_streak, 0),
    p_last_digest_date, p_last_story_date,
    p_quiz_score, p_quiz_score, p_last_quiz_date,
    coalesce(p_badge_excellence, false), coalesce(p_badge_weekly_streak, false), coalesce(p_badge_growth, false)
  )
  on conflict (student_email, age_group) do update set
    points              = p.points + excluded.points,
    digests_completed   = p.digests_completed + excluded.digests_completed,
    stories_read        = p.stories_read + excluded.stories_read,
    quizzes_completed   = p.quizzes_completed + excluded.quizzes_completed,
    current_streak      = coalesce(p_current_streak, p.current_streak),
    longest_streak      = greatest(p.longest_streak, coalesce(p_current_streak, 0)),
    last_digest_date    = greatest(p.last_digest_date, excluded.last_digest_date),
    last_story_date     = greatest(p.last_story_date, excluded.last_story_date),
    best_quiz_score     = greatest(p.best_quiz_score, excluded.best_quiz_score),
    last_quiz_score     = coalesce(p_quiz_score, p.last_quiz_score),
    last_quiz_date      = greatest(p.last_quiz_date, excluded.last_quiz_date),
    badge_excellence    = p.badge_excellence or excluded.badge_excellence,
    badge_weekly_streak = p.badge_weekly_streak or excluded.badge_weekly_streak,
    badge_growth        = p.badge_growth or excluded.badge_growth,
    updated_at          = now()
  returning *;
$$;

notify pgrst, 'reload schema';
