-- ============================================================
-- Migration v1.97 : レート制限・Bot/自動化対策
-- Supabase SQL Editor で実行してください。前提: v1.85（send_like）,
-- v1.69（send_chat_message）, v1.58（send_group_message）, v1.17（profile_views）
-- 実行済み。
-- ------------------------------------------------------------
-- 背景:
--   DM送信・いいねに速度制限が無く、大量送信によるスパム/嫌がらせを
--   技術的に止める手段が無かった。また異常な利用パターン（DM/マッチ/
--   プロフィール閲覧/位置情報更新の急増）を検知する仕組みも無かった。
--
--   ログイン試行制限・アカウント作成速度の異常検知（IP/デバイス単位）は
--   Supabase Auth側の設定、またはedge function側でのIP集計が必要で
--   Postgres RPCの範囲を超えるため、今回のスコープからは除外する
--   （運用チェックリスト: Dashboard → Auth → Rate Limits の確認）。
--
--   何度実行しても安全（冪等）。
-- ============================================================

-- ① 速度チェック用インデックス
CREATE INDEX IF NOT EXISTS idx_chat_messages_sender_created ON public.chat_messages(sender_id, created_at);
CREATE INDEX IF NOT EXISTS idx_group_messages_sender_created ON public.group_messages(sender_id, created_at);

