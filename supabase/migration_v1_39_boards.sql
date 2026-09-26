-- ============================================================
-- Migration v1.39 : 掲示板（ツーリング募集・イベント/オフ会告知）
-- Supabase SQL Editor で実行してください。前提: v1.34（app_notifications）実行済み。
-- ------------------------------------------------------------
-- 目的:
--   ツーリング募集・イベント/オフ会告知の掲示板。v1.38（グループ）の
--   「参加/承認」RPCパターンを踏襲しつつ、定員・「興味あり」ステータスを追加。
--
--   何度実行しても安全（冪等）。
-- ============================================================

CREATE TABLE IF NOT EXISTS public.board_posts (
  post_id           UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  organizer_id      UUID NOT NULL REFERENCES public.users(user_id) ON DELETE CASCADE,
  post_type         TEXT NOT NULL CHECK (post_type IN ('touring', 'event')),
  title             TEXT NOT NULL,
  detail            TEXT,
  mode              TEXT CHECK (mode IN ('small_group', 'large_group')),
  meeting_place_text TEXT,
  meeting_lat       DOUBLE PRECISION,
  meeting_lng       DOUBLE PRECISION,
  route_detail      TEXT,
  scheduled_at      TIMESTAMPTZ,
  capacity          INT,
  visibility        TEXT NOT NULL CHECK (visibility IN ('open', 'invite_only', 'approval')),
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT board_posts_mode_touring_only CHECK (
    (post_type = 'touring') OR (post_type = 'event' AND mode IS NULL)
  )
);

CREATE TABLE IF NOT EXISTS public.board_participations (
  participation_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  post_id          UUID NOT NULL REFERENCES public.board_posts(post_id) ON DELETE CASCADE,
  user_id          UUID NOT NULL REFERENCES public.users(user_id) ON DELETE CASCADE,
  vehicle_id       UUID REFERENCES public.vehicles(vehicle_id) ON DELETE SET NULL,
  status           TEXT NOT NULL CHECK (status IN ('interested', 'joined', 'pending', 'invited')),
  created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  responded_at     TIMESTAMPTZ,
  CONSTRAINT board_participations_unique UNIQUE (post_id, user_id)
);

CREATE INDEX IF NOT EXISTS idx_board_participations_post ON public.board_participations(post_id);
CREATE INDEX IF NOT EXISTS idx_board_participations_user ON public.board_participations(user_id);
CREATE INDEX IF NOT EXISTS idx_board_posts_scheduled ON public.board_posts(scheduled_at);

ALTER TABLE public.board_posts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.board_participations ENABLE ROW LEVEL SECURITY;

-- 投稿の可視性: open は全認証ユーザー、invite_only/approval は主催者+参加関係者のみ
DROP POLICY IF EXISTS "board_posts_select" ON public.board_posts;
CREATE POLICY "board_posts_select" ON public.board_posts FOR SELECT USING (
  visibility = 'open'
  OR organizer_id IN (SELECT user_id FROM public.users WHERE auth_id = auth.uid())
  OR post_id IN (
    SELECT post_id FROM public.board_participations
    WHERE user_id IN (SELECT user_id FROM public.users WHERE auth_id = auth.uid())
  )
);

DROP POLICY IF EXISTS "board_posts_insert_own" ON public.board_posts;
CREATE POLICY "board_posts_insert_own" ON public.board_posts FOR INSERT WITH CHECK (
  organizer_id IN (SELECT user_id FROM public.users WHERE auth_id = auth.uid())
);
DROP POLICY IF EXISTS "board_posts_update_own" ON public.board_posts;
CREATE POLICY "board_posts_update_own" ON public.board_posts FOR UPDATE USING (
  organizer_id IN (SELECT user_id FROM public.users WHERE auth_id = auth.uid())
);
DROP POLICY IF EXISTS "board_posts_delete_own" ON public.board_posts;
CREATE POLICY "board_posts_delete_own" ON public.board_posts FOR DELETE USING (
  organizer_id IN (SELECT user_id FROM public.users WHERE auth_id = auth.uid())
);

DROP POLICY IF EXISTS "board_participations_select" ON public.board_participations;
CREATE POLICY "board_participations_select" ON public.board_participations FOR SELECT USING (
  user_id IN (SELECT user_id FROM public.users WHERE auth_id = auth.uid())
  OR post_id IN (
    SELECT post_id FROM public.board_posts
    WHERE organizer_id IN (SELECT user_id FROM public.users WHERE auth_id = auth.uid())
  )
  OR post_id IN (SELECT post_id FROM public.board_posts WHERE visibility = 'open')
);

