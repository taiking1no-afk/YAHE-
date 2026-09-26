-- ============================================================
-- Migration v1.102 : Gear R「お試し500円」のDB側基盤
-- Supabase SQL Editor で実行してください。前提: v1.27（sync_subscription_plan）実行済み。
-- ------------------------------------------------------------
-- 背景:
--   Gear+には「初回1ヶ月無料」のトライアル管理（gear_plus_trial_used_at +
--   sync_subscription_plan の p_mark_trial_used）が既にあるが、Gear Rには
--   同等の仕組みが無い。App Store Connect側の導入価格(Introductory Offer)
--   商品設定はまだ行っていない前提で、先にデータベース側の受け皿だけを
--   用意する（開発者の指示により今回はDB側のみ、Flutter側のUI/モデルは
--   後続で対応）。
--
--   現状の sync_subscription_plan の gear_r 分岐は
--     - trial_ends_at を常に NULL 上書き（p_trial_ends_at を無視）
--     - gear_plus_trial_used_at のみ更新（Gear R専用の使用済みフラグが無い）
--   という状態だったため、Gear+と同じ形に揃える。
--
--   何度実行しても安全（冪等）。
-- ============================================================

-- ① Gear R トライアル使用済みフラグ
ALTER TABLE public.users
  ADD COLUMN IF NOT EXISTS gear_r_trial_used_at TIMESTAMPTZ;

-- ② sync_subscription_plan: gear_r 分岐で trial_ends_at を反映し、
--    gear_r_trial_used_at を記録するように更新
CREATE OR REPLACE FUNCTION public.sync_subscription_plan(
  p_user_id          UUID,
  p_plan             TEXT,
  p_trial_ends_at    TIMESTAMPTZ DEFAULT NULL,
  p_mark_trial_used  BOOLEAN DEFAULT FALSE
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_effective TEXT;
  v_prev_plan TEXT;
BEGIN
  PERFORM set_config('yaeh.allow_sensitive_update', '1', true);

  IF p_plan NOT IN ('free', 'pit_in', 'gear_plus', 'gear_r') THEN
    RAISE EXCEPTION 'invalid plan: %', p_plan;
  END IF;

  SELECT plan INTO v_prev_plan FROM public.users WHERE user_id = p_user_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'user not found';
  END IF;

  IF p_plan = 'free' THEN
    UPDATE public.users
    SET
      plan = 'free',
      trial_ends_at = NULL,
      is_verified = CASE
        WHEN plan = 'gear_r' THEN FALSE
        ELSE is_verified
      END,
      verified_label = CASE
        WHEN plan = 'gear_r' THEN NULL
        ELSE verified_label
      END
    WHERE user_id = p_user_id
      AND plan IN ('pit_in', 'gear_plus', 'gear_r');
  ELSIF p_plan = 'gear_r' THEN
    UPDATE public.users
    SET
      plan = 'gear_r',
      -- Gear+と同様、導入価格(トライアル)期間中はRevenueCatから渡された
      -- 終了日時をそのまま反映する（以前は常にNULL上書きしていた）
      trial_ends_at = p_trial_ends_at,
      gear_plus_trial_used_at = COALESCE(gear_plus_trial_used_at, NOW()),
      gear_r_trial_used_at = CASE
        WHEN p_mark_trial_used THEN COALESCE(gear_r_trial_used_at, NOW())
        ELSE gear_r_trial_used_at
      END,
      is_verified = TRUE,
      gear_r_applied_at = COALESCE(gear_r_applied_at, NOW())
    WHERE user_id = p_user_id;
  ELSIF p_plan = 'gear_plus' THEN
    UPDATE public.users
    SET
      plan = 'gear_plus',
      trial_ends_at = p_trial_ends_at,
      gear_plus_trial_used_at = CASE
        WHEN p_mark_trial_used THEN COALESCE(gear_plus_trial_used_at, NOW())
        ELSE gear_plus_trial_used_at
      END,
      is_verified = CASE
        WHEN v_prev_plan = 'gear_r' THEN FALSE
        ELSE is_verified
      END,
      verified_label = CASE
        WHEN v_prev_plan = 'gear_r' THEN NULL
        ELSE verified_label
      END
    WHERE user_id = p_user_id;
  ELSE
    -- pit_in
    UPDATE public.users
    SET
      plan = 'pit_in',
      is_verified = CASE
        WHEN v_prev_plan = 'gear_r' THEN FALSE
        ELSE is_verified
      END,
      verified_label = CASE
        WHEN v_prev_plan = 'gear_r' THEN NULL
        ELSE verified_label
      END
    WHERE user_id = p_user_id;
  END IF;

  PERFORM public.sync_user_premium(p_user_id);
  v_effective := public.user_effective_plan(p_user_id);

  RETURN jsonb_build_object(
    'success',        TRUE,
    'effective_plan', v_effective
  );
END;
$$;

REVOKE ALL ON FUNCTION public.sync_subscription_plan(UUID, TEXT, TIMESTAMPTZ, BOOLEAN) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.sync_subscription_plan(UUID, TEXT, TIMESTAMPTZ, BOOLEAN) FROM authenticated;
REVOKE ALL ON FUNCTION public.sync_subscription_plan(UUID, TEXT, TIMESTAMPTZ, BOOLEAN) FROM anon;
GRANT EXECUTE ON FUNCTION public.sync_subscription_plan(UUID, TEXT, TIMESTAMPTZ, BOOLEAN) TO service_role;

-- ============================================================
-- 動作確認用クエリ（手動実行）
-- ============================================================
-- SELECT column_name FROM information_schema.columns WHERE table_name='users' AND column_name='gear_r_trial_used_at';
-- SELECT prosrc ILIKE '%gear_r_trial_used_at%' FROM pg_proc WHERE proname='sync_subscription_plan';
