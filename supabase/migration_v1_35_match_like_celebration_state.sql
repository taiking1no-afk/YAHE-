-- ============================================================
-- Migration v1.35 : マッチ/いいね ポップアップ表示状態
-- Supabase SQL Editor で実行してください。前提: v1.34 実行済み（app_notifications）。
-- ------------------------------------------------------------
-- 目的:
--   「マッチしました！」ポップアップの重複実装を統合するにあたり、
--   どちらが先にアプリを開くか分からないため両者独立のフラグで管理する。
--   push配信やRealtimeには依存させず、タブ切替・アプリ復帰時のポーリングで
--   確実に一度だけ表示する。
--
--   何度実行しても安全（冪等）。
-- ============================================================

ALTER TABLE public.matches
  ADD COLUMN IF NOT EXISTS celebrated_by_a BOOLEAN NOT NULL DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS celebrated_by_b BOOLEAN NOT NULL DEFAULT FALSE;

ALTER TABLE public.likes
  ADD COLUMN IF NOT EXISTS seen_at TIMESTAMPTZ;

-- ============================================================
-- マッチのお祝いポップアップを既読化（呼び出し元の側だけ）
-- ============================================================
CREATE OR REPLACE FUNCTION public.mark_match_celebrated(p_match_id UUID)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_user_id UUID;
  v_a UUID;
  v_b UUID;
BEGIN
  SELECT user_id INTO v_caller_user_id FROM public.users WHERE auth_id = auth.uid();

  SELECT user_a_id, user_b_id INTO v_a, v_b
  FROM public.matches WHERE match_id = p_match_id;

  IF v_a IS NULL THEN
    RETURN;
  END IF;

  IF v_caller_user_id = v_a THEN
    UPDATE public.matches SET celebrated_by_a = TRUE WHERE match_id = p_match_id;
  ELSIF v_caller_user_id = v_b THEN
    UPDATE public.matches SET celebrated_by_b = TRUE WHERE match_id = p_match_id;
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.mark_match_celebrated(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.mark_match_celebrated(UUID) TO authenticated;

-- ============================================================
-- いいね受信ポップアップを既読化（受信者本人のみ）
-- ============================================================
CREATE OR REPLACE FUNCTION public.mark_like_seen(p_like_id UUID)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_user_id UUID;
BEGIN
  SELECT user_id INTO v_caller_user_id FROM public.users WHERE auth_id = auth.uid();

  UPDATE public.likes
  SET seen_at = NOW()
  WHERE like_id = p_like_id
    AND to_user_id = v_caller_user_id
    AND seen_at IS NULL;
END;
$$;

REVOKE ALL ON FUNCTION public.mark_like_seen(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.mark_like_seen(UUID) TO authenticated;
