-- ============================================================
-- Migration v1.77 : マッチ後プロフィールに参加予定イベント表示 + 公開SNSリンクをマッチ後限定に
-- Supabase SQL Editor で実行してください。前提: v1.75, v1.76 実行済み。
-- ------------------------------------------------------------
-- ① public_sns_links: 「マッチ前でも公開されてしまう」不具合を修正。
--    Gear R限定の公開SNSリンクは、これまで user_effective_plan='gear_r'
--    でさえあれば誰からでも見えていた（ブロックのみ除外）。
--    「マッチ後常にプロフィールに公開される」仕様に変更し、本人以外は
--    マッチ済みの相手のみ閲覧可能にする。
--
-- ② board_participations_select: マッチ後プロフィールに「参加予定の
--    イベント」を表示するため、承認制(approval)募集の参加者(joined)も
--    公開制(open)と同様に閲覧可能にする（招待制(invite_only)は対象外のまま）。
--
--   何度実行しても安全（冪等）。
-- ============================================================

DROP POLICY IF EXISTS "public_sns_links_select" ON public.public_sns_links;
CREATE POLICY "public_sns_links_select" ON public.public_sns_links FOR SELECT USING (
  -- 本人は常に自分の設定を確認できる
  user_id IN (SELECT user_id FROM public.users WHERE auth_id = auth.uid())
  OR (
    public.user_effective_plan(public_sns_links.user_id) = 'gear_r'
    AND NOT EXISTS (
      SELECT 1 FROM public.blocks b
      JOIN public.users me ON me.auth_id = auth.uid()
      WHERE b.blocker_id = me.user_id AND b.blocked_id = public_sns_links.user_id
    )
    -- マッチ済みの相手にのみ公開する
    AND EXISTS (
      SELECT 1 FROM public.matches m
      JOIN public.users me ON me.auth_id = auth.uid()
      WHERE (m.user_a_id = public_sns_links.user_id AND m.user_b_id = me.user_id)
         OR (m.user_b_id = public_sns_links.user_id AND m.user_a_id = me.user_id)
    )
  )
);

DROP POLICY IF EXISTS "board_participations_select" ON public.board_participations;
CREATE POLICY "board_participations_select" ON public.board_participations FOR SELECT USING (
  user_id IN (SELECT user_id FROM public.users WHERE auth_id = auth.uid())
  OR post_id IN (
    SELECT post_id FROM public.board_posts
    WHERE organizer_id IN (SELECT user_id FROM public.users WHERE auth_id = auth.uid())
  )
  OR (
    status = 'joined'
    AND post_id IN (
      SELECT post_id FROM public.board_posts WHERE visibility IN ('open', 'approval')
    )
  )
);


-- ============================================================
-- 動作確認用クエリ（手動実行）
-- ============================================================
-- SELECT qual ILIKE '%matches%' AS public_sns_requires_match FROM pg_policies WHERE tablename='public_sns_links' AND policyname='public_sns_links_select';
-- SELECT qual ILIKE '%approval%' AS board_participations_includes_approval FROM pg_policies WHERE tablename='board_participations' AND policyname='board_participations_select';
