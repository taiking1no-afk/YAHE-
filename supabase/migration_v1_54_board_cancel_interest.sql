-- ============================================================
-- Migration v1.54 : 掲示板の「気になる」解除RPC
-- Supabase SQL Editor で実行してください。前提: v1.39（掲示板）実行済み。
-- ------------------------------------------------------------
-- 目的: 一覧のハートボタンで「気になる」をON/OFFできるようにする
--   （既存のexpress_interest_board_postはONにする方向のみだった）。
--
--   何度実行しても安全（冪等）。
-- ============================================================

CREATE OR REPLACE FUNCTION public.cancel_board_interest(p_post_id UUID)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_id UUID;
BEGIN
  SELECT user_id INTO v_caller_id FROM public.users WHERE auth_id = auth.uid();
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'unauthorized';
  END IF;

  DELETE FROM public.board_participations
  WHERE post_id = p_post_id AND user_id = v_caller_id AND status = 'interested';
END;
$$;

REVOKE ALL ON FUNCTION public.cancel_board_interest(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.cancel_board_interest(UUID) TO authenticated;
