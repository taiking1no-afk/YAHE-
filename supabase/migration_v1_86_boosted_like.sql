-- ============================================================
-- Migration v1.86 : 渋！/激渋！を特定の相手に送る「ブースト付きいいね」
-- Supabase SQL Editor で実行してください。前提: v1.27（渋！/激渋！基盤）まで適用済み。
-- ------------------------------------------------------------
-- 目的:
--   既存の「渋！/激渋！」は消費すると24時間、自分が送った"すべての"いいねが
--   相手側リストで上位表示される仕様（user_items.active_until による一括ブースト）。
--   これとは別に、特定の相手への「いいね」だけを目立たせて送れるようにする
--   （いいねボタンの隣に置く「渋ボタン」用）。両方併用可能。
--
--   何度実行しても安全（冪等）。
-- ============================================================

ALTER TABLE public.likes
  ADD COLUMN IF NOT EXISTS boost_type TEXT CHECK (boost_type IN ('shibu', 'geki_shibu'));

-- ============================================================
-- send_boosted_like: 渋！/激渋！を1個消費し、特定の相手へのいいねを
-- ブースト付きで送る。いいね自体の検証（ブロック・日次上限・マッチ判定・
-- 通知）は既存の send_like にそのまま委譲し、ロジックを重複させない。
-- 激渋！を優先して消費する（両方所持している場合）。
-- ============================================================
CREATE OR REPLACE FUNCTION public.send_boosted_like(
  p_from_user_id UUID,
  p_to_user_id UUID,
  p_encounter_id UUID
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

  -- 激渋！を優先。行ロックしてから残数判定することで、連打による二重消費を防ぐ。
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

  v_result := public.send_like(p_from_user_id, p_to_user_id, p_encounter_id);

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

REVOKE ALL ON FUNCTION public.send_boosted_like(UUID, UUID, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.send_boosted_like(UUID, UUID, UUID) TO authenticated;
