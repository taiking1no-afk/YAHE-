-- ============================================================
-- Migration v1.57 : 掲示板の参加後の辞退（退会）RPC
-- Supabase SQL Editor で実行してください。前提: v1.39（掲示板）実行済み。
-- ------------------------------------------------------------
-- 目的: これまでは参加（joined）後に辞退する手段がなかった
--   （興味あり(interested)の解除はv1.54で対応済み）。
--   主催者は募集自体の削除で対応するため、このRPCの対象外とする。
--
--   何度実行しても安全（冪等）。
-- ============================================================

CREATE OR REPLACE FUNCTION public.leave_board_post(p_post_id UUID)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_id UUID;
  v_organizer_id UUID;
BEGIN
  SELECT user_id INTO v_caller_id FROM public.users WHERE auth_id = auth.uid();
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'unauthorized';
  END IF;

  SELECT organizer_id INTO v_organizer_id FROM public.board_posts WHERE post_id = p_post_id;
  IF v_organizer_id = v_caller_id THEN
    RAISE EXCEPTION 'organizer cannot leave; delete the post instead';
  END IF;

  DELETE FROM public.board_participations
  WHERE post_id = p_post_id AND user_id = v_caller_id AND status = 'joined';
END;
$$;

REVOKE ALL ON FUNCTION public.leave_board_post(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.leave_board_post(UUID) TO authenticated;
