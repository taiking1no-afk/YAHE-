-- ============================================================
-- Migration v1.64 : 累計/今日のヤエー数を「重複を含む回数」でカウント
-- Supabase SQL Editor で実行してください。
-- ------------------------------------------------------------
-- 目的: これまでget_encounter_statsはCOUNT(DISTINCT 相手)で
--   「すれ違った人数（ユニーク）」を返していたため、同じ人と複数回
--   すれ違っても1人としてしかカウントされなかった。
--   「累計ヤエー」は回数として見せたいため、COUNT(*)に変更する
--   （実際のすれ違い記録自体はクライアント側の重複防止ウィンドウで
--   間隔を空けて1行ずつ作られる想定なので、行数=回数として数えてよい）。
--
--   何度実行しても安全（冪等）。
-- ============================================================

CREATE OR REPLACE FUNCTION public.get_encounter_stats(p_user_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_total integer;
  v_today integer;
BEGIN
  IF p_user_id IS NULL OR NOT EXISTS (SELECT 1 FROM public.users WHERE user_id = p_user_id) THEN
    RETURN jsonb_build_object('total_people', 0, 'today_people', 0);
  END IF;

  SELECT COUNT(*)
  INTO v_total
  FROM public.encounters
  WHERE user_a_id = p_user_id OR user_b_id = p_user_id;

  SELECT COUNT(*)
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
$function$;
