-- ============================================================
-- Migration v1.45 : グループメンバー名簿を公開範囲に修正
-- Supabase SQL Editor で実行してください。前提: v1.38（グループ）実行済み。
-- ------------------------------------------------------------
-- 問題:
--   group_memberships_select ポリシーが「自分の行」または「自分が
--   メンバーであるグループの行」しか見せない設計だったため、まだ参加
--   していないグループでは他人の status='member' 行が一切見えず、
--   グループ一覧・詳細のメンバー数が常に0人と表示される不具合があった
--   （groups自体は「誰でも一覧・検索できる」合意のため、メンバー名簿も
--   同様に公開情報として扱うのが一貫している）。
--
-- 対応:
--   status='member' の行は誰でも閲覧可能にする（名簿・人数の公開）。
--   pending/invited（参加申請・招待）は本人とグループオーナーのみ閲覧可能のまま。
--
--   何度実行しても安全（冪等）。
-- ============================================================

DROP POLICY IF EXISTS "group_memberships_select" ON public.group_memberships;
CREATE POLICY "group_memberships_select" ON public.group_memberships FOR SELECT USING (
  status = 'member'
  OR user_id IN (SELECT user_id FROM public.users WHERE auth_id = auth.uid())
  OR group_id IN (
    SELECT group_id FROM public.groups
    WHERE owner_id IN (SELECT user_id FROM public.users WHERE auth_id = auth.uid())
  )
);
