-- ============================================================
-- migration_v1_22: ヤエー（すれ違い）人数の集計RPC
-- プロフィール画面に「累計ヤエー人数」「今日のヤエー人数」を表示するため、
-- 対象ユーザーの encounters から相手の人数（重複なし）を集計して返す。
--
-- encounters テーブルは本人のみ閲覧可のRLSが掛かっているため、
-- 他ユーザーのプロフィールからも件数だけを見られるよう
-- SECURITY DEFINER で集計結果（件数のみ）を返す関数として実装する。
-- 個々のすれ違い相手が誰かは返さない。
-- ============================================================

CREATE OR REPLACE FUNCTION public.get_encounter_stats(p_user_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
STABLE
AS $$
DECLARE
  v_total integer;
  v_today integer;
BEGIN
  IF p_user_id IS NULL OR NOT EXISTS (SELECT 1 FROM public.users WHERE user_id = p_user_id) THEN
    RETURN jsonb_build_object('total_people', 0, 'today_people', 0);
  END IF;

  SELECT COUNT(DISTINCT CASE WHEN user_a_id = p_user_id THEN user_b_id ELSE user_a_id END)
  INTO v_total
  FROM public.encounters
  WHERE user_a_id = p_user_id OR user_b_id = p_user_id;

  SELECT COUNT(DISTINCT CASE WHEN user_a_id = p_user_id THEN user_b_id ELSE user_a_id END)
  INTO v_today
  FROM public.encounters
  WHERE (user_a_id = p_user_id OR user_b_id = p_user_id)
    AND time >= DATE_TRUNC('day', NOW() AT TIME ZONE 'Asia/Tokyo') AT TIME ZONE 'Asia/Tokyo'
    AND time <  DATE_TRUNC('day', NOW() AT TIME ZONE 'Asia/Tokyo') AT TIME ZONE 'Asia/Tokyo' + INTERVAL '1 day';

  RETURN jsonb_build_object(
    'total_people', COALESCE(v_total, 0),
    'today_people', COALESCE(v_today, 0)
  );
END;
$$;

REVOKE ALL ON FUNCTION public.get_encounter_stats(uuid) FROM public;
GRANT EXECUTE ON FUNCTION public.get_encounter_stats(uuid) TO authenticated;
