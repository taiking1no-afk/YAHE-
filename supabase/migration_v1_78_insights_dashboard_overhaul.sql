-- ============================================================
-- Migration v1.78 : インサイトアクティビティ大幅拡張（Instagramプロフェッショナル
-- ダッシュボード相当への作り直し）
-- Supabase SQL Editor で実行してください。前提: v1.75, v1.77 実行済み。
-- ------------------------------------------------------------
-- 追加する指標:
--  ◯プロフィールインサイト
--   ・プロフィール閲覧数（期間内）
--   ・累計すれ違い数（すれ違いの生ログencountersは24h/7dで自動削除されるため
--     期間別の集計は不可能。永続カウンタ encounter_pair_counters から常に
--     「累計」として算出する）
--   ・もらったいいね数（期間内）と、そのうちすれ違い無し(likes.encounter_id
--     IS NULL＝イベント/グループ経由)の数・割合
--   ・累計すれ違い数からのいいね化率（累計）
--   ・累計すれ違いからのマッチ数・割合（累計）
--   ・SNSリンクタップ数・プロフィール閲覧に対する割合（期間内）
--  ◯作成した募集(掲示板投稿)ごとのインサイト
--   ・閲覧数／参加人数／気になる数（現在値・延べ人数）
--   ・気になる→参加のコンバージョン率
--     （既存スキーマは status を上書きするため「気になるだった事実」が
--     消える。新設の board_participation_status_log に遷移履歴を残す）
--   ・参加者による招待（拡散）人数・参加人数に対する割合
--     （invite_to_board_post は既に「joined状態の参加者のみ」実行できる
--     ため、invited_by が主催者以外＝参加者経由の拡散として判別可能）
--
--   何度実行しても安全（冪等）。
-- ============================================================

-- ① 掲示板参加ステータスの遷移履歴ログ -------------------------------------

