-- ============================================================
-- Migration v1.44 : 掲示板RLSの無限再帰を修正
-- Supabase SQL Editor で実行してください。前提: v1.39（掲示板）実行済み。
-- ------------------------------------------------------------
-- 問題:
--   board_posts_select ポリシーが board_participations をサブクエリで参照し、
--   board_participations_select ポリシーが逆に board_posts を参照していたため、
--   両ポリシーが互いのRLSを再評価し合い "infinite recursion detected in policy"
--   (42P17) となり、一覧取得が完全に失敗していた。
--
-- 対応:
--   相互参照している判定を SECURITY DEFINER 関数に切り出す。
--   関数はテーブル所有者権限で実行されRLSを再トリガーしないため、循環が切れる。
--
--   何度実行しても安全（冪等）。
-- ============================================================

CREATE OR REPLACE FUNCTION public._board_post_visibility_ok(p_post_id UUID, p_caller_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.board_posts bp
    WHERE bp.post_id = p_post_id
      AND (bp.visibility = 'open' OR bp.organizer_id = p_caller_id)
  );
$$;

REVOKE ALL ON FUNCTION public._board_post_visibility_ok(UUID, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public._board_post_visibility_ok(UUID, UUID) TO authenticated;

CREATE OR REPLACE FUNCTION public._is_board_post_participant(p_post_id UUID, p_caller_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.board_participations
    WHERE post_id = p_post_id AND user_id = p_caller_id
  );
$$;

REVOKE ALL ON FUNCTION public._is_board_post_participant(UUID, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public._is_board_post_participant(UUID, UUID) TO authenticated;

DROP POLICY IF EXISTS "board_posts_select" ON public.board_posts;
CREATE POLICY "board_posts_select" ON public.board_posts FOR SELECT USING (
  visibility = 'open'
  OR organizer_id IN (SELECT user_id FROM public.users WHERE auth_id = auth.uid())
  OR public._is_board_post_participant(
       post_id, (SELECT user_id FROM public.users WHERE auth_id = auth.uid())
     )
);

DROP POLICY IF EXISTS "board_participations_select" ON public.board_participations;
CREATE POLICY "board_participations_select" ON public.board_participations FOR SELECT USING (
  user_id IN (SELECT user_id FROM public.users WHERE auth_id = auth.uid())
  OR public._board_post_visibility_ok(
       post_id, (SELECT user_id FROM public.users WHERE auth_id = auth.uid())
     )
);