-- ② send_chat_message: 1分あたり60件を超えたら一時的に拒否
CREATE OR REPLACE FUNCTION public.send_chat_message(p_match_id uuid, p_content_type text, p_body text DEFAULT NULL::text, p_photo_path text DEFAULT NULL::text, p_related_post_id uuid DEFAULT NULL::uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_caller_id UUID;
  v_a UUID;
  v_b UUID;
  v_other_id UUID;
  v_thread_id UUID;
  v_message_id UUID;
  v_word RECORD;
  v_text TEXT;
  v_recent_count INT;
BEGIN
  SELECT user_id INTO v_caller_id FROM public.users WHERE auth_id = auth.uid();
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'unauthorized';
  END IF;

  SELECT count(*) INTO v_recent_count
  FROM public.chat_messages
  WHERE sender_id = v_caller_id AND created_at > now() - interval '1 minute';
  IF v_recent_count >= 60 THEN
    RAISE EXCEPTION 'rate_limited';
  END IF;

  IF p_content_type NOT IN ('text', 'photo', 'sns', 'quick_reply', 'board_invite') THEN
    RAISE EXCEPTION 'invalid content_type';
  END IF;
  IF p_content_type = 'board_invite' AND p_related_post_id IS NULL THEN
    RAISE EXCEPTION 'related_post_id required for board_invite';
  END IF;

  SELECT user_a_id, user_b_id INTO v_a, v_b FROM public.matches WHERE match_id = p_match_id;
  IF v_a IS NULL THEN
    RAISE EXCEPTION 'match not found';
  END IF;
  IF v_caller_id <> v_a AND v_caller_id <> v_b THEN
    RAISE EXCEPTION 'not a participant of this match';
  END IF;
  v_other_id := CASE WHEN v_caller_id = v_a THEN v_b ELSE v_a END;

  IF EXISTS (
    SELECT 1 FROM public.blocks
    WHERE (blocker_id = v_caller_id AND blocked_id = v_other_id)
       OR (blocker_id = v_other_id AND blocked_id = v_caller_id)
  ) THEN
    RAISE EXCEPTION 'blocked';
  END IF;

  IF p_body IS NOT NULL AND p_body <> '' THEN
    v_text := lower(p_body);
    FOR v_word IN SELECT word FROM public.ng_words LOOP
      IF position(lower(v_word.word) IN v_text) > 0 THEN
        RAISE EXCEPTION 'ng_word_detected';
      END IF;
    END LOOP;
  END IF;

  SELECT thread_id INTO v_thread_id FROM public.chat_threads WHERE match_id = p_match_id;
  IF v_thread_id IS NULL THEN
    INSERT INTO public.chat_threads (match_id) VALUES (p_match_id)
    ON CONFLICT (match_id) DO NOTHING
    RETURNING thread_id INTO v_thread_id;

    IF v_thread_id IS NULL THEN
      SELECT thread_id INTO v_thread_id FROM public.chat_threads WHERE match_id = p_match_id;
    END IF;
  END IF;

  INSERT INTO public.chat_messages (thread_id, sender_id, content_type, body, photo_path, related_post_id)
  VALUES (v_thread_id, v_caller_id, p_content_type, p_body, p_photo_path, p_related_post_id)
  RETURNING message_id INTO v_message_id;

  PERFORM public.create_app_notification(
    v_other_id, 'chat_message',
    jsonb_build_object('match_id', p_match_id, 'thread_id', v_thread_id), v_caller_id
  );

  RETURN jsonb_build_object('success', TRUE, 'message_id', v_message_id, 'thread_id', v_thread_id);
END;
$function$;

-- ③ send_group_message: 同様に1分あたり60件で拒否
CREATE OR REPLACE FUNCTION public.send_group_message(
  p_group_id UUID,
  p_content_type TEXT,
  p_body TEXT DEFAULT NULL,
  p_photo_path TEXT DEFAULT NULL,
  p_related_post_id UUID DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_id UUID;
  v_message_id UUID;
  v_word RECORD;
  v_text TEXT;
  v_recent_count INT;
BEGIN
  SELECT user_id INTO v_caller_id FROM public.users WHERE auth_id = auth.uid();
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'unauthorized';
  END IF;

  SELECT count(*) INTO v_recent_count
  FROM public.group_messages
  WHERE sender_id = v_caller_id AND created_at > now() - interval '1 minute';
  IF v_recent_count >= 60 THEN
    RAISE EXCEPTION 'rate_limited';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.group_memberships
    WHERE group_id = p_group_id AND user_id = v_caller_id AND status = 'member'
  ) THEN
    RAISE EXCEPTION 'not a member';
  END IF;

  IF p_content_type NOT IN ('text', 'photo', 'quick_reply', 'board_invite') THEN
    RAISE EXCEPTION 'invalid content_type';
  END IF;
  IF p_content_type = 'board_invite' AND p_related_post_id IS NULL THEN
    RAISE EXCEPTION 'related_post_id required for board_invite';
  END IF;
  IF p_content_type = 'photo' AND p_photo_path IS NULL THEN
    RAISE EXCEPTION 'photo_path required for photo';
  END IF;
  IF p_content_type <> 'photo' AND (p_body IS NULL OR trim(p_body) = '') THEN
    RAISE EXCEPTION 'body required';
  END IF;

  IF p_body IS NOT NULL AND p_body <> '' THEN
    v_text := lower(p_body);
    FOR v_word IN SELECT word FROM public.ng_words LOOP
      IF position(lower(v_word.word) IN v_text) > 0 THEN
        RAISE EXCEPTION 'ng_word_detected';
      END IF;
    END LOOP;
  END IF;

  INSERT INTO public.group_messages (group_id, sender_id, content_type, body, photo_path, related_post_id)
  VALUES (p_group_id, v_caller_id, p_content_type, NULLIF(trim(coalesce(p_body, '')), ''), p_photo_path, p_related_post_id)
  RETURNING message_id INTO v_message_id;

  RETURN v_message_id;
END;
$$;

-- ④ send_like: 既存の日次上限（10/200）に加え、1分あたり20件のバースト制限を追加
CREATE OR REPLACE FUNCTION public.send_like(
  p_from_user_id UUID,
  p_to_user_id   UUID,
  p_encounter_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_is_matched   BOOLEAN := FALSE;
  v_match_id     UUID;
  v_like_count   INT;
  v_is_premium   BOOLEAN;
  v_is_suspended BOOLEAN;
  v_caller       UUID;
  v_user_a       UUID;
  v_user_b       UUID;
  v_enc_a        UUID;
  v_enc_b        UUID;
  v_rowcount     INT := 0;
  v_recent_count INT;
BEGIN
  SELECT user_id INTO v_caller FROM public.users WHERE auth_id = auth.uid();
  IF v_caller IS NULL OR v_caller <> p_from_user_id THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'forbidden');
  END IF;

  IF p_from_user_id = p_to_user_id THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'invalid_target');
  END IF;

  SELECT count(*) INTO v_recent_count
  FROM public.likes
  WHERE from_user_id = p_from_user_id AND created_at > now() - interval '1 minute';
  IF v_recent_count >= 20 THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'rate_limited');
  END IF;

  SELECT user_a_id, user_b_id
  INTO v_enc_a, v_enc_b
  FROM public.encounters
  WHERE encounter_id = p_encounter_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'encounter_not_found');
  END IF;

  IF NOT (
    (v_enc_a = p_from_user_id AND v_enc_b = p_to_user_id) OR
    (v_enc_b = p_from_user_id AND v_enc_a = p_to_user_id)
  ) THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'not_encounter_party');
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.blocks b
    WHERE (b.blocker_id = p_from_user_id AND b.blocked_id = p_to_user_id)
       OR (b.blocker_id = p_to_user_id AND b.blocked_id = p_from_user_id)
  ) THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'blocked');
  END IF;

  v_is_premium := public.user_is_premium(p_from_user_id);

  SELECT is_suspended INTO v_is_suspended
  FROM public.users WHERE user_id = p_from_user_id;

  IF COALESCE(v_is_suspended, FALSE) THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'suspended');
  END IF;

  SELECT like_count INTO v_like_count
  FROM public.today_like_counts
  WHERE from_user_id = p_from_user_id;

  IF NOT v_is_premium AND COALESCE(v_like_count, 0) >= 10 THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'daily_limit_exceeded');
  END IF;

  INSERT INTO public.likes (from_user_id, to_user_id, encounter_id)
  VALUES (p_from_user_id, p_to_user_id, p_encounter_id)
  ON CONFLICT (from_user_id, to_user_id) DO UPDATE
    SET encounter_id = EXCLUDED.encounter_id,
        created_at = NOW()
    WHERE public.likes.encounter_id IS DISTINCT FROM EXCLUDED.encounter_id;

  GET DIAGNOSTICS v_rowcount = ROW_COUNT;

  IF EXISTS (
    SELECT 1 FROM public.likes
    WHERE from_user_id = p_to_user_id
      AND to_user_id = p_from_user_id
  ) OR EXISTS (
    SELECT 1 FROM public.matches
    WHERE user_a_id = LEAST(p_from_user_id, p_to_user_id)
      AND user_b_id = GREATEST(p_from_user_id, p_to_user_id)
  ) THEN
    v_user_a := LEAST(p_from_user_id, p_to_user_id);
    v_user_b := GREATEST(p_from_user_id, p_to_user_id);

    INSERT INTO public.matches (user_a_id, user_b_id)
    VALUES (v_user_a, v_user_b)
    ON CONFLICT (user_a_id, user_b_id) DO NOTHING
    RETURNING match_id INTO v_match_id;

    v_is_matched := TRUE;
  END IF;

  IF v_rowcount > 0 AND NOT v_is_matched THEN
    PERFORM public.create_app_notification(
      p_to_user_id, 'like_received',
      jsonb_build_object('from_user_id', p_from_user_id), p_from_user_id
    );
  END IF;

  RETURN jsonb_build_object(
    'success',    TRUE,
    'is_matched', v_is_matched,
    'match_id',   v_match_id,
    'already_liked', (v_rowcount = 0)
  );
