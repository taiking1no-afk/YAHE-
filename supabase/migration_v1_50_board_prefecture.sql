-- ============================================================
-- Migration v1.50 : 掲示板に開催地域（都道府県）を追加
-- Supabase SQL Editor で実行してください。前提: v1.39（掲示板）実行済み。
-- ------------------------------------------------------------
-- 目的:
--   ユーザーの居住エリア（users.area、自由記入）に近い開催地域の募集を
--   「あなたの地域のおすすめ」として掲示板・カレンダーで優先表示できるようにする。
--   都道府県は自由記入のusers.areaと同じ運用に合わせ、厳密な47都道府県の
--   コード化はせず自由記入のまま（前方一致・部分一致でクライアント側が突き合わせる）。
--
--   何度実行しても安全（冪等）。
-- ============================================================

ALTER TABLE public.board_posts ADD COLUMN IF NOT EXISTS prefecture TEXT;

DROP FUNCTION IF EXISTS public.create_board_post(TEXT, TEXT, TEXT, TEXT, TEXT, DOUBLE PRECISION, DOUBLE PRECISION, TEXT, TIMESTAMPTZ, INT, TEXT);

CREATE OR REPLACE FUNCTION public.create_board_post(
  p_post_type TEXT,
  p_title TEXT,
  p_detail TEXT,
  p_mode TEXT,
  p_meeting_place_text TEXT,
  p_meeting_lat DOUBLE PRECISION,
  p_meeting_lng DOUBLE PRECISION,
  p_route_detail TEXT,
  p_scheduled_at TIMESTAMPTZ,
  p_capacity INT,
  p_visibility TEXT,
  p_prefecture TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_id UUID;
  v_post_id   UUID;
BEGIN
  SELECT user_id INTO v_caller_id FROM public.users WHERE auth_id = auth.uid();
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'unauthorized';
  END IF;
  IF p_post_type NOT IN ('touring', 'event') THEN
    RAISE EXCEPTION 'invalid post_type';
  END IF;
  IF p_visibility NOT IN ('open', 'invite_only', 'approval') THEN
    RAISE EXCEPTION 'invalid visibility';
  END IF;
  IF p_title IS NULL OR trim(p_title) = '' THEN
    RAISE EXCEPTION 'title required';
  END IF;

  INSERT INTO public.board_posts (
    organizer_id, post_type, title, detail, mode,
    meeting_place_text, meeting_lat, meeting_lng, route_detail,
    scheduled_at, capacity, visibility, prefecture
  ) VALUES (
    v_caller_id, p_post_type, trim(p_title), p_detail,
    CASE WHEN p_post_type = 'touring' THEN p_mode ELSE NULL END,
    p_meeting_place_text, p_meeting_lat, p_meeting_lng, p_route_detail,
    p_scheduled_at, p_capacity, p_visibility, p_prefecture
  ) RETURNING post_id INTO v_post_id;

  -- 主催者は自動的に「参加」扱い
  INSERT INTO public.board_participations (post_id, user_id, status)
  VALUES (v_post_id, v_caller_id, 'joined');

  RETURN v_post_id;
END;
$$;

REVOKE ALL ON FUNCTION public.create_board_post(
  TEXT, TEXT, TEXT, TEXT, TEXT, DOUBLE PRECISION, DOUBLE PRECISION, TEXT, TIMESTAMPTZ, INT, TEXT, TEXT
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_board_post(
  TEXT, TEXT, TEXT, TEXT, TEXT, DOUBLE PRECISION, DOUBLE PRECISION, TEXT, TIMESTAMPTZ, INT, TEXT, TEXT
) TO authenticated;
