-- ============================================================
-- Migration v1.25 : ピットインサブスクの実装 + Gear R 認証バッジ自動付与
-- Supabase SQL Editor で実行してください。前提: v1.1〜v1.24 実行済み。
-- ------------------------------------------------------------
-- 問題①: users_plan_check が 'free'/'gear_plus'/'gear_r' しか許可しておらず、
-- sync_subscription_plan RPC も 'pit_in' を渡すと例外を投げて拒否していた。
-- そのためピットイン購入者は課金は成立するが users.plan に反映されず、
-- 毎月のニトロ1個＋渋！10個も配布されていなかった（配布関数自体が存在しなかった）。
--
-- 問題②: Gear R はストア表示で「購入後すぐ認証バッジ設定可能」としているが、
-- アプリ内課金（RevenueCat）経由の sync_subscription_plan は is_verified を
-- 更新しておらず、is_verified を立てるのは admin_grant_premium と
-- Stripe Webhook（Web決済）のみだった。モバイルIAP購入者にバッジが付かない。
--
--   ① users_plan_check に 'pit_in' を追加
--   ② sync_subscription_plan に pit_in 分岐を追加 / gear_r 分岐で is_verified 付与
--   ③ grant_pit_in_monthly_items() を新設し、毎月1日に cron で実行
--
-- 何度実行しても安全（冪等）。
-- ============================================================


-- ============================================================
-- ① CHECK制約に 'pit_in' を追加
-- ============================================================
ALTER TABLE public.users DROP CONSTRAINT IF EXISTS users_plan_check;
ALTER TABLE public.users
  ADD CONSTRAINT users_plan_check
  CHECK (plan IN ('free', 'pit_in', 'gear_plus', 'gear_r'));


-- ============================================================
-- ② sync_subscription_plan を pit_in 対応 + gear_r 認証バッジ付与に更新
-- ------------------------------------------------------------
-- pit_in は premium 機能（いいね無制限等）を持たない補給プランなので
-- user_effective_plan / is_premium 判定には影響しない
-- （'gear_r' / 'gear_plus' でなければ 'free' 扱いのまま）。
-- gear_r 分岐では is_verified / gear_r_applied_at を admin_grant_premium と
-- 同様に設定する（モバイルIAP購入経路でもバッジが即時付与されるように）。
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
  IF p_plan NOT IN ('free', 'pit_in', 'gear_plus', 'gear_r') THEN
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
      AND plan IN ('pit_in', 'gear_plus', 'gear_r');
  ELSIF p_plan = 'gear_r' THEN
    UPDATE public.users
    SET
      plan = 'gear_r',
      trial_ends_at = NULL,
      gear_plus_trial_used_at = COALESCE(gear_plus_trial_used_at, NOW()),
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
      END
    WHERE user_id = p_user_id;
  ELSE
    -- pit_in: このRPCが呼ばれる時点でRevenueCat側はすでにgear_r/gear_plusが
    -- 非アクティブであることを確認済み（subscription_sync.dartが優先順位判定
    -- してから呼ぶ）。呼び出しを信頼し、他分岐と同様に無条件で反映する。
    -- （DB側の古いplan値でガードすると、Gear+解約→ピットインのみ有効になった
    --   ユーザーが永久にgear_plusのまま固まってしまうため）
    UPDATE public.users
    SET plan = 'pit_in'
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
-- ③ ピットイン月次アイテム付与
-- ------------------------------------------------------------
-- ニトロ +1 / 渋！ +10（既存所持数に加算）。plan = 'pit_in' のユーザーのみ対象
-- （gear_plus / gear_r は別関数でそれぞれのアイテムを受け取るため対象外）。
-- ============================================================
CREATE OR REPLACE FUNCTION public.grant_pit_in_monthly_items()
RETURNS TABLE(user_id UUID, nickname TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  r RECORD;
BEGIN
  FOR r IN
    SELECT u.user_id, u.nickname
    FROM public.users u
    WHERE u.plan = 'pit_in'
      AND COALESCE(u.is_suspended, FALSE) = FALSE
  LOOP
    INSERT INTO public.user_items (user_id, item_type, quantity, updated_at)
    VALUES (r.user_id, 'nitro', 1, NOW())
    ON CONFLICT (user_id, item_type)
    DO UPDATE SET
      quantity   = public.user_items.quantity + 1,
      updated_at = NOW();

    INSERT INTO public.user_items (user_id, item_type, quantity, updated_at)
    VALUES (r.user_id, 'shibu', 10, NOW())
    ON CONFLICT (user_id, item_type)
    DO UPDATE SET
      quantity   = public.user_items.quantity + 10,
      updated_at = NOW();

    user_id  := r.user_id;
    nickname := r.nickname;
    RETURN NEXT;
  END LOOP;
END;
$$;

REVOKE ALL ON FUNCTION public.grant_pit_in_monthly_items() FROM public;
GRANT EXECUTE ON FUNCTION public.grant_pit_in_monthly_items() TO service_role;


-- ============================================================
-- cron（pg_cron がある場合）… 毎月1日 10:00 JST = 01:00 UTC
-- ============================================================
DO $cron_setup$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'pg_cron') THEN
    CREATE EXTENSION IF NOT EXISTS pg_cron;

    IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'grant-pit-in-monthly-items') THEN
      PERFORM cron.unschedule('grant-pit-in-monthly-items');
    END IF;
    PERFORM cron.schedule(
      'grant-pit-in-monthly-items',
      '0 1 1 * *',
      $job$SELECT public.grant_pit_in_monthly_items()$job$
    );
  END IF;
END $cron_setup$;


-- ============================================================
-- 動作確認（手動 / service_role）
-- ============================================================
-- SELECT * FROM public.grant_pit_in_monthly_items();
