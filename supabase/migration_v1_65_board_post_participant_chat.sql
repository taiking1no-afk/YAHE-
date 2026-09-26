-- ============================================================
-- Migration v1.65 : ツーリング・イベント参加者限定の期間限定グループチャット
-- Supabase SQL Editor で実行してください。前提: v1.38/v1.39/v1.46/v1.58実行済み。
-- ------------------------------------------------------------
-- 目的:
--   募集(ツーリング・イベント)の主催者が、参加者だけが入れる期間限定
--   （開催日の翌日まで）のグループチャットを作成できるようにする。
--   既存のグループチャット機能をそのまま流用する（groups/group_messages）。
--
--   何度実行しても安全（冪等）。
-- ============================================================

-- ① 期限（groups側）・紐づく募集（board_posts側）の列を追加
ALTER TABLE public.groups ADD COLUMN IF NOT EXISTS expires_at TIMESTAMPTZ;
ALTER TABLE public.board_posts ADD COLUMN IF NOT EXISTS chat_group_id UUID REFERENCES public.groups(group_id) ON DELETE SET NULL;

-- ② 参加確定時に、その募集に紐づくチャットグループへ自動的にメンバー追加する共通処理
CREATE OR REPLACE FUNCTION public._join_board_post_chat_if_exists(p_post_id UUID, p_user_id UUID)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_chat_group_id UUID;
BEGIN
  SELECT chat_group_id INTO v_chat_group_id FROM public.board_posts WHERE post_id = p_post_id;
  IF v_chat_group_id IS NULL THEN
    RETURN;
  END IF;

  INSERT INTO public.group_memberships (group_id, user_id, status, role)
  VALUES (v_chat_group_id, p_user_id, 'member', 'member')
  ON CONFLICT (group_id, user_id) DO UPDATE
    SET status = 'member'
    WHERE public.group_memberships.status <> 'member';
END;
$$;

-- ③ 募集の参加者限定チャットを作成（主催者のみ）
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
    CASE WHEN v_scheduled_at IS NOT NULL THEN v_scheduled_at + INTERVAL '1 day' ELSE NULL END
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