END;
$$;

-- ⑤ Bot/自動化対策：異常な速度を検知して蓄積するテーブル
CREATE TABLE IF NOT EXISTS public.abuse_signals (
  signal_id     UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id       UUID NOT NULL REFERENCES public.users(user_id) ON DELETE CASCADE,
  signal_type   TEXT NOT NULL CHECK (signal_type IN (
                  'dm_velocity', 'match_velocity', 'profile_view_velocity', 'location_velocity'
                )),
  metric_value  INT NOT NULL,
  detected_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  resolved      BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE INDEX IF NOT EXISTS idx_abuse_signals_user ON public.abuse_signals(user_id, detected_at DESC);
CREATE INDEX IF NOT EXISTS idx_abuse_signals_unresolved ON public.abuse_signals(resolved, detected_at DESC) WHERE resolved = FALSE;

ALTER TABLE public.abuse_signals ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.abuse_signals FROM anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON public.abuse_signals TO service_role;

CREATE OR REPLACE VIEW public.abuse_review_queue AS
SELECT
  s.user_id,
  u.nickname,
  u.is_suspended,
  s.signal_type,
  s.metric_value,
  s.detected_at
FROM public.abuse_signals s
JOIN public.users u ON u.user_id = s.user_id
WHERE s.resolved = FALSE
ORDER BY s.detected_at DESC;

REVOKE ALL ON public.abuse_review_queue FROM anon, authenticated;
GRANT SELECT ON public.abuse_review_queue TO service_role;

-- ⑥ 異常検知cron（毎時、直近1時間の速度を4シグナルで評価）
-- 閾値は初期値。運用しながら調整する想定。
-- location_velocity は user_locations が最新1件しか保持しない(TTL 30秒)ため、
-- 位置情報を伴うencounter登録件数を代理指標として使う。
DO $abuse_cron$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'pg_cron') THEN
    CREATE EXTENSION IF NOT EXISTS pg_cron;
    IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'detect-abuse-signals') THEN
      PERFORM cron.unschedule('detect-abuse-signals');
    END IF;
    PERFORM cron.schedule(
      'detect-abuse-signals',
      '0 * * * *',
      $job$
      INSERT INTO public.abuse_signals (user_id, signal_type, metric_value)
      SELECT sender_id, 'dm_velocity', cnt FROM (
        SELECT sender_id, count(*) AS cnt FROM (
          SELECT sender_id, created_at FROM public.chat_messages WHERE created_at > now() - interval '1 hour'
          UNION ALL
          SELECT sender_id, created_at FROM public.group_messages WHERE created_at > now() - interval '1 hour'
        ) x GROUP BY sender_id
      ) agg WHERE cnt > 300;

      INSERT INTO public.abuse_signals (user_id, signal_type, metric_value)
      SELECT user_id, 'match_velocity', cnt FROM (
        SELECT user_a_id AS user_id, count(*) AS cnt FROM public.matches WHERE matched_at > now() - interval '1 hour' GROUP BY user_a_id
        UNION ALL
        SELECT user_b_id AS user_id, count(*) AS cnt FROM public.matches WHERE matched_at > now() - interval '1 hour' GROUP BY user_b_id
      ) x GROUP BY user_id HAVING sum(cnt) > 50;

      INSERT INTO public.abuse_signals (user_id, signal_type, metric_value)
      SELECT viewer_user_id, 'profile_view_velocity', count(*)
      FROM public.profile_views
      WHERE viewed_at > now() - interval '1 hour'
      GROUP BY viewer_user_id
      HAVING count(*) > 500;

      INSERT INTO public.abuse_signals (user_id, signal_type, metric_value)
      SELECT user_id, 'location_velocity', cnt FROM (
        SELECT user_a_id AS user_id, count(*) AS cnt FROM public.encounters WHERE created_at > now() - interval '1 hour' GROUP BY user_a_id
        UNION ALL
        SELECT user_b_id AS user_id, count(*) AS cnt FROM public.encounters WHERE created_at > now() - interval '1 hour' GROUP BY user_b_id
      ) x GROUP BY user_id HAVING sum(cnt) > 200;
      $job$
    );
  END IF;
END $abuse_cron$;

-- ============================================================
-- 動作確認用クエリ（手動実行）
-- ============================================================
-- SELECT jobname FROM cron.job WHERE jobname = 'detect-abuse-signals';
-- SELECT * FROM public.abuse_review_queue LIMIT 20;
