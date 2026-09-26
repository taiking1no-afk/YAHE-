-- ============================================================
-- v1.31: マッチ前の相手と再度すれ違った際に、もう一度いいねできるようにする
-- ------------------------------------------------------------
-- 背景:
--   send_like() は `INSERT ... ON CONFLICT (from_user_id, to_user_id)
--   DO NOTHING` になっており、一度いいねした相手には、別の（新しい）
--   すれ違いで再度いいねしようとしても常にサイレントに無視されていた
--   （エラーにはならないが、DBは一切更新されず、相手の「いいねされた」
--   一覧も上位に上がってこなかった）。
--
-- 方針:
--   (from_user_id, to_user_id) の一意制約はそのまま維持しつつ（1相手1行）、
--   新しい encounter_id からの再いいねの場合は DO NOTHING ではなく
--   DO UPDATE で encounter_id / created_at を更新する。
--   これにより:
--     - 同じ encounter からの連打は今まで通り no-op（already_liked = true）
--     - 新しいすれ違いからの再いいねは created_at が更新され、
--       受信側の「いいねされた」一覧で新規いいねと同様に上位表示される
--       （一覧は created_at 降順ソートのため、Dart側の変更は不要）
-- ============================================================

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
BEGIN
  SELECT user_id INTO v_caller FROM public.users WHERE auth_id = auth.uid();
  IF v_caller IS NULL OR v_caller <> p_from_user_id THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'forbidden');
  END IF;

  IF p_from_user_id = p_to_user_id THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'invalid_target');
  END IF;

  SELECT user_a_id, user_b_id
  INTO v_enc_a, v_enc_b
  FROM public.encounters
  WHERE encounter_id = p_encounter_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'encounter_not_found');
  END IF;

  -- 期限切れでも「いいねされた」からの返し・別日マッチを許可する
  -- （ホームの表示期限は encounters.expires_at / クライアントフィルタで別管理）
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

  -- 新しい encounter からの再いいねは、既存行を新しい encounter_id / created_at
  -- で更新する（1相手1行の制約は維持）。同じ encounter からの連打（encounter_id
  -- が変わらない）場合だけ DO UPDATE の WHERE 条件に一致せず no-op になる。
  INSERT INTO public.likes (from_user_id, to_user_id, encounter_id)
  VALUES (p_from_user_id, p_to_user_id, p_encounter_id)
  ON CONFLICT (from_user_id, to_user_id) DO UPDATE
    SET encounter_id = EXCLUDED.encounter_id,
        created_at = NOW()
    WHERE public.likes.encounter_id IS DISTINCT FROM EXCLUDED.encounter_id;

  GET DIAGNOSTICS v_rowcount = ROW_COUNT;

  -- 相手ユーザー単位で相互いいねを判定（encounter_id / すれ違い日は問わない）
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

REVOKE ALL ON FUNCTION public.send_like(UUID, UUID, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.send_like(UUID, UUID, UUID) TO authenticated;
