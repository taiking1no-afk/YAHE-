-- ============================================================
-- Migration v1.68 : 「気になる」を押した人が誰かは主催者のみ閲覧可能にする
-- Supabase SQL Editor で実行してください。
-- ------------------------------------------------------------
-- 背景:
--   board_participations の既存SELECTポリシーは、公開(open)募集であれば
--   status を問わず（joined/interested/pending/invited すべて）誰でも
--   閲覧できてしまっていた。参加者(joined)一覧は従来どおり公開でよいが、
--   「気になる(interested)」を押した人の身元、および参加申請中(pending)・
--   招待中(invited)の身元は、本人と主催者以外には見せない。
--
--   一方で「気になった人数」自体は誰でも見られる必要があるため、
--   RLSをすり抜けずに集計だけを返す SECURITY DEFINER 関数を用意する。
--
--   何度実行しても安全（冪等）。
-- ============================================================

DROP POLICY IF EXISTS "board_participations_select" ON public.board_participations;
CREATE POLICY "board_participations_select" ON public.board_participations FOR SELECT USING (
  user_id IN (SELECT user_id FROM public.users WHERE auth_id = auth.uid())
  OR post_id IN (
    SELECT post_id FROM public.board_posts
    WHERE organizer_id IN (SELECT user_id FROM public.users WHERE auth_id = auth.uid())
  )
  OR (
    status = 'joined'
    AND post_id IN (SELECT post_id FROM public.board_posts WHERE visibility = 'open')
  )
);

CREATE OR REPLACE FUNCTION public.get_board_interested_count(p_post_id uuid)
RETURNS integer
LANGUAGE sql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  SELECT COUNT(*)::integer FROM public.board_participations
  WHERE post_id = p_post_id AND status = 'interested';
$function$;

REVOKE ALL ON FUNCTION public.get_board_interested_count(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_board_interested_count(uuid) TO authenticated;


-- ============================================================
-- 動作確認用クエリ（手動実行）
-- ============================================================
-- SELECT polname, qual FROM pg_policies WHERE tablename = 'board_participations' AND policyname = 'board_participations_select';
-- SELECT public.get_board_interested_count('<post_id>');
