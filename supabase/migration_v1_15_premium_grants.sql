-- ============================================================
-- Migration v1.15 : 無料付与・トライアル管理
-- Supabase SQL Editor で実行してください。前提: v1.1〜v1.14 実行済み。
-- ------------------------------------------------------------
-- 目的:
--   ① 新規登録ユーザーに30日間 Gear+ トライアルを自動付与
--   ② 運営が特定ユーザーへ期限付き/永久の無料プレミアム付与（インフルエンサー等）
--   ③ plan / is_premium の不整合を解消（同期関数 + RPC で正確な判定）
--   ④ 付与履歴テーブル（premium_grants）で監査可能に
--
--   何度実行しても安全（冪等）。
-- ============================================================


-- ============================================================
-- ① users テーブル拡張
-- ============================================================
ALTER TABLE public.users
  ADD COLUMN IF NOT EXISTS plan TEXT NOT NULL DEFAULT 'free',
  ADD COLUMN IF NOT EXISTS trial_ends_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS premium_override_plan TEXT,
  ADD COLUMN IF NOT EXISTS premium_override_expires_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS premium_override_source TEXT,
  ADD COLUMN IF NOT EXISTS premium_override_reason TEXT,
  ADD COLUMN IF NOT EXISTS is_verified BOOLEAN NOT NULL DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS gear_r_applied_at TIMESTAMPTZ;

-- plan / override の値域チェック（既存制約が無い場合のみ）
DO $chk$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'users_plan_check'
  ) THEN
    ALTER TABLE public.users
      ADD CONSTRAINT users_plan_check
      CHECK (plan IN ('free', 'gear_plus', 'gear_r'));
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'users_premium_override_plan_check'
  ) THEN
    ALTER TABLE public.users
      ADD CONSTRAINT users_premium_override_plan_check
      CHECK (
        premium_override_plan IS NULL
        OR premium_override_plan IN ('gear_plus', 'gear_r')
      );
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'users_premium_override_source_check'
  ) THEN
    ALTER TABLE public.users
      ADD CONSTRAINT users_premium_override_source_check
      CHECK (
        premium_override_source IS NULL
        OR premium_override_source IN ('admin', 'influencer', 'test')
      );
  END IF;
END $chk$;


