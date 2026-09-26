-- ============================================================
-- Migration v1.47 : premium_grants監査テーブルの復旧 + テスト期間中の無期限付与化
-- Supabase SQL Editor で実行してください。
-- ------------------------------------------------------------
-- 背景:
--   v1.15（無料付与・トライアル管理）は本番に一度も適用されていなかった。
--   v1.33（テスター自動付与）だけが先に適用された結果、v1.33のAFTERトリガーが
--   存在しないpremium_grantsテーブルへのINSERTで失敗し、新規登録が壊れる事故が
--   起きた（当時の緊急対応でAFTERトリガーのみ削除、以後は付与の監査ログが
--   一切残っていない）。
--
--   v1.15をそのまま適用すると send_like/register_encounter/grant_gear_plus を
--   v1.15時点の古いロジックで上書きしてしまい、v1.16〜v1.31で入った改善
--   （すれ違い日次重複排除・いいね再送信対応 等）が巻き戻る恐れがあるため、
--   ここでは premium_grants まわりの安全な部分だけを抽出して適用する。
--   （新規登録者への自動30日トライアル機能=v1.15§④は意図的に含めない。
--   「テスト期間終了後の1ヶ月無料」は既存のストア側トライアル
--   （gear_plus_trial_used_at・RevenueCat）で対応する設計のため、
--   ここで別のDB内トライアルを重ねると二重無料化してしまう）
--
--   何度実行しても安全（冪等）。
-- ============================================================


