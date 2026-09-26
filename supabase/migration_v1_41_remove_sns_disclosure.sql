-- ============================================================
-- Migration v1.41 : SNS開示の廃止（チャット経由への一本化）
-- Supabase SQL Editor で実行してください。前提: v1.40（チャット）実行済み
-- （チャットでSNSアカウントを送れるようになったので、マッチ済み・
-- いいね公開による自動開示の代替手段が用意された状態で無効化する）。
-- ------------------------------------------------------------
-- 目的:
--   「マッチ済みOR(鍵なし+いいね受信済み)」による自動SNS開示を廃止し、
--   本人のみ閲覧可にする。SNSを伝える行為は、チャットで自分から送る
--   （content_type='sns'）という能動的な操作に置き換える。
--
--   user_sns_links テーブル自体・sns_link_clicks は削除しない
--   （可逆性のため停止のみ。過去データはGear Rレポート等の分析用に残す）。
--
--   何度実行しても安全（冪等）。
-- ============================================================

-- 過去のマイグレーションで作られた可能性のあるポリシー名を全て念のため削除
DROP POLICY IF EXISTS "user_sns_select_v2" ON public.user_sns_links;
DROP POLICY IF EXISTS "user_sns_select_owner_or_matched" ON public.user_sns_links;
DROP POLICY IF EXISTS "user_sns_links_select" ON public.user_sns_links;
DROP POLICY IF EXISTS "user_sns_select_own_only" ON public.user_sns_links;

CREATE POLICY "user_sns_select_own_only" ON public.user_sns_links FOR SELECT USING (
  user_id IN (SELECT user_id FROM public.users WHERE auth_id = auth.uid())
);