-- ============================================================
-- ② 付与履歴テーブル（監査用）
-- ============================================================
CREATE TABLE IF NOT EXISTS public.premium_grants (
  grant_id        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         UUID NOT NULL REFERENCES public.users(user_id) ON DELETE CASCADE,
  plan            TEXT NOT NULL CHECK (plan IN ('gear_plus', 'gear_r')),
  source          TEXT NOT NULL CHECK (source IN ('trial', 'admin', 'influencer', 'test')),
  reason          TEXT,
  granted_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  expires_at      TIMESTAMPTZ,          -- NULL = 永久付与
  revoked_at      TIMESTAMPTZ,
  revoked_reason  TEXT,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_premium_grants_user_id
  ON public.premium_grants(user_id);
CREATE INDEX IF NOT EXISTS idx_premium_grants_active
  ON public.premium_grants(user_id, expires_at)
  WHERE revoked_at IS NULL;

ALTER TABLE public.premium_grants ENABLE ROW LEVEL SECURITY;
-- 一般ユーザーには見せない（service_role のみ）


-- ============================================================
-- ③ プレミアム判定ヘルパー
-- ------------------------------------------------------------
-- 優先度（高い方を effective_plan に反映）:
--   gear_r  > gear_plus > free
-- ソース:
--   - users.plan（RevenueCat 購入でクライアントが更新）
--   - premium_override_*（運営付与 / インフルエンサー）
--   - trial_ends_at（新規30日トライアル → gear_plus 相当）
-- ============================================================

CREATE OR REPLACE FUNCTION public._user_has_active_override(p_user_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.users u
    WHERE u.user_id = p_user_id
      AND u.premium_override_plan IS NOT NULL
      AND (u.premium_override_expires_at IS NULL OR u.premium_override_expires_at > NOW())
  );
$$;

CREATE OR REPLACE FUNCTION public._user_has_active_trial(p_user_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.users u
    WHERE u.user_id = p_user_id
      AND u.trial_ends_at IS NOT NULL
      AND u.trial_ends_at > NOW()
  );
$$;

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
  v_trial_active     BOOLEAN;
BEGIN
  SELECT
    COALESCE(u.plan, 'free'),
    u.premium_override_plan,
    (u.premium_override_plan IS NOT NULL
      AND (u.premium_override_expires_at IS NULL OR u.premium_override_expires_at > NOW())),
    (u.trial_ends_at IS NOT NULL AND u.trial_ends_at > NOW())
  INTO v_plan, v_override_plan, v_override_active, v_trial_active
  FROM public.users u
  WHERE u.user_id = p_user_id;

  IF NOT FOUND THEN
    RETURN 'free';
  END IF;

  -- gear_r が最優先
  IF v_plan = 'gear_r'
     OR (v_override_active AND v_override_plan = 'gear_r') THEN
    RETURN 'gear_r';
  END IF;

  -- gear_plus（購入 / 付与 / トライアル）
  IF v_plan = 'gear_plus'
     OR (v_override_active AND v_override_plan = 'gear_plus')
     OR v_trial_active THEN
    RETURN 'gear_plus';
  END IF;

  RETURN 'free';
END;
$$;

CREATE OR REPLACE FUNCTION public.user_is_premium(p_user_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public.user_effective_plan(p_user_id) <> 'free';
$$;

-- is_premium カラムを KPI 用に同期（RPC 判定と一致させる）
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
-- ④ 新規登録時に30日トライアルを自動付与
-- ============================================================
CREATE OR REPLACE FUNCTION public.users_apply_trial_on_signup()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.trial_ends_at IS NULL THEN
    NEW.trial_ends_at := NOW() + INTERVAL '30 days';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_users_apply_trial_on_signup ON public.users;
CREATE TRIGGER trg_users_apply_trial_on_signup
  BEFORE INSERT ON public.users
  FOR EACH ROW
  EXECUTE FUNCTION public.users_apply_trial_on_signup();

CREATE OR REPLACE FUNCTION public.users_sync_premium_after_change()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_effective TEXT := 'free';
  v_override_active BOOLEAN;
  v_trial_active BOOLEAN;
BEGIN
  v_override_active := NEW.premium_override_plan IS NOT NULL
    AND (NEW.premium_override_expires_at IS NULL OR NEW.premium_override_expires_at > NOW());
  v_trial_active := NEW.trial_ends_at IS NOT NULL AND NEW.trial_ends_at > NOW();

  IF NEW.plan = 'gear_r'
     OR (v_override_active AND NEW.premium_override_plan = 'gear_r') THEN
    v_effective := 'gear_r';
  ELSIF NEW.plan = 'gear_plus'
     OR (v_override_active AND NEW.premium_override_plan = 'gear_plus')
     OR v_trial_active THEN
    v_effective := 'gear_plus';
  END IF;

  NEW.is_premium := (v_effective <> 'free');
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_users_sync_premium ON public.users;
CREATE TRIGGER trg_users_sync_premium
  BEFORE INSERT OR UPDATE OF plan, trial_ends_at,
    premium_override_plan, premium_override_expires_at
  ON public.users
  FOR EACH ROW
  EXECUTE FUNCTION public.users_sync_premium_after_change();


-- ============================================================
-- ⑤ 運営オペ RPC（service_role 専用）
-- ============================================================

-- 無料プレミアム付与
-- p_expires_at = NULL → 永久付与
-- p_source: 'admin' | 'influencer' | 'test'
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

  -- 既存の有効な手動付与を履歴上クローズ
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

  -- Gear R 付与時は認証バッジも付与（従来 admin_grant_gear_r.sql と同等）
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

-- 手動付与の解除（RevenueCat 購入 plan / トライアルは維持）
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

-- トライアル延長（キャンペーン等）
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


-- ============================================================
-- ⑥ grant_gear_plus RPC 修正（is_premium も更新）
-- ============================================================
CREATE OR REPLACE FUNCTION public.grant_gear_plus(p_user_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE public.users
  SET plan = 'gear_plus', is_premium = TRUE
  WHERE user_id = p_user_id
    AND auth_id = auth.uid()
    AND plan = 'free';
END;
$$;


-- ============================================================
-- ⑦ send_like / register_encounter を正確な判定に更新
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
BEGIN
  SELECT user_id INTO v_caller FROM public.users WHERE auth_id = auth.uid();
  IF v_caller IS NULL OR v_caller <> p_from_user_id THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'forbidden');
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
  IF COALESCE(v_like_count, 0) >= 200 THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'daily_limit_exceeded');
  END IF;

  INSERT INTO public.likes (from_user_id, to_user_id, encounter_id)
  VALUES (p_from_user_id, p_to_user_id, p_encounter_id)
  ON CONFLICT (from_user_id, to_user_id, encounter_id) DO NOTHING;

  IF EXISTS (
    SELECT 1 FROM public.likes
    WHERE from_user_id = p_to_user_id
      AND to_user_id = p_from_user_id
      AND encounter_id = p_encounter_id
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
    'match_id',   v_match_id
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.register_encounter(p_other_user_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_my_user_id   uuid;
  v_sorted_a     uuid;
  v_sorted_b     uuid;
  v_a_premium    boolean;
  v_b_premium    boolean;
  v_expires_at   timestamptz;
  v_occurrence   integer;
BEGIN
  SELECT user_id INTO v_my_user_id
  FROM public.users
  WHERE auth_id = auth.uid();

  IF v_my_user_id IS NULL THEN
    RAISE EXCEPTION 'not authenticated';
  END IF;

  IF p_other_user_id IS NULL OR p_other_user_id = v_my_user_id THEN
    RETURN;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.users WHERE user_id = p_other_user_id) THEN
    RETURN;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.blocks b
    WHERE (b.blocker_id = v_my_user_id AND b.blocked_id = p_other_user_id)
       OR (b.blocker_id = p_other_user_id AND b.blocked_id = v_my_user_id)
  ) THEN
    RETURN;
  END IF;

  v_sorted_a := LEAST(v_my_user_id, p_other_user_id);
  v_sorted_b := GREATEST(v_my_user_id, p_other_user_id);

  IF EXISTS (
    SELECT 1
    FROM public.encounters
    WHERE user_a_id = v_sorted_a
      AND user_b_id = v_sorted_b
      AND time > now() - interval '5 minutes'
  ) THEN
    RETURN;
  END IF;

  v_a_premium := public.user_is_premium(v_my_user_id);
  v_b_premium := public.user_is_premium(p_other_user_id);

  v_expires_at := CASE
    WHEN v_a_premium AND v_b_premium THEN now() + interval '7 days'
    ELSE now() + interval '24 hours'
  END;

  SELECT COUNT(*) + 1
    INTO v_occurrence
  FROM public.encounters
  WHERE user_a_id = v_sorted_a
    AND user_b_id = v_sorted_b;

  INSERT INTO public.encounters (
    user_a_id,
    user_b_id,
    expires_at,
    occurrence_number
  ) VALUES (
    v_sorted_a,
    v_sorted_b,
    v_expires_at,
    v_occurrence
  );
END;
$$;


-- ============================================================
-- ⑧ 運営ビュー
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


-- ============================================================
-- ⑨ 権限（service_role のみ）
-- ============================================================
REVOKE ALL ON public.premium_grants            FROM anon, authenticated;
REVOKE ALL ON public.premium_status_overview   FROM anon, authenticated;
GRANT  SELECT, INSERT, UPDATE ON public.premium_grants TO service_role;
GRANT  SELECT ON public.premium_status_overview TO service_role;

REVOKE ALL ON FUNCTION public.admin_grant_premium(UUID, TEXT, TIMESTAMPTZ, TEXT, TEXT) FROM public;
REVOKE ALL ON FUNCTION public.admin_revoke_premium(UUID, TEXT)                         FROM public;
REVOKE ALL ON FUNCTION public.admin_extend_trial(UUID, INT, TEXT)                      FROM public;
REVOKE ALL ON FUNCTION public.sync_user_premium(UUID)                                  FROM public;
REVOKE ALL ON FUNCTION public.sync_all_user_premium()                                    FROM public;

GRANT EXECUTE ON FUNCTION public.admin_grant_premium(UUID, TEXT, TIMESTAMPTZ, TEXT, TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.admin_revoke_premium(UUID, TEXT)                         TO service_role;
GRANT EXECUTE ON FUNCTION public.admin_extend_trial(UUID, INT, TEXT)                      TO service_role;
GRANT EXECUTE ON FUNCTION public.sync_user_premium(UUID)                                  TO service_role;
GRANT EXECUTE ON FUNCTION public.sync_all_user_premium()                                  TO service_role;


-- ============================================================
-- ⑩ 期限切れ付与のクリーンアップ（cron）
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

  -- トライアル期限切れユーザーの is_premium も同期
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
-- ⑪ 既存ユーザーの is_premium を同期（既存ユーザーにトライアルは付与しない）
-- ============================================================
SELECT public.sync_all_user_premium();


-- ============================================================
-- 動作確認用クエリ（手動実行 / service_role）
-- ============================================================
-- SELECT * FROM public.premium_status_overview LIMIT 20;
--
-- -- 自分を常時 Gear R に（テスト用）
-- SELECT public.admin_grant_premium(
--   '<your_user_id>'::uuid, 'gear_r', NULL, 'test', 'オーナー開発用'
-- );
--
-- -- インフルエンサーに3ヶ月無料 Gear+
-- SELECT public.admin_grant_premium(
--   '<user_id>'::uuid, 'gear_plus', NOW() + INTERVAL '90 days', 'influencer', '@handle コラボ'
-- );
--
-- -- 手動付与を解除
-- SELECT public.admin_revoke_premium('<user_id>'::uuid, 'キャンペーン終了');
--
-- -- トライアルを30日延長
-- SELECT public.admin_extend_trial('<user_id>'::uuid, 30, '再登録キャンペーン');
