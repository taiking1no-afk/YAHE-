-- ============================================================
-- Migration v1.26 : user_locations RLS の重大な情報漏洩修正 + いいね絶対上限の撤廃
-- Supabase SQL Editor で実行してください。前提: v1.1〜v1.25 実行済み。
-- ------------------------------------------------------------
-- 問題①（重大）: user_locations の SELECT ポリシーが
--   "auth.role() = 'authenticated'" となっており、ログインさえしていれば
--   誰でも全ユーザーのリアルタイム生GPS座標を直接取得できた。
--   近傍検索は SECURITY DEFINER の nearby_user_ids() 経由でのみ行われ、
--   クライアントが user_locations を直接 SELECT する箇所はアプリ内に
--   存在しないため、このポリシーは不要かつ重大なプライバシーリスクだった。
--   → 自分の行のみ SELECT 可能に制限する。
--
-- 問題②: send_like の絶対上限(200/日)を撤廃。無料プランの1日10件制限は維持。
--
--   ① user_locations の SELECT ポリシーを自分の行のみに制限
--   ② send_like から絶対上限チェックを削除
--
-- 何度実行しても安全（冪等）。
-- ============================================================


-- ============================================================
-- ① user_locations: 自分の行のみ SELECT 可能に変更
-- ------------------------------------------------------------
-- nearby_user_ids() は SECURITY DEFINER のため RLS の影響を受けず、
-- 近傍検索は従来どおり機能する。
-- ============================================================
DROP POLICY IF EXISTS "locations_select_authenticated" ON public.user_locations;
DROP POLICY IF EXISTS "locations_select_own" ON public.user_locations;

CREATE POLICY "locations_select_own" ON public.user_locations
  FOR SELECT USING (auth.uid() = user_id);


-- ============================================================
-- ② send_like: 絶対上限(200/日)を撤廃、無料10件/日の制限のみ残す
-- ============================================================
CREATE OR REPLACE FUNCTION public.send_like(
  p_from_user_id UUID,
  p_to_user_id   UUID,
  p_encounter_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_is_matched   BOOLEAN := FALSE;
  v_match_id     UUID;
  v_like_count   INT;
  v_is_premium   BOOLEAN;
  v_is_suspended BOOLEAN;
  v_caller       UUID;
  v_user_a       UUID;
  v_user_b       UUID;
BEGIN
  SELECT user_id INTO v_caller FROM public.users WHERE auth_id = auth.uid();
  IF v_caller IS NULL OR v_caller <> p_from_user_id THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'forbidden');
  END IF;

  v_is_premium := public.user_is_premium(p_from_user_id);

  SELECT is_suspended INTO v_is_suspended
  FROM public.users WHERE user_id = p_from_user_id;

  IF COALESCE(v_is_suspended, FALSE) THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'suspended');
  END IF;

  SELECT like_count INTO v_like_count
  FROM public.today_like_counts
  WHERE from_user_id = p_from_user_id;

  IF NOT v_is_premium AND COALESCE(v_like_count, 0) >= 10 THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'daily_limit_exceeded');
  END IF;

  INSERT INTO public.likes (from_user_id, to_user_id, encounter_id)
  VALUES (p_from_user_id, p_to_user_id, p_encounter_id)
  ON CONFLICT (from_user_id, to_user_id, encounter_id) DO NOTHING;

  IF EXISTS (
    SELECT 1 FROM public.likes
    WHERE from_user_id = p_to_user_id
      AND to_user_id = p_from_user_id
      AND encounter_id = p_encounter_id
  ) THEN
    v_user_a := LEAST(p_from_user_id, p_to_user_id);
    v_user_b := GREATEST(p_from_user_id, p_to_user_id);

    INSERT INTO public.matches (user_a_id, user_b_id)
    VALUES (v_user_a, v_user_b)
    ON CONFLICT (user_a_id, user_b_id) DO NOTHING
    RETURNING match_id INTO v_match_id;

    v_is_matched := TRUE;
  END IF;

  RETURN jsonb_build_object(
    'success',    TRUE,
    'is_matched', v_is_matched,
    'match_id',   v_match_id
  );
END;
$$;
