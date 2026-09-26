-- SNSリンク（user_sns_links）を、本人の任意設定で「マッチした相手にはプロフィールに
-- 表示する」ことを選べるようにする。デフォルトは非表示（オプトイン）。
-- これにより、チャットでSNSリンクを個別送信する導線は不要になる想定。

ALTER TABLE public.user_sns_links
  ADD COLUMN IF NOT EXISTS visible_to_matches boolean NOT NULL DEFAULT false;

-- マッチ済み・非ブロック・本人が表示をオンにしている場合のみ、相手のSNSリンクを閲覧可能にする。
-- 既存の「本人のみ」ポリシーには手を加えず、SELECTポリシーを追加する
-- （同一コマンドの複数ポリシーはOR条件として評価される）。
DROP POLICY IF EXISTS user_sns_select_matched_visible ON public.user_sns_links;
CREATE POLICY user_sns_select_matched_visible ON public.user_sns_links
  FOR SELECT
  USING (
    visible_to_matches = true
    AND NOT EXISTS (
      SELECT 1 FROM public.blocks b
      JOIN public.users me ON me.auth_id = auth.uid()
      WHERE (b.blocker_id = me.user_id AND b.blocked_id = user_sns_links.user_id)
         OR (b.blocker_id = user_sns_links.user_id AND b.blocked_id = me.user_id)
    )
    AND EXISTS (
      SELECT 1 FROM public.matches m
      JOIN public.users me ON me.auth_id = auth.uid()
      WHERE (m.user_a_id = user_sns_links.user_id AND m.user_b_id = me.user_id)
         OR (m.user_b_id = user_sns_links.user_id AND m.user_a_id = me.user_id)
    )
  );
