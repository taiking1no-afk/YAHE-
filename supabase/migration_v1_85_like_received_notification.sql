-- ============================================================
-- Migration v1.85 : 「いいねされた」を「お知らせ」に表示されるようにする
-- Supabase SQL Editor で実行してください。
-- ------------------------------------------------------------
-- 背景: app_notifications.type の 'like_received' はCHECK制約・クライアント側
--   の表示ロジック（タイトル「❤️ いいねが届きました」等）は既に用意されて
--   いたが、実際にこの型の通知行を作る箇所がどこにも無く、いいねされても
--   お知らせ画面・未読バッジには一切表示されなかった（いいねタブ本体・
--   ポップアップ・プッシュ通知は別経路のため引き続き機能していた）。
--   send_like() / send_like_no_encounter() に通知作成を追加する。
--
--   マッチと同時に成立した場合は「マッチしました」側の体験を優先し、
--   二重通知を避けるため「いいねされた」通知は送らない。いいねの内容に
--   実質変化が無かった場合（重複いいね等、v_rowcount=0）も送らない。
--
--   何度実行しても安全（冪等）。
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

REVOKE ALL ON FUNCTION public.send_like(UUID, UUID, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.send_like(UUID, UUID, UUID) TO authenticated;
REVOKE ALL ON FUNCTION public.send_like_no_encounter(UUID, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.send_like_no_encounter(UUID, UUID) TO authenticated;
