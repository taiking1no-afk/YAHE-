-- ============================================================
-- Migration v1.63 : すれ違い(encounter)なしでのいいね送信
-- Supabase SQL Editor で実行してください。前提: v1.62実行済み。
-- ------------------------------------------------------------
-- 目的:
--   これまで「いいね」は実際のBLEすれ違い(encounters行)を前提にしていたが、
--   v1.62でグループ・掲示板の共通参加者同士もプロフィールを閲覧できるように
--   したため、そこから「気になったらいいね」できるようにする。
--   個人情報保護のため、この経路のプロフィール表示はマッチ前の限定表示のまま
--   （詳細プロフィールはマッチ後のみ、という既存方針を維持）。
--
--   何度実行しても安全（冪等）。
-- ============================================================

ALTER TABLE public.likes ALTER COLUMN encounter_id DROP NOT NULL;

CREATE OR REPLACE FUNCTION public.send_like_no_encounter(
  p_from_user_id UUID,
  p_to_user_id   UUID
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
  v_rowcount     INT := 0;
BEGIN
  SELECT user_id INTO v_caller FROM public.users WHERE auth_id = auth.uid();
  IF v_caller IS NULL OR v_caller <> p_from_user_id THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'forbidden');
  END IF;

  IF p_from_user_id = p_to_user_id THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'invalid_target');
  END IF;

  -- グループ/掲示板の共通参加者同士であることを要求する
  -- （can_view_userと同じ関係性チェックを流用。ブロック済みならfalseになる）
  IF NOT public.can_view_user(p_to_user_id) THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'not_related');
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
  VALUES (p_from_user_id, p_to_user_id, NULL)
  ON CONFLICT (from_user_id, to_user_id) DO NOTHING;

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

  RETURN jsonb_build_object(
    'success',    TRUE,
    'is_matched', v_is_matched,
    'match_id',   v_match_id,
    'already_liked', (v_rowcount = 0)
  );
END;
$$;

REVOKE ALL ON FUNCTION public.send_like_no_encounter(UUID, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.send_like_no_encounter(UUID, UUID) TO authenticated;
