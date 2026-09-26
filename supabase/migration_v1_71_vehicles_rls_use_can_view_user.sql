-- ============================================================
-- Migration v1.71 : vehicles の閲覧可否を can_view_user() に統一する
-- Supabase SQL Editor で実行してください。
-- ------------------------------------------------------------
-- 問題:
--   vehicles_select_related ポリシーは v1.9 時点の独自ロジック
--   （自分の車両 or すれ違い済み or マッチ済み）のままで、以降
--   can_view_user() に追加されたグループ共通所属・募集共通参加の
--   例外や、ブロック関係の除外が一切反映されていなかった。
--   結果として「すれ違ったことはないがグループ/イベントで一緒の相手」
--   のプロフィールを開くと、users行は見えるのに vehicles だけRLSで
--   空配列になり、車両情報・車両写真が表示されない状態になっていた。
--
-- 対応: 独自ロジックをやめ、can_view_user() に統一する
--   （usersテーブルの閲覧可否と常に同期する。ブロック時は自動的に除外され、
--   グループ/募集共通参加の例外も自動的に効くようになる）。
--
--   何度実行しても安全（冪等）。
-- ============================================================

DROP POLICY IF EXISTS "vehicles_select_related" ON public.vehicles;
CREATE POLICY "vehicles_select_related" ON public.vehicles
FOR SELECT USING (
  user_id IN (SELECT user_id FROM public.users WHERE auth_id = auth.uid())
  OR public.can_view_user(vehicles.user_id)
);


-- ============================================================
-- 動作確認用クエリ（手動実行）
-- ============================================================
-- SELECT qual ILIKE '%can_view_user%' AS uses_can_view_user FROM pg_policies WHERE tablename = 'vehicles' AND policyname = 'vehicles_select_related';
