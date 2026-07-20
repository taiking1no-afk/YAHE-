-- ============================================================
-- Migration v1.23 : いいね取り消し
-- Supabase SQL Editor で実行してください。前提: v1.1〜v1.22 実行済み。
-- ------------------------------------------------------------
-- 送信したいいねを取り消せるように、自分が送ったいいね行の DELETE を許可する。
-- （マッチ成立後は matches テーブルが別に永続化されるため、いいね行を
--   消してもマッチ・開示済みのSNS情報には影響しない）
-- 何度実行しても安全（冪等）。
-- ============================================================

DROP POLICY IF EXISTS "likes_delete_own" ON public.likes;

CREATE POLICY "likes_delete_own" ON public.likes FOR DELETE USING (
  from_user_id IN (SELECT user_id FROM public.users WHERE auth_id = auth.uid())
);
