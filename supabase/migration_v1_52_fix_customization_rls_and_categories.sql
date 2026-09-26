-- ============================================================
-- Migration v1.52 : カスタムパーツのRLS復旧 + カテゴリ変更（ECU→その他）
-- Supabase SQL Editor で実行してください。前提: v1.36（カスタムパーツ）実行済み。
-- ------------------------------------------------------------
-- 問題:
--   vehicle_customization_parts は RLS が有効化されているのに
--   ポリシーが1件も存在せず（本番で作成文が実行されていなかった）、
--   authenticated ロールからの読み書きがすべて拒否されていた。
--   これが「カスタム詳細を入力しても反映されない」不具合の直接の原因。
--
-- 対応:
--   ① v1.36で定義していたポリシーを復旧する。
--   ② カテゴリから 'ecu' を廃止し 'other'（その他）を追加する。
--      既存の 'ecu' 行は 'other' に変換してから制約を張り替える。
--
--   何度実行しても安全（冪等）。
-- ============================================================

-- ① RLSポリシー復旧
DROP POLICY IF EXISTS "vehicle_customization_parts_all_own" ON public.vehicle_customization_parts;
CREATE POLICY "vehicle_customization_parts_all_own" ON public.vehicle_customization_parts
  FOR ALL USING (
    vehicle_id IN (
      SELECT vehicle_id FROM public.vehicles
      WHERE user_id IN (SELECT user_id FROM public.users WHERE auth_id = auth.uid())
    )
  );

DROP POLICY IF EXISTS "vehicle_customization_parts_select_others" ON public.vehicle_customization_parts;
CREATE POLICY "vehicle_customization_parts_select_others" ON public.vehicle_customization_parts
  FOR SELECT USING (
    vehicle_id IN (SELECT vehicle_id FROM public.vehicles WHERE is_active = TRUE)
  );

-- ② カテゴリ変更: ecu → other
UPDATE public.vehicle_customization_parts SET category = 'other' WHERE category = 'ecu';

ALTER TABLE public.vehicle_customization_parts DROP CONSTRAINT IF EXISTS vehicle_customization_parts_category_check;
ALTER TABLE public.vehicle_customization_parts ADD CONSTRAINT vehicle_customization_parts_category_check
  CHECK (category IN ('suspension', 'wheel', 'exhaust', 'aero', 'other', 'tire'));
