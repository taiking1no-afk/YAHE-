-- ============================================================
-- Migration v1.80 : 全体バグ監査で見つかったサーバー側の修正
-- Supabase SQL Editor で実行してください。前提: v1.79実行済み。
-- ------------------------------------------------------------
-- ① express_interest_board_post に開催日チェックを追加
--    join_board_post / respond_to_board_invite / approve_board_join_request /
--    invite_to_board_post には v1.66 で「開催日を過ぎていたら拒否」する
--    チェックが入ったが、express_interest_board_post（気になる）だけ
--    このチェックが漏れており、終了したイベントにも「気になる」を押せて
--    しまっていた。
--
--   何度実行しても安全（冪等）。
-- ============================================================

CREATE OR REPLACE FUNCTION public.express_interest_board_post(p_post_id UUID)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_id UUID;
  v_scheduled_at TIMESTAMPTZ;
BEGIN
  SELECT user_id INTO v_caller_id FROM public.users WHERE auth_id = auth.uid();
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'unauthorized';
  END IF;

  SELECT scheduled_at INTO v_scheduled_at FROM public.board_posts WHERE post_id = p_post_id;
  IF v_scheduled_at IS NOT NULL AND v_scheduled_at < NOW() THEN
    RAISE EXCEPTION 'event_ended';
  END IF;

  INSERT INTO public.board_participations (post_id, user_id, status)
  VALUES (p_post_id, v_caller_id, 'interested')
  ON CONFLICT (post_id, user_id) DO UPDATE
    SET status = 'interested'
    WHERE public.board_participations.status NOT IN ('joined', 'pending');

  PERFORM public._log_board_participation_status(p_post_id, v_caller_id, 'interested');
END;
$$;

REVOKE ALL ON FUNCTION public.express_interest_board_post(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.express_interest_board_post(UUID) TO authenticated;
