-- ============================================================
-- Migration v1.70 : 掲示板投稿の作成と同時に参加者チャットを自動作成
-- Supabase SQL Editor で実行してください。前提: v1.65, v1.68 実行済み。
-- ------------------------------------------------------------
-- 従来は主催者が募集詳細画面で「参加者チャットを作成」を押すまで
-- チャットが存在しなかった。募集作成と同じタイミングで自動的に
-- 作成し、参加者がすぐにコンタクトできるようにする。
--
-- 開催日(scheduled_at)未設定の投稿でも呼べるよう、
-- create_board_post_chat() 側のフォールバック期限も合わせて追加する
-- （未設定のまま無期限にすると、投稿自体もscheduled_atがNULLの間は
-- 自動削除(migration_v1_67)の対象外で永久に残り続けてしまうため）。
--
-- 何度実行しても安全（冪等）。
-- ============================================================

CREATE OR REPLACE FUNCTION public.create_board_post_chat(p_post_id UUID)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_id     UUID;
  v_organizer_id  UUID;
  v_title         TEXT;
  v_scheduled_at  TIMESTAMPTZ;
  v_existing      UUID;
  v_new_group_id  UUID;
BEGIN
  SELECT user_id INTO v_caller_id FROM public.users WHERE auth_id = auth.uid();
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'unauthorized';
  END IF;

  SELECT organizer_id, title, scheduled_at, chat_group_id
  INTO v_organizer_id, v_title, v_scheduled_at, v_existing
  FROM public.board_posts WHERE post_id = p_post_id FOR UPDATE;

  IF v_organizer_id IS NULL THEN
    RAISE EXCEPTION 'post not found';
  END IF;
  IF v_organizer_id <> v_caller_id THEN
    RAISE EXCEPTION 'only the organizer can start the chat';
  END IF;
  IF v_existing IS NOT NULL THEN
    RETURN v_existing;
  END IF;

  INSERT INTO public.groups (owner_id, name, description, join_mode, expires_at)
  VALUES (
    v_caller_id,
    v_title,
    '参加者限定の期間限定チャットです。',
    'invite_only',
    -- 開催日未設定の投稿は「開催日の翌日」を計算できないため、
    -- 作成から90日後をフォールバック期限にする（無期限放置を防ぐ）
    CASE WHEN v_scheduled_at IS NOT NULL THEN v_scheduled_at + INTERVAL '1 day' ELSE NOW() + INTERVAL '90 days' END
  )
  RETURNING group_id INTO v_new_group_id;

  INSERT INTO public.group_memberships (group_id, user_id, status, role)
  SELECT v_new_group_id, bp.user_id, 'member', CASE WHEN bp.user_id = v_caller_id THEN 'owner' ELSE 'member' END
  FROM public.board_participations bp
  WHERE bp.post_id = p_post_id AND bp.status = 'joined';

  -- 主催者が参加者(joined)としてまだ登録されていない場合の保険
  INSERT INTO public.group_memberships (group_id, user_id, status, role)
  VALUES (v_new_group_id, v_caller_id, 'member', 'owner')
  ON CONFLICT (group_id, user_id) DO NOTHING;

  UPDATE public.board_posts SET chat_group_id = v_new_group_id WHERE post_id = p_post_id;

  RETURN v_new_group_id;
END;
$$;

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

  -- 参加者チャットを投稿作成と同時に自動作成する（主催者が手動作成しなくても
  -- 参加者同士がすぐにコンタクトできるようにする）
  PERFORM public.create_board_post_chat(v_post_id);

  RETURN v_post_id;
END;
$$;


-- ============================================================
-- 動作確認用クエリ（手動実行）
-- ============================================================
-- SELECT prosrc ILIKE '%create_board_post_chat%' AS auto_creates_chat FROM pg_proc WHERE proname = 'create_board_post';
-- SELECT prosrc ILIKE '%90 days%' AS has_fallback_expiry FROM pg_proc WHERE proname = 'create_board_post_chat';