CREATE TABLE IF NOT EXISTS public.board_participation_status_log (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  post_id    UUID NOT NULL REFERENCES public.board_posts(post_id) ON DELETE CASCADE,
  user_id    UUID NOT NULL REFERENCES public.users(user_id) ON DELETE CASCADE,
  status     TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_board_participation_status_log_post
  ON public.board_participation_status_log(post_id, status, user_id, created_at);

ALTER TABLE public.board_participation_status_log ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "board_participation_status_log_select_organizer" ON public.board_participation_status_log;
CREATE POLICY "board_participation_status_log_select_organizer" ON public.board_participation_status_log FOR SELECT USING (
  post_id IN (
    SELECT post_id FROM public.board_posts
    WHERE organizer_id IN (SELECT user_id FROM public.users WHERE auth_id = auth.uid())
  )
);

REVOKE INSERT, UPDATE, DELETE ON public.board_participation_status_log FROM authenticated, anon;

CREATE OR REPLACE FUNCTION public._log_board_participation_status(p_post_id UUID, p_user_id UUID, p_status TEXT)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
  -- このDBでは新規関数がREVOKE ALL FROM PUBLIC後もauthenticatedから直接呼べて
  -- しまうため（既存のcreate_app_notification等も同様）、権限だけに頼らず、
  -- 実際にboard_participationsが同じ状態であることを条件にして偽装ログを防ぐ。
  IF NOT EXISTS (
    SELECT 1 FROM public.board_participations
    WHERE post_id = p_post_id AND user_id = p_user_id AND status = p_status
  ) THEN
    RETURN;
  END IF;

  INSERT INTO public.board_participation_status_log (post_id, user_id, status)
  VALUES (p_post_id, p_user_id, p_status);
END;
$function$;

REVOKE ALL ON FUNCTION public._log_board_participation_status(UUID, UUID, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public._log_board_participation_status(UUID, UUID, TEXT) TO service_role;


-- ② 参加系RPCにログ記録を追加（既存ロジックはそのまま、PERFORM行のみ追加）--------

CREATE OR REPLACE FUNCTION public.express_interest_board_post(p_post_id UUID)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_id UUID;
BEGIN
  SELECT user_id INTO v_caller_id FROM public.users WHERE auth_id = auth.uid();
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'unauthorized';
  END IF;

  INSERT INTO public.board_participations (post_id, user_id, status)
  VALUES (p_post_id, v_caller_id, 'interested')
  ON CONFLICT (post_id, user_id) DO UPDATE
    SET status = 'interested'
    WHERE public.board_participations.status NOT IN ('joined', 'pending');

  PERFORM public._log_board_participation_status(p_post_id, v_caller_id, 'interested');
END;
$$;

REVOKE ALL ON FUNCTION public.express_interest_board_post(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.express_interest_board_post(UUID) TO authenticated;


CREATE OR REPLACE FUNCTION public.join_board_post(p_post_id uuid, p_vehicle_id uuid DEFAULT NULL::uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_caller_id UUID;
  v_organizer_id UUID;
  v_visibility TEXT;
  v_capacity   INT;
  v_scheduled_at TIMESTAMPTZ;
  v_joined_count INT;
  v_status TEXT;
  v_other_user_id UUID;
BEGIN
  SELECT user_id INTO v_caller_id FROM public.users WHERE auth_id = auth.uid();
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'unauthorized';
  END IF;

  SELECT organizer_id, visibility, capacity, scheduled_at
  INTO v_organizer_id, v_visibility, v_capacity, v_scheduled_at
  FROM public.board_posts WHERE post_id = p_post_id FOR UPDATE;

  IF v_organizer_id IS NULL THEN
    RAISE EXCEPTION 'post not found';
  END IF;

  IF v_scheduled_at IS NOT NULL AND v_scheduled_at < NOW() THEN
    RAISE EXCEPTION 'event_ended';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.board_participations
    WHERE post_id = p_post_id AND user_id = v_caller_id AND status IN ('joined', 'pending')
  ) THEN
    RETURN jsonb_build_object('success', TRUE, 'status', 'already_requested');
  END IF;

  IF v_visibility = 'invite_only' THEN
    RAISE EXCEPTION 'this post is invite-only';
  END IF;

  IF v_capacity IS NOT NULL THEN
    SELECT COUNT(*) INTO v_joined_count
    FROM public.board_participations WHERE post_id = p_post_id AND status = 'joined';
    IF v_joined_count >= v_capacity THEN
      RAISE EXCEPTION 'capacity_full';
    END IF;
  END IF;

  v_status := CASE WHEN v_visibility = 'open' THEN 'joined' ELSE 'pending' END;

  INSERT INTO public.board_participations (post_id, user_id, vehicle_id, status)
  VALUES (p_post_id, v_caller_id, p_vehicle_id, v_status)
  ON CONFLICT (post_id, user_id) DO UPDATE SET status = v_status, vehicle_id = p_vehicle_id, responded_at = NULL;

  PERFORM public._log_board_participation_status(p_post_id, v_caller_id, v_status);

  IF v_status = 'pending' THEN
    PERFORM public.create_app_notification(
      v_organizer_id, 'board_join_request',
      jsonb_build_object('post_id', p_post_id), v_caller_id
    );
  ELSIF v_status = 'joined' THEN
    PERFORM public._join_board_post_chat_if_exists(p_post_id, v_caller_id);
    BEGIN
      FOR v_other_user_id IN
        SELECT user_id FROM public.board_participations
        WHERE post_id = p_post_id AND status = 'joined' AND user_id <> v_caller_id
      LOOP
        PERFORM public.increment_together_count(v_caller_id, v_other_user_id, p_post_id);
      END LOOP;
    EXCEPTION WHEN undefined_function THEN
      NULL;
    END;
  END IF;

  RETURN jsonb_build_object('success', TRUE, 'status', v_status);
END;
$function$;


CREATE OR REPLACE FUNCTION public.respond_to_board_invite(p_participation_id uuid, p_accept boolean)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_caller_id    UUID;
  v_post_id      UUID;
  v_inviter      UUID;
  v_capacity     INT;
  v_scheduled_at TIMESTAMPTZ;
  v_joined_count INT;
  v_other_user_id UUID;
BEGIN
  SELECT user_id INTO v_caller_id FROM public.users WHERE auth_id = auth.uid();

  SELECT post_id, invited_by INTO v_post_id, v_inviter
  FROM public.board_participations
  WHERE participation_id = p_participation_id AND user_id = v_caller_id AND status = 'invited';

  IF v_post_id IS NULL THEN
    RAISE EXCEPTION 'invite not found';
  END IF;

  IF NOT p_accept THEN
    DELETE FROM public.board_participations
    WHERE participation_id = p_participation_id AND user_id = v_caller_id AND status = 'invited';

    IF v_inviter IS NOT NULL THEN
      PERFORM public.create_app_notification(
        v_inviter, 'board_invite_declined',
        jsonb_build_object('post_id', v_post_id), v_caller_id
      );
    END IF;

    RETURN jsonb_build_object('success', TRUE, 'status', 'declined');
  END IF;

  SELECT capacity, scheduled_at INTO v_capacity, v_scheduled_at FROM public.board_posts WHERE post_id = v_post_id FOR UPDATE;

  IF v_scheduled_at IS NOT NULL AND v_scheduled_at < NOW() THEN
    RAISE EXCEPTION 'event_ended';
  END IF;

  IF v_capacity IS NOT NULL THEN
    SELECT COUNT(*) INTO v_joined_count
    FROM public.board_participations WHERE post_id = v_post_id AND status = 'joined';
    IF v_joined_count >= v_capacity THEN
      RAISE EXCEPTION 'capacity_full';
    END IF;
  END IF;

  UPDATE public.board_participations
  SET status = 'joined', responded_at = NOW()
  WHERE participation_id = p_participation_id AND user_id = v_caller_id AND status = 'invited';

  PERFORM public._log_board_participation_status(v_post_id, v_caller_id, 'joined');
  PERFORM public._join_board_post_chat_if_exists(v_post_id, v_caller_id);

  BEGIN
    FOR v_other_user_id IN
      SELECT user_id FROM public.board_participations
      WHERE post_id = v_post_id AND status = 'joined' AND user_id <> v_caller_id
    LOOP
      PERFORM public.increment_together_count(v_caller_id, v_other_user_id, v_post_id);
    END LOOP;
  EXCEPTION WHEN undefined_function THEN
    NULL;
  END;

  RETURN jsonb_build_object('success', TRUE, 'status', 'joined');
END;
$function$;


CREATE OR REPLACE FUNCTION public.approve_board_join_request(p_participation_id uuid, p_approve boolean)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_caller_id UUID;
  v_post_id   UUID;
  v_organizer_id UUID;
  v_applicant_id UUID;
  v_scheduled_at TIMESTAMPTZ;
BEGIN
  SELECT user_id INTO v_caller_id FROM public.users WHERE auth_id = auth.uid();

  SELECT post_id, user_id INTO v_post_id, v_applicant_id FROM public.board_participations WHERE participation_id = p_participation_id;
  SELECT organizer_id, scheduled_at INTO v_organizer_id, v_scheduled_at FROM public.board_posts WHERE post_id = v_post_id;

  IF v_organizer_id IS NULL OR v_organizer_id <> v_caller_id THEN
    RAISE EXCEPTION 'only the organizer can approve requests';
  END IF;

  IF p_approve THEN
    IF v_scheduled_at IS NOT NULL AND v_scheduled_at < NOW() THEN
      RAISE EXCEPTION 'event_ended';
    END IF;

    UPDATE public.board_participations
    SET status = 'joined', responded_at = NOW()
    WHERE participation_id = p_participation_id AND status = 'pending';

    PERFORM public._log_board_participation_status(v_post_id, v_applicant_id, 'joined');
    PERFORM public._join_board_post_chat_if_exists(v_post_id, v_applicant_id);
  ELSE
    DELETE FROM public.board_participations
    WHERE participation_id = p_participation_id AND status = 'pending';
  END IF;
END;
$function$;


-- ③ インサイト集計RPCの全面書き換え -----------------------------------------

CREATE OR REPLACE FUNCTION public.get_gear_r_insights(p_days INT DEFAULT 30)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_me UUID;
  v_since TIMESTAMPTZ;

  -- 期間内
  v_profile_views INT;
  v_likes_received INT;
  v_likes_received_encounter INT;
  v_likes_received_non_encounter INT;
  v_likes_received_non_encounter_pct NUMERIC;
  v_likes_sent INT;
  v_matches_period INT;
  v_link_clicks INT;
  v_link_click_pct NUMERIC;

  -- 累計（すれ違いの生ログは24h/7dで自動削除されるため、期間指定はできない）
  v_encounter_count INT;
  v_likes_received_encounter_lifetime INT;
  v_encounter_to_like_rate NUMERIC;
  v_matches_lifetime INT;
  v_matches_from_encounter INT;
  v_matches_from_encounter_pct NUMERIC;
  v_link_click_to_match INT;

  v_daily JSONB;
  v_posts JSONB;
BEGIN
  SELECT user_id INTO v_me FROM public.users WHERE auth_id = auth.uid();
  IF v_me IS NULL THEN
    RAISE EXCEPTION 'unauthorized';
  END IF;
  IF public.user_effective_plan(v_me) <> 'gear_r' THEN
    RAISE EXCEPTION 'gear_r_required';
  END IF;

  v_since := NOW() - (GREATEST(p_days, 1) || ' days')::interval;

  -- ---- 期間内 -------------------------------------------------------
  SELECT count(*) INTO v_profile_views
  FROM public.profile_views WHERE viewed_user_id = v_me AND viewed_at >= v_since;

  SELECT
    count(*),
    count(*) FILTER (WHERE encounter_id IS NOT NULL),
    count(*) FILTER (WHERE encounter_id IS NULL)
  INTO v_likes_received, v_likes_received_encounter, v_likes_received_non_encounter
  FROM public.likes WHERE to_user_id = v_me AND created_at >= v_since;

  v_likes_received_non_encounter_pct := CASE WHEN v_likes_received > 0
    THEN ROUND(v_likes_received_non_encounter::numeric / v_likes_received * 100, 1) ELSE 0 END;

  SELECT count(*) INTO v_likes_sent
  FROM public.likes WHERE from_user_id = v_me AND created_at >= v_since;

  SELECT count(*) INTO v_matches_period
  FROM public.matches WHERE (user_a_id = v_me OR user_b_id = v_me) AND matched_at >= v_since;

  SELECT count(*) INTO v_link_clicks
  FROM public.sns_link_clicks WHERE owner_user_id = v_me AND clicked_at >= v_since;

  v_link_click_pct := CASE WHEN v_profile_views > 0
    THEN ROUND(v_link_clicks::numeric / v_profile_views * 100, 1) ELSE 0 END;

  -- ---- 累計 -----------------------------------------------------------
  SELECT COALESCE(SUM(total_count), 0) INTO v_encounter_count
  FROM public.encounter_pair_counters WHERE user_a_id = v_me OR user_b_id = v_me;

  SELECT count(*) INTO v_likes_received_encounter_lifetime
  FROM public.likes WHERE to_user_id = v_me AND encounter_id IS NOT NULL;

  v_encounter_to_like_rate := CASE WHEN v_encounter_count > 0
    THEN ROUND(v_likes_received_encounter_lifetime::numeric / v_encounter_count * 100, 1) ELSE 0 END;

  SELECT count(*) INTO v_matches_lifetime
  FROM public.matches WHERE user_a_id = v_me OR user_b_id = v_me;

  SELECT count(*) INTO v_matches_from_encounter
  FROM public.matches m
  WHERE (m.user_a_id = v_me OR m.user_b_id = v_me)
    AND EXISTS (
      SELECT 1 FROM public.likes l
      WHERE l.encounter_id IS NOT NULL
        AND ((l.from_user_id = m.user_a_id AND l.to_user_id = m.user_b_id)
          OR (l.from_user_id = m.user_b_id AND l.to_user_id = m.user_a_id))
    );

  v_matches_from_encounter_pct := CASE WHEN v_matches_lifetime > 0
    THEN ROUND(v_matches_from_encounter::numeric / v_matches_lifetime * 100, 1) ELSE 0 END;

  SELECT count(DISTINCT c.clicker_user_id) INTO v_link_click_to_match
  FROM public.sns_link_clicks c
  WHERE c.owner_user_id = v_me
    AND EXISTS (
      SELECT 1 FROM public.matches m
      WHERE (m.user_a_id = v_me AND m.user_b_id = c.clicker_user_id)
         OR (m.user_b_id = v_me AND m.user_a_id = c.clicker_user_id)
    );

  -- ---- 日別推移（グラフ用、期間内） -------------------------------------
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'date', d.day,
    'profile_views', d.pv,
    'link_clicks', d.lc,
    'likes_received', d.lr
  ) ORDER BY d.day), '[]'::jsonb)
  INTO v_daily
  FROM (
    SELECT
      gs.day::date AS day,
      (SELECT count(*) FROM public.profile_views pv
        WHERE pv.viewed_user_id = v_me AND pv.viewed_at::date = gs.day) AS pv,
      (SELECT count(*) FROM public.sns_link_clicks sc
        WHERE sc.owner_user_id = v_me AND sc.clicked_at::date = gs.day) AS lc,
      (SELECT count(*) FROM public.likes l
        WHERE l.to_user_id = v_me AND l.created_at::date = gs.day) AS lr
    FROM generate_series(v_since::date, NOW()::date, '1 day') AS gs(day)
  ) d;

  -- ---- 主催した募集ごとの内訳（累計、直近30件） ---------------------------
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'post_id', p.post_id,
    'title', p.title,
    'scheduled_at', p.scheduled_at,
    'view_count', p.view_count,
    'joined_count', p.joined_count,
    'interested_count', p.interested_count,
    'ever_interested_count', p.ever_interested_count,
    'interested_to_joined_count', p.interested_to_joined_count,
    'interested_to_joined_pct',
      CASE WHEN p.ever_interested_count > 0
        THEN ROUND(p.interested_to_joined_count::numeric / p.ever_interested_count * 100, 1) ELSE 0 END,
    'participant_invited_count', p.participant_invited_count,
    'participant_invited_pct',
      CASE WHEN p.joined_count > 0
        THEN ROUND(p.participant_invited_count::numeric / p.joined_count * 100, 1) ELSE 0 END
  ) ORDER BY p.created_at DESC), '[]'::jsonb)
  INTO v_posts
  FROM (
    SELECT
      bp.post_id, bp.title, bp.scheduled_at, bp.created_at, bp.organizer_id,
      (SELECT count(*) FROM public.board_post_views v WHERE v.post_id = bp.post_id) AS view_count,
      (SELECT count(*) FROM public.board_participations x
        WHERE x.post_id = bp.post_id AND x.status = 'joined') AS joined_count,
      (SELECT count(*) FROM public.board_participations x
        WHERE x.post_id = bp.post_id AND x.status = 'interested') AS interested_count,
      (SELECT count(DISTINCT l.user_id) FROM public.board_participation_status_log l
        WHERE l.post_id = bp.post_id AND l.status = 'interested') AS ever_interested_count,
      (SELECT count(DISTINCT l1.user_id) FROM public.board_participation_status_log l1
        WHERE l1.post_id = bp.post_id AND l1.status = 'interested'
          AND EXISTS (
            SELECT 1 FROM public.board_participation_status_log l2
            WHERE l2.post_id = bp.post_id AND l2.user_id = l1.user_id
              AND l2.status = 'joined' AND l2.created_at >= l1.created_at
          )) AS interested_to_joined_count,
      (SELECT count(*) FROM public.board_participations x
        WHERE x.post_id = bp.post_id AND x.status = 'joined'
          AND x.invited_by IS NOT NULL AND x.invited_by <> bp.organizer_id) AS participant_invited_count
    FROM public.board_posts bp
    WHERE bp.organizer_id = v_me
    ORDER BY bp.created_at DESC
    LIMIT 30
  ) p;

  RETURN jsonb_build_object(
    'period_days', p_days,
    'period', jsonb_build_object(
      'profile_views', v_profile_views,
      'likes_received', v_likes_received,
      'likes_received_encounter', v_likes_received_encounter,
      'likes_received_non_encounter', v_likes_received_non_encounter,
      'likes_received_non_encounter_pct', v_likes_received_non_encounter_pct,
      'likes_sent', v_likes_sent,
      'matches', v_matches_period,
      'link_clicks', v_link_clicks,
      'link_click_pct', v_link_click_pct
    ),
    'lifetime', jsonb_build_object(
      'encounter_count', v_encounter_count,
      'likes_received_encounter', v_likes_received_encounter_lifetime,
      'encounter_to_like_rate', v_encounter_to_like_rate,
      'matches_total', v_matches_lifetime,
      'matches_from_encounter', v_matches_from_encounter,
      'matches_from_encounter_pct', v_matches_from_encounter_pct,
      'link_click_to_match', v_link_click_to_match
    ),
    'daily', v_daily,
    'posts', v_posts
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.get_gear_r_insights(INT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_gear_r_insights(INT) TO authenticated;


-- ============================================================
-- 動作確認用クエリ（手動実行）
-- ============================================================
-- SELECT has_function_privilege('authenticated', 'public.get_gear_r_insights(int)', 'execute') AS can_exec;
-- SELECT has_function_privilege('authenticated', 'public.express_interest_board_post(uuid)', 'execute') AS can_exec;
-- SELECT has_function_privilege('service_role', 'public._log_board_participation_status(uuid,uuid,text)', 'execute') AS can_exec;