REVOKE INSERT, UPDATE, DELETE ON public.board_participations FROM authenticated, anon;

-- ============================================================
-- RPC群
-- ============================================================

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
  p_visibility TEXT
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
    scheduled_at, capacity, visibility
  ) VALUES (
    v_caller_id, p_post_type, trim(p_title), p_detail,
    CASE WHEN p_post_type = 'touring' THEN p_mode ELSE NULL END,
    p_meeting_place_text, p_meeting_lat, p_meeting_lng, p_route_detail,
    p_scheduled_at, p_capacity, p_visibility
  ) RETURNING post_id INTO v_post_id;

  -- 主催者は自動的に「参加」扱い
  INSERT INTO public.board_participations (post_id, user_id, status)
  VALUES (v_post_id, v_caller_id, 'joined');

  RETURN v_post_id;
END;
$$;

REVOKE ALL ON FUNCTION public.create_board_post(
  TEXT, TEXT, TEXT, TEXT, TEXT, DOUBLE PRECISION, DOUBLE PRECISION, TEXT, TIMESTAMPTZ, INT, TEXT
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_board_post(
  TEXT, TEXT, TEXT, TEXT, TEXT, DOUBLE PRECISION, DOUBLE PRECISION, TEXT, TIMESTAMPTZ, INT, TEXT
) TO authenticated;

-- 参加（定員チェックあり。同一トランザクション内でカウント→判定するため競合登録を防げる）
CREATE OR REPLACE FUNCTION public.join_board_post(p_post_id UUID, p_vehicle_id UUID DEFAULT NULL)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_id UUID;
  v_organizer_id UUID;
  v_visibility TEXT;
  v_capacity   INT;
  v_joined_count INT;
  v_status TEXT;
  v_other_user_id UUID;
BEGIN
  SELECT user_id INTO v_caller_id FROM public.users WHERE auth_id = auth.uid();
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'unauthorized';
  END IF;

  -- 行ロックして定員判定の競合を防ぐ
  SELECT organizer_id, visibility, capacity INTO v_organizer_id, v_visibility, v_capacity
  FROM public.board_posts WHERE post_id = p_post_id FOR UPDATE;

  IF v_organizer_id IS NULL THEN
    RAISE EXCEPTION 'post not found';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.board_participations
    WHERE post_id = p_post_id AND user_id = v_caller_id AND status IN ('joined', 'pending')
  ) THEN
    RETURN jsonb_build_object('success', TRUE, 'status', 'already_requested');
  END IF;

  IF v_visibility = 'invite_only' THEN
    RAISE EXCEPTION 'this post is invite-only';
  END IF;

  IF v_capacity IS NOT NULL THEN
    SELECT COUNT(*) INTO v_joined_count
    FROM public.board_participations WHERE post_id = p_post_id AND status = 'joined';
    IF v_joined_count >= v_capacity THEN
      RAISE EXCEPTION 'capacity_full';
    END IF;
  END IF;

  v_status := CASE WHEN v_visibility = 'open' THEN 'joined' ELSE 'pending' END;

  INSERT INTO public.board_participations (post_id, user_id, vehicle_id, status)
  VALUES (p_post_id, v_caller_id, p_vehicle_id, v_status)
  ON CONFLICT (post_id, user_id) DO UPDATE SET status = v_status, vehicle_id = p_vehicle_id, responded_at = NULL;

  IF v_status = 'pending' THEN
    PERFORM public.create_app_notification(
      v_organizer_id, 'board_join_request',
      jsonb_build_object('post_id', p_post_id), v_caller_id
    );
  ELSIF v_status = 'joined' THEN
    -- 既に参加(joined)しているペアそれぞれについて、一緒に行った回数を+1する
    -- （Phase 8 関係レベル制度用。テーブル未作成環境でも掲示板参加自体は失敗させない）
    BEGIN
      FOR v_other_user_id IN
        SELECT user_id FROM public.board_participations
        WHERE post_id = p_post_id AND status = 'joined' AND user_id <> v_caller_id
      LOOP
        PERFORM public.increment_together_count(v_caller_id, v_other_user_id, p_post_id);
      END LOOP;
    EXCEPTION WHEN undefined_function THEN
      NULL; -- v1.42未適用の環境では何もしない
    END;
  END IF;

  RETURN jsonb_build_object('success', TRUE, 'status', v_status);