-- ============================================================
-- ① 付与履歴テーブル（v1.15§②から。監査ログ復旧のため必須）
-- ============================================================
CREATE TABLE IF NOT EXISTS public.premium_grants (
  grant_id        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         UUID NOT NULL REFERENCES public.users(user_id) ON DELETE CASCADE,
  plan            TEXT NOT NULL CHECK (plan IN ('gear_plus', 'gear_r')),
  source          TEXT NOT NULL CHECK (source IN ('trial', 'admin', 'influencer', 'test')),
  reason          TEXT,
  granted_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  expires_at      TIMESTAMPTZ,          -- NULL = 無期限
  revoked_at      TIMESTAMPTZ,
  revoked_reason  TEXT,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_premium_grants_user_id ON public.premium_grants(user_id);
CREATE INDEX IF NOT EXISTS idx_premium_grants_active
  ON public.premium_grants(user_id, expires_at)
  WHERE revoked_at IS NULL;

ALTER TABLE public.premium_grants ENABLE ROW LEVEL SECURITY;
-- 一般ユーザーには見せない（service_role のみ）

REVOKE ALL ON public.premium_grants FROM anon, authenticated;
GRANT  SELECT, INSERT, UPDATE ON public.premium_grants TO service_role;


-- ============================================================
-- ② 運営オペRPC（v1.15§⑤/⑩から。service_role専用）
-- ============================================================

CREATE OR REPLACE FUNCTION public.admin_grant_premium(
  p_user_id   UUID,
  p_plan      TEXT    DEFAULT 'gear_plus',
  p_expires_at TIMESTAMPTZ DEFAULT NULL,
  p_source    TEXT    DEFAULT 'admin',
  p_reason    TEXT    DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_effective TEXT;
BEGIN
  IF p_plan NOT IN ('gear_plus', 'gear_r') THEN
    RAISE EXCEPTION 'invalid plan: %', p_plan;
  END IF;
  IF p_source NOT IN ('admin', 'influencer', 'test') THEN
    RAISE EXCEPTION 'invalid source: %', p_source;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.users WHERE user_id = p_user_id) THEN
    RAISE EXCEPTION 'user not found: %', p_user_id;
  END IF;

  UPDATE public.premium_grants
  SET revoked_at = NOW(), revoked_reason = 'replaced_by_new_grant'
  WHERE user_id = p_user_id
    AND revoked_at IS NULL
    AND source IN ('admin', 'influencer', 'test');

  INSERT INTO public.premium_grants (user_id, plan, source, reason, expires_at)
  VALUES (p_user_id, p_plan, p_source, p_reason, p_expires_at);

  UPDATE public.users
  SET
    premium_override_plan       = p_plan,
    premium_override_expires_at = p_expires_at,
    premium_override_source     = p_source,
    premium_override_reason     = p_reason
  WHERE user_id = p_user_id;

  IF p_plan = 'gear_r' THEN
    UPDATE public.users
    SET is_verified = TRUE, gear_r_applied_at = NOW()
    WHERE user_id = p_user_id;
  END IF;

  PERFORM public.sync_user_premium(p_user_id);
  v_effective := public.user_effective_plan(p_user_id);

  RETURN jsonb_build_object(
    'success',         TRUE,
    'user_id',         p_user_id,
    'granted_plan',    p_plan,
    'effective_plan',  v_effective,
    'expires_at',      p_expires_at
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_revoke_premium(
  p_user_id UUID,
  p_reason  TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_effective TEXT;
BEGIN
  UPDATE public.premium_grants
  SET revoked_at = NOW(), revoked_reason = COALESCE(p_reason, 'admin_revoke')
  WHERE user_id = p_user_id
    AND revoked_at IS NULL
    AND source IN ('admin', 'influencer', 'test');

  UPDATE public.users
  SET
    premium_override_plan       = NULL,
    premium_override_expires_at = NULL,
    premium_override_source     = NULL,
    premium_override_reason     = NULL
  WHERE user_id = p_user_id;

  PERFORM public.sync_user_premium(p_user_id);
  v_effective := public.user_effective_plan(p_user_id);

  RETURN jsonb_build_object(
    'success',        TRUE,
    'user_id',        p_user_id,
    'effective_plan', v_effective
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_extend_trial(
  p_user_id UUID,
  p_days    INT  DEFAULT 30,
  p_reason  TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_new_ends TIMESTAMPTZ;
BEGIN
  IF p_days <= 0 THEN
    RAISE EXCEPTION 'p_days must be positive';
  END IF;

  UPDATE public.users
  SET trial_ends_at = GREATEST(COALESCE(trial_ends_at, NOW()), NOW()) + (p_days || ' days')::INTERVAL
  WHERE user_id = p_user_id
  RETURNING trial_ends_at INTO v_new_ends;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'user not found: %', p_user_id;
  END IF;

  INSERT INTO public.premium_grants (user_id, plan, source, reason, expires_at)
  VALUES (p_user_id, 'gear_plus', 'admin', COALESCE(p_reason, 'trial_extension'), v_new_ends);

  PERFORM public.sync_user_premium(p_user_id);

  RETURN jsonb_build_object(
    'success',       TRUE,
    'user_id',       p_user_id,
    'trial_ends_at', v_new_ends
  );
END;
$$;

REVOKE ALL ON FUNCTION public.admin_grant_premium(UUID, TEXT, TIMESTAMPTZ, TEXT, TEXT) FROM public;
REVOKE ALL ON FUNCTION public.admin_revoke_premium(UUID, TEXT)                         FROM public;
REVOKE ALL ON FUNCTION public.admin_extend_trial(UUID, INT, TEXT)                      FROM public;
GRANT EXECUTE ON FUNCTION public.admin_grant_premium(UUID, TEXT, TIMESTAMPTZ, TEXT, TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.admin_revoke_premium(UUID, TEXT)                         TO service_role;
GRANT EXECUTE ON FUNCTION public.admin_extend_trial(UUID, INT, TEXT)                      TO service_role;


-- ============================================================
-- ③ 期限切れ付与のクリーンアップ（v1.15§⑩から。cron）
-- ============================================================
CREATE OR REPLACE FUNCTION public.expire_premium_overrides()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  r RECORD;
BEGIN
  FOR r IN
    SELECT user_id FROM public.users
    WHERE premium_override_plan IS NOT NULL
      AND premium_override_expires_at IS NOT NULL
      AND premium_override_expires_at <= NOW()
  LOOP
    UPDATE public.premium_grants
    SET revoked_at = NOW(), revoked_reason = 'expired'
    WHERE user_id = r.user_id
      AND revoked_at IS NULL
      AND source IN ('admin', 'influencer', 'test');

    UPDATE public.users
    SET
      premium_override_plan       = NULL,
      premium_override_expires_at = NULL,
      premium_override_source     = NULL,
      premium_override_reason     = NULL
    WHERE user_id = r.user_id;

    PERFORM public.sync_user_premium(r.user_id);
  END LOOP;

  PERFORM public.sync_all_user_premium();
END;
$$;

REVOKE ALL ON FUNCTION public.expire_premium_overrides() FROM public;
GRANT EXECUTE ON FUNCTION public.expire_premium_overrides() TO service_role;

DO $cron_setup$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'pg_cron') THEN
    IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'expire-premium-overrides') THEN
      PERFORM cron.unschedule('expire-premium-overrides');
    END IF;
    PERFORM cron.schedule(
      'expire-premium-overrides', '0 15 * * *',  -- 毎日 00:00 JST
      $job$SELECT public.expire_premium_overrides()$job$
    );
  END IF;
END $cron_setup$;


-- ============================================================
-- ④ 運営ビュー（v1.15§⑧から。任意・service_role専用）
-- ============================================================
CREATE OR REPLACE VIEW public.premium_status_overview AS
SELECT
  u.user_id,
  u.nickname,
  u.plan                                              AS paid_plan,
  public.user_effective_plan(u.user_id)               AS effective_plan,
  public.user_is_premium(u.user_id)                   AS is_premium_effective,
  u.trial_ends_at,
  (u.trial_ends_at IS NOT NULL AND u.trial_ends_at > NOW()) AS trial_active,
  u.premium_override_plan,
  u.premium_override_expires_at,
  u.premium_override_source,
  u.premium_override_reason,
  u.created_at
FROM public.users u
ORDER BY u.created_at DESC;

REVOKE ALL ON public.premium_status_overview FROM anon, authenticated;
GRANT  SELECT ON public.premium_status_overview TO service_role;


-- ============================================================
-- ⑤ v1.33のAFTER監査トリガーを復旧（premium_grantsが今できたので書き込める）
-- ============================================================
CREATE OR REPLACE FUNCTION public.users_tester_auto_grant_after()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.premium_override_source = 'test'
     AND NEW.premium_override_reason = 'tester_auto_grant' THEN
    INSERT INTO public.premium_grants (user_id, plan, source, reason, expires_at)
    VALUES (
      NEW.user_id,
      NEW.premium_override_plan,
      'test',
      'tester_auto_grant',
      NEW.premium_override_expires_at
    );
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_users_tester_auto_grant_audit ON public.users;
CREATE TRIGGER trg_users_tester_auto_grant_audit
  AFTER INSERT ON public.users
  FOR EACH ROW
  EXECUTE FUNCTION public.users_tester_auto_grant_after();


-- ============================================================
-- ⑥ テスト期間中の自動付与を「無期限」に変更
-- ------------------------------------------------------------
-- 従来は expires_days（デフォルト90日）で個別に失効していたが、
-- 特典期間の終了はowner_ops_gate.md セクションFの手順で全員一斉に
-- 打ち切る運用のため、個別の期限は設けず無期限（NULL）にする。
-- 一斉打ち切りのSQLは元々 `expires_at IS NULL OR expires_at > NOW()` を
-- 条件にしているため、この変更のみで無期限化に対応できる。
-- ============================================================
CREATE OR REPLACE FUNCTION public.users_tester_auto_grant_before()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_cfg JSONB;
BEGIN
  SELECT value INTO v_cfg FROM public.app_config WHERE key = 'tester_auto_grant';

  IF v_cfg IS NOT NULL
     AND COALESCE((v_cfg->>'enabled')::boolean, false)
     AND NEW.premium_override_plan IS NULL THEN
    NEW.premium_override_plan := COALESCE(v_cfg->>'plan', 'gear_plus');
    NEW.premium_override_expires_at := CASE
      WHEN (v_cfg->>'expires_days') IS NOT NULL
        THEN NOW() + make_interval(days => (v_cfg->>'expires_days')::int)
      ELSE NULL  -- 無期限
    END;
    NEW.premium_override_source := 'test';
    NEW.premium_override_reason := 'tester_auto_grant';
  END IF;

  RETURN NEW;
END;
$$;

-- expires_days を削除 → 以後の新規登録は無期限付与になる
UPDATE public.app_config
SET value = (value - 'expires_days'), updated_at = NOW()
WHERE key = 'tester_auto_grant';
