-- ============================================================
-- Migration v1.33 : テスター向け Gear+ 自動付与（一時措置）
-- Supabase SQL Editor で実行してください。前提: v1.15 実行済み（premium_grants / admin_grant_premium）。
-- ------------------------------------------------------------
-- 目的:
--   実機テスト期間中、新規登録したユーザー全員に Gear+ を自動付与し、
--   テスターが課金操作なしですれ違い・いいね無制限等の有料機能を試せるようにする。
--
--   本番公開前に必ず無効化すること（下部「無効化」参照）。
--   有効/無効は app_config テーブルの1行で切り替えるだけで、
--   users テーブルへの直接付与ロジックはコードに残しても副作用がない設計。
--
--   何度実行しても安全（冪等）。
-- ============================================================


-- ============================================================
-- ① 設定テーブル（クライアントからは一切アクセス不可）
-- ============================================================
CREATE TABLE IF NOT EXISTS public.app_config (
  key        TEXT PRIMARY KEY,
  value      JSONB NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE public.app_config ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.app_config FROM anon, authenticated;
-- RLS 用ポリシーは意図的に作成しない（=default deny。service_role/postgres は RLS をバイパス）

INSERT INTO public.app_config (key, value)
VALUES (
  'tester_auto_grant',
  jsonb_build_object(
    'enabled', true,
    'plan', 'gear_plus',
    'expires_days', 90
  )
)
ON CONFLICT (key) DO NOTHING;


-- ============================================================
-- ② 新規登録時に自動付与（BEFORE INSERT で NEW を書き換え）
--    トリガー名は "00" で始め、trg_users_sync_premium (v1.15) より
--    先に実行されるようにする（is_premium 計算に override を反映させるため）。
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
    NEW.premium_override_plan       := COALESCE(v_cfg->>'plan', 'gear_plus');
    NEW.premium_override_expires_at := NOW() + make_interval(
      days => COALESCE((v_cfg->>'expires_days')::int, 90)
    );
    NEW.premium_override_source := 'test';
    NEW.premium_override_reason := 'tester_auto_grant';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_users_00_tester_auto_grant ON public.users;
CREATE TRIGGER trg_users_00_tester_auto_grant
  BEFORE INSERT ON public.users
  FOR EACH ROW
  EXECUTE FUNCTION public.users_tester_auto_grant_before();


-- ============================================================
-- ③ 監査ログ（premium_grants に履歴を残す。AFTER INSERT でないと
--    親行がまだ存在せず FK 違反になるため BEFORE とは分離する）
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
-- 無効化（本番公開前に必ず実行）
-- ============================================================
-- UPDATE public.app_config
-- SET value = jsonb_set(value, '{enabled}', 'false'), updated_at = NOW()
-- WHERE key = 'tester_auto_grant';
--
-- 確認:
-- SELECT value FROM public.app_config WHERE key = 'tester_auto_grant';
-- → enabled: false になっていること

-- 期限切れ分は既存の cron（v1.15 expire_premium_overrides、毎日 00:00 JST）が
-- premium_override_* のクリアと premium_grants.revoked_at の記録を自動で行う。