REVOKE ALL ON FUNCTION public.create_board_post_chat(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_board_post_chat(UUID) TO authenticated;
REVOKE ALL ON FUNCTION public._join_board_post_chat_if_exists(UUID, UUID) FROM PUBLIC;

-- ④ join_board_post / respond_to_board_invite / approve_board_join_request：
--    参加確定(joined)のタイミングでチャットグループへの自動参加フックを追加
--    （元のロジックはそのまま、フック呼び出しのみ追加）
CREATE OR REPLACE FUNCTION public.join_board_post(p_post_id uuid, p_vehicle_id uuid DEFAULT NULL::uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
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
    PERFORM public._join_board_post_chat_if_exists(p_post_id, v_caller_id);
    BEGIN
      FOR v_other_user_id IN
        SELECT user_id FROM public.board_participations
        WHERE post_id = p_post_id AND status = 'joined' AND user_id <> v_caller_id
      LOOP
        PERFORM public.increment_together_count(v_caller_id, v_other_user_id, p_post_id);
      END LOOP;
    EXCEPTION WHEN undefined_function THEN
      NULL;
    END;
  END IF;

  RETURN jsonb_build_object('success', TRUE, 'status', v_status);
END;
$function$;

CREATE OR REPLACE FUNCTION public.respond_to_board_invite(p_participation_id uuid, p_accept boolean)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_caller_id    UUID;
  v_post_id      UUID;
  v_inviter      UUID;
  v_capacity     INT;
  v_joined_count INT;
  v_other_user_id UUID;
BEGIN
  SELECT user_id INTO v_caller_id FROM public.users WHERE auth_id = auth.uid();

  SELECT post_id, invited_by INTO v_post_id, v_inviter
  FROM public.board_participations
  WHERE participation_id = p_participation_id AND user_id = v_caller_id AND status = 'invited';

  IF v_post_id IS NULL THEN
    RAISE EXCEPTION 'invite not found';
  END IF;

  IF NOT p_accept THEN
    DELETE FROM public.board_participations
    WHERE participation_id = p_participation_id AND user_id = v_caller_id AND status = 'invited';

    IF v_inviter IS NOT NULL THEN
      PERFORM public.create_app_notification(
        v_inviter, 'board_invite_declined',
        jsonb_build_object('post_id', v_post_id), v_caller_id
      );
    END IF;

    RETURN jsonb_build_object('success', TRUE, 'status', 'declined');
  END IF;

  SELECT capacity INTO v_capacity FROM public.board_posts WHERE post_id = v_post_id FOR UPDATE;
  IF v_capacity IS NOT NULL THEN
    SELECT COUNT(*) INTO v_joined_count
    FROM public.board_participations WHERE post_id = v_post_id AND status = 'joined';
    IF v_joined_count >= v_capacity THEN
      RAISE EXCEPTION 'capacity_full';
    END IF;
  END IF;

  UPDATE public.board_participations
  SET status = 'joined', responded_at = NOW()
  WHERE participation_id = p_participation_id AND user_id = v_caller_id AND status = 'invited';

  PERFORM public._join_board_post_chat_if_exists(v_post_id, v_caller_id);

  BEGIN
    FOR v_other_user_id IN
      SELECT user_id FROM public.board_participations
      WHERE post_id = v_post_id AND status = 'joined' AND user_id <> v_caller_id
    LOOP
      PERFORM public.increment_together_count(v_caller_id, v_other_user_id, v_post_id);
    END LOOP;
  EXCEPTION WHEN undefined_function THEN
    NULL;
  END;

  RETURN jsonb_build_object('success', TRUE, 'status', 'joined');
END;
$function$;

CREATE OR REPLACE FUNCTION public.approve_board_join_request(p_participation_id uuid, p_approve boolean)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_caller_id UUID;
  v_post_id   UUID;
  v_organizer_id UUID;
  v_applicant_id UUID;
BEGIN
  SELECT user_id INTO v_caller_id FROM public.users WHERE auth_id = auth.uid();

  SELECT post_id, user_id INTO v_post_id, v_applicant_id FROM public.board_participations WHERE participation_id = p_participation_id;
  SELECT organizer_id INTO v_organizer_id FROM public.board_posts WHERE post_id = v_post_id;

  IF v_organizer_id IS NULL OR v_organizer_id <> v_caller_id THEN
    RAISE EXCEPTION 'only the organizer can approve requests';
  END IF;

  IF p_approve THEN
    UPDATE public.board_participations
    SET status = 'joined', responded_at = NOW()
    WHERE participation_id = p_participation_id AND status = 'pending';

    PERFORM public._join_board_post_chat_if_exists(v_post_id, v_applicant_id);
  ELSE
    DELETE FROM public.board_participations
    WHERE participation_id = p_participation_id AND status = 'pending';
  END IF;
END;
$function$;

-- ⑤ leave_board_post：脱退時にチャットグループのメンバーからも外す
CREATE OR REPLACE FUNCTION public.leave_board_post(p_post_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_caller_id UUID;
  v_organizer_id UUID;
  v_chat_group_id UUID;
BEGIN
  SELECT user_id INTO v_caller_id FROM public.users WHERE auth_id = auth.uid();
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'unauthorized';
  END IF;

  SELECT organizer_id, chat_group_id INTO v_organizer_id, v_chat_group_id FROM public.board_posts WHERE post_id = p_post_id;
  IF v_organizer_id = v_caller_id THEN
    RAISE EXCEPTION 'organizer cannot leave; delete the post instead';
  END IF;

  DELETE FROM public.board_participations
  WHERE post_id = p_post_id AND user_id = v_caller_id AND status = 'joined';

  IF v_chat_group_id IS NOT NULL THEN
    DELETE FROM public.group_memberships
    WHERE group_id = v_chat_group_id AND user_id = v_caller_id AND role <> 'owner';
  END IF;
END;
$function$;

-- ⑥ send_group_message：期限切れのグループには新規メッセージを送れないようにする
CREATE OR REPLACE FUNCTION public.send_group_message(
  p_group_id uuid,
  p_content_type text,
  p_body text DEFAULT NULL::text,
  p_photo_path text DEFAULT NULL::text,
  p_related_post_id uuid DEFAULT NULL::uuid
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_caller_id UUID;
  v_message_id UUID;
  v_word RECORD;
  v_text TEXT;
  v_expires_at TIMESTAMPTZ;
BEGIN
  SELECT user_id INTO v_caller_id FROM public.users WHERE auth_id = auth.uid();
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'unauthorized';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.group_memberships
    WHERE group_id = p_group_id AND user_id = v_caller_id AND status = 'member'
  ) THEN
    RAISE EXCEPTION 'not a member';
  END IF;

  SELECT expires_at INTO v_expires_at FROM public.groups WHERE group_id = p_group_id;
  IF v_expires_at IS NOT NULL AND v_expires_at < NOW() THEN
    RAISE EXCEPTION 'chat_expired';
  END IF;

  IF p_content_type NOT IN ('text', 'photo', 'quick_reply', 'board_invite') THEN
    RAISE EXCEPTION 'invalid content_type';
  END IF;
  IF p_content_type = 'board_invite' AND p_related_post_id IS NULL THEN
    RAISE EXCEPTION 'related_post_id required for board_invite';
  END IF;
  IF p_content_type = 'photo' AND p_photo_path IS NULL THEN
    RAISE EXCEPTION 'photo_path required for photo';
  END IF;
  IF p_content_type <> 'photo' AND (p_body IS NULL OR trim(p_body) = '') THEN
    RAISE EXCEPTION 'body required';
  END IF;

  IF p_body IS NOT NULL AND p_body <> '' THEN
    v_text := lower(p_body);
    FOR v_word IN SELECT word FROM public.ng_words LOOP
      IF position(lower(v_word.word) IN v_text) > 0 THEN
        RAISE EXCEPTION 'ng_word_detected';
      END IF;
    END LOOP;
  END IF;

  INSERT INTO public.group_messages (group_id, sender_id, content_type, body, photo_path, related_post_id)
  VALUES (p_group_id, v_caller_id, p_content_type, NULLIF(trim(coalesce(p_body, '')), ''), p_photo_path, p_related_post_id)
  RETURNING message_id INTO v_message_id;

  RETURN v_message_id;
END;
$function$;
