-- ============================================================
-- Migration v1.87 : イベント/グループ経由（すれ違い無し）のプロフィールでも
-- 渋！/激渋！を送れるようにする
-- Supabase SQL Editor で実行してください。前提: v1.86（send_boosted_like）まで適用済み。
-- ------------------------------------------------------------
-- 目的:
--   send_boosted_like は encounter_id が必須（すれ違い経由のみ）だったため、
--   グループ/掲示板で出会った未マッチユーザーのプロフィール（すれ違い無し、
--   send_like_no_encounter 経由）からは渋！/激渋！を送れなかった。
--   既存の send_boosted_like と同じロジックを、send_like_no_encounter版として用意する。
--
--   何度実行しても安全（冪等）。
-- ============================================================

CREATE OR REPLACE FUNCTION public.send_boosted_like_no_encounter(
  p_from_user_id UUID,
  p_to_user_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_id UUID;
  v_item_type TEXT;
  v_qty        INT;
  v_result     JSONB;
BEGIN
  SELECT user_id INTO v_caller_id FROM public.users WHERE auth_id = auth.uid();
  IF v_caller_id IS NULL OR v_caller_id <> p_from_user_id THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'forbidden');
  END IF;

  SELECT quantity INTO v_qty FROM public.user_items
    WHERE user_id = v_caller_id AND item_type = 'geki_shibu' FOR UPDATE;
  IF COALESCE(v_qty, 0) > 0 THEN
    v_item_type := 'geki_shibu';
  ELSE
    SELECT quantity INTO v_qty FROM public.user_items
      WHERE user_id = v_caller_id AND item_type = 'shibu' FOR UPDATE;
    IF COALESCE(v_qty, 0) > 0 THEN
      v_item_type := 'shibu';
    ELSE
      RETURN jsonb_build_object('success', FALSE, 'error', 'no_boost_item');
    END IF;
  END IF;

  v_result := public.send_like_no_encounter(p_from_user_id, p_to_user_id);

  IF COALESCE((v_result->>'success')::boolean, FALSE) THEN
    UPDATE public.user_items
      SET quantity = quantity - 1
      WHERE user_id = v_caller_id AND item_type = v_item_type;

    UPDATE public.likes
      SET boost_type = v_item_type
      WHERE from_user_id = p_from_user_id AND to_user_id = p_to_user_id;
  END IF;

  RETURN v_result || jsonb_build_object('boost_type', v_item_type);
END;
$$;

REVOKE ALL ON FUNCTION public.send_boosted_like_no_encounter(UUID, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.send_boosted_like_no_encounter(UUID, UUID) TO authenticated;