END;
$$;

REVOKE ALL ON FUNCTION public.join_board_post(UUID, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.join_board_post(UUID, UUID) TO authenticated;

-- 興味あり（定員チェックなし）
CREATE OR REPLACE FUNCTION public.express_interest_board_post(p_post_id UUID)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_id UUID;
BEGIN
  SELECT user_id INTO v_caller_id FROM public.users WHERE auth_id = auth.uid();
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'unauthorized';
  END IF;

  INSERT INTO public.board_participations (post_id, user_id, status)
  VALUES (p_post_id, v_caller_id, 'interested')
  ON CONFLICT (post_id, user_id) DO UPDATE
    SET status = 'interested'
    WHERE public.board_participations.status NOT IN ('joined', 'pending');
END;
$$;

REVOKE ALL ON FUNCTION public.express_interest_board_post(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.express_interest_board_post(UUID) TO authenticated;

CREATE OR REPLACE FUNCTION public.invite_to_board_post(p_post_id UUID, p_user_id UUID)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_id UUID;
BEGIN
  SELECT user_id INTO v_caller_id FROM public.users WHERE auth_id = auth.uid();
  IF NOT EXISTS (
    SELECT 1 FROM public.board_participations
    WHERE post_id = p_post_id AND user_id = v_caller_id AND status = 'joined'
  ) THEN
    RAISE EXCEPTION 'only participants can invite';
  END IF;

  INSERT INTO public.board_participations (post_id, user_id, status)
  VALUES (p_post_id, p_user_id, 'invited')
  ON CONFLICT (post_id, user_id) DO NOTHING;

  PERFORM public.create_app_notification(
    p_user_id, 'board_invite',
    jsonb_build_object('post_id', p_post_id), v_caller_id
  );
END;
$$;

REVOKE ALL ON FUNCTION public.invite_to_board_post(UUID, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.invite_to_board_post(UUID, UUID) TO authenticated;

CREATE OR REPLACE FUNCTION public.approve_board_join_request(p_participation_id UUID, p_approve BOOLEAN)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_id UUID;
  v_post_id   UUID;
  v_organizer_id UUID;
BEGIN
  SELECT user_id INTO v_caller_id FROM public.users WHERE auth_id = auth.uid();

  SELECT post_id INTO v_post_id FROM public.board_participations WHERE participation_id = p_participation_id;
  SELECT organizer_id INTO v_organizer_id FROM public.board_posts WHERE post_id = v_post_id;

  IF v_organizer_id IS NULL OR v_organizer_id <> v_caller_id THEN
    RAISE EXCEPTION 'only the organizer can approve requests';
  END IF;

  IF p_approve THEN
    UPDATE public.board_participations
    SET status = 'joined', responded_at = NOW()
    WHERE participation_id = p_participation_id AND status = 'pending';
  ELSE
    DELETE FROM public.board_participations
    WHERE participation_id = p_participation_id AND status = 'pending';
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.approve_board_join_request(UUID, BOOLEAN) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.approve_board_join_request(UUID, BOOLEAN) TO authenticated;

-- 「マッチしている人が参加しているか」をサーバー側で解決する
-- （クライアントに他人のmatches行を晒さないため）
CREATE OR REPLACE FUNCTION public.get_board_attending_matches(p_post_id UUID)
RETURNS TABLE(user_id UUID)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_id UUID;
BEGIN
  SELECT u.user_id INTO v_caller_id FROM public.users u WHERE u.auth_id = auth.uid();
  IF v_caller_id IS NULL THEN
    RETURN;
  END IF;

  RETURN QUERY
  SELECT bp.user_id
  FROM public.board_participations bp
  WHERE bp.post_id = p_post_id
    AND bp.status = 'joined'
    AND EXISTS (
      SELECT 1 FROM public.matches m
      WHERE (m.user_a_id = v_caller_id AND m.user_b_id = bp.user_id)
         OR (m.user_b_id = v_caller_id AND m.user_a_id = bp.user_id)
    );
END;
$$;

REVOKE ALL ON FUNCTION public.get_board_attending_matches(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_board_attending_matches(UUID) TO authenticated;
