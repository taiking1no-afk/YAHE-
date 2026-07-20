-- ============================================================
-- Migration v1.18 : Gear+ サブスク初月無料（App Store イントロオファー）
-- Supabase SQL Editor で実行してください。前提: v1.1〜v1.17 推奨。
-- ------------------------------------------------------------
-- 変更点:
--   ① 新規登録時の30日自動トライアルを廃止
--   ② gear_plus_trial_used_at … 初回お試し利用済みフラグ
--   ③ sync_subscription_plan RPC … RevenueCat 同期用
--   ④ user_effective_plan … 未購入ユーザーの trial_ends_at による
--      プレミアム付与を停止（購入後のイントロ期間のみ plan=gear_plus）
--
--   何度実行しても安全（冪等）。
-- ============================================================


-- ============================================================
-- ① gear_plus_trial_used_at カラム追加
-- ============================================================
ALTER TABLE public.users
  ADD COLUMN IF NOT EXISTS gear_plus_trial_used_at TIMESTAMPTZ;


-- ============================================================
-- ② 新規登録時の自動30日トライアルを廃止
-- ============================================================
DROP TRIGGER IF EXISTS trg_users_apply_trial_on_signup ON public.users;
DROP FUNCTION IF EXISTS public.users_apply_trial_on_signup();


-- ============================================================
-- ③ 未購入ユーザーに自動付与されていたトライアルを解除
--    （新モデル: お試しは Gear+ サブスク加入時のみ）
-- ============================================================
UPDATE public.users
SET trial_ends_at = NULL
WHERE plan = 'free'
  AND gear_plus_trial_used_at IS NULL
  AND trial_ends_at IS NOT NULL;


-- ============================================================
-- ④ プレミアム判定を更新（未購入 + trial_ends_at だけでは premium にならない）
-- ============================================================
CREATE OR REPLACE FUNCTION public.user_effective_plan(p_user_id UUID)
RETURNS TEXT
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_plan             TEXT;
  v_override_plan    TEXT;
  v_override_active  BOOLEAN;
BEGIN
  SELECT
    COALESCE(u.plan, 'free'),
    u.premium_override_plan,
    (u.premium_override_plan IS NOT NULL
      AND (u.premium_override_expires_at IS NULL OR u.premium_override_expires_at > NOW()))
  INTO v_plan, v_override_plan, v_override_active
  FROM public.users u
  WHERE u.user_id = p_user_id;

  IF NOT FOUND THEN
    RETURN 'free';
  END IF;

  IF v_plan = 'gear_r'
     OR (v_override_active AND v_override_plan = 'gear_r') THEN
    RETURN 'gear_r';
  END IF;

  IF v_plan = 'gear_plus'
     OR (v_override_active AND v_override_plan = 'gear_plus') THEN
    RETURN 'gear_plus';
  END IF;

  RETURN 'free';
END;
$$;

CREATE OR REPLACE FUNCTION public.users_sync_premium_after_change()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_effective TEXT := 'free';
  v_override_active BOOLEAN;
BEGIN
  v_override_active := NEW.premium_override_plan IS NOT NULL
    AND (NEW.premium_override_expires_at IS NULL OR NEW.premium_override_expires_at > NOW());

  IF NEW.plan = 'gear_r'
     OR (v_override_active AND NEW.premium_override_plan = 'gear_r') THEN
    v_effective := 'gear_r';
  ELSIF NEW.plan = 'gear_plus'
     OR (v_override_active AND NEW.premium_override_plan = 'gear_plus') THEN
    v_effective := 'gear_plus';
  END IF;

  NEW.is_premium := (v_effective <> 'free');
  RETURN NEW;
END;
$$;


-- ============================================================
-- ④-b 前提: sync_user_premium（v1.15 未適用環境向けブートストラップ）
-- ============================================================
CREATE OR REPLACE FUNCTION public.user_is_premium(p_user_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public.user_effective_plan(p_user_id) <> 'free';
$$;

CREATE OR REPLACE FUNCTION public.sync_user_premium(p_user_id UUID)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE public.users
  SET is_premium = public.user_is_premium(p_user_id)
  WHERE user_id = p_user_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.sync_all_user_premium()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  r RECORD;
BEGIN
  FOR r IN SELECT user_id FROM public.users LOOP
    PERFORM public.sync_user_premium(r.user_id);
  END LOOP;
END;
$$;


-- ============================================================
-- ⑤ RevenueCat 同期 RPC（クライアントから呼び出し）
-- ------------------------------------------------------------
-- p_plan: 'free' | 'gear_plus' | 'gear_r'
-- p_trial_ends_at: イントロ/トライアル期間の終了日時（UI表示用）
-- p_mark_trial_used: Gear+ 初回お試し利用済みにする
-- ============================================================
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
BEGIN
  IF p_plan NOT IN ('free', 'gear_plus', 'gear_r') THEN
    RAISE EXCEPTION 'invalid plan: %', p_plan;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.users
    WHERE user_id = p_user_id AND auth_id = auth.uid()
  ) THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  IF p_plan = 'free' THEN
    UPDATE public.users
    SET
      plan = 'free',
      trial_ends_at = NULL
    WHERE user_id = p_user_id
      AND plan IN ('gear_plus', 'gear_r');
  ELSIF p_plan = 'gear_r' THEN
    UPDATE public.users
    SET
      plan = 'gear_r',
      trial_ends_at = NULL,
      gear_plus_trial_used_at = COALESCE(gear_plus_trial_used_at, NOW())
    WHERE user_id = p_user_id;
  ELSE
    UPDATE public.users
    SET
      plan = 'gear_plus',
      trial_ends_at = p_trial_ends_at,
      gear_plus_trial_used_at = CASE
        WHEN p_mark_trial_used THEN COALESCE(gear_plus_trial_used_at, NOW())
        ELSE gear_plus_trial_used_at
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

GRANT EXECUTE ON FUNCTION public.sync_subscription_plan(UUID, TEXT, TIMESTAMPTZ, BOOLEAN)
  TO authenticated;


-- ============================================================
-- ⑥ grant_gear_plus を新モデルに合わせて更新
-- ============================================================
CREATE OR REPLACE FUNCTION public.grant_gear_plus(p_user_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM public.sync_subscription_plan(
    p_user_id,
    'gear_plus',
    NULL,
    TRUE
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.grant_gear_plus(UUID) TO authenticated;


-- ============================================================
-- ⑦ is_premium 同期
-- ============================================================
SELECT public.sync_all_user_premium();
