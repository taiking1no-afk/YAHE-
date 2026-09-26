-- ============================================================
-- Migration v1.66 : 開催日を過ぎた募集への参加・申請・招待をサーバー側でも禁止
-- Supabase SQL Editor で実行してください。前提: v1.65実行済み。
-- ------------------------------------------------------------
-- 目的: クライアント側のボタン無効化だけでは直接RPCを叩けば通ってしまうため、
--   join_board_post / respond_to_board_invite / approve_board_join_request /
--   invite_to_board_post のそれぞれに「開催日（scheduled_at）を過ぎていたら
--   拒否する」チェックを追加する。既存ロジックはそのまま、チェックのみ追加。
--
--   何度実行しても安全（冪等）。
-- ============================================================

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
  v_scheduled_at TIMESTAMPTZ;
  v_joined_count INT;
  v_status TEXT;
  v_other_user_id UUID;
BEGIN
  SELECT user_id INTO v_caller_id FROM public.users WHERE auth_id = auth.uid();
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'unauthorized';
  END IF;

  SELECT organizer_id, visibility, capacity, scheduled_at
  INTO v_organizer_id, v_visibility, v_capacity, v_scheduled_at
  FROM public.board_posts WHERE post_id = p_post_id FOR UPDATE;

  IF v_organizer_id IS NULL THEN
    RAISE EXCEPTION 'post not found';
  END IF;

  IF v_scheduled_at IS NOT NULL AND v_scheduled_at < NOW() THEN
    RAISE EXCEPTION 'event_ended';
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
  v_scheduled_at TIMESTAMPTZ;
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

  SELECT capacity, scheduled_at INTO v_capacity, v_scheduled_at FROM public.board_posts WHERE post_id = v_post_id FOR UPDATE;

  IF v_scheduled_at IS NOT NULL AND v_scheduled_at < NOW() THEN
    RAISE EXCEPTION 'event_ended';
  END IF;

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
  v_scheduled_at TIMESTAMPTZ;
BEGIN
  SELECT user_id INTO v_caller_id FROM public.users WHERE auth_id = auth.uid();

  SELECT post_id, user_id INTO v_post_id, v_applicant_id FROM public.board_participations WHERE participation_id = p_participation_id;
  SELECT organizer_id, scheduled_at INTO v_organizer_id, v_scheduled_at FROM public.board_posts WHERE post_id = v_post_id;

  IF v_organizer_id IS NULL OR v_organizer_id <> v_caller_id THEN
    RAISE EXCEPTION 'only the organizer can approve requests';
  END IF;

  IF p_approve THEN
    IF v_scheduled_at IS NOT NULL AND v_scheduled_at < NOW() THEN
      RAISE EXCEPTION 'event_ended';
    END IF;

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

CREATE OR REPLACE FUNCTION public.invite_to_board_post(p_post_id uuid, p_user_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_caller_id UUID;
  v_scheduled_at TIMESTAMPTZ;
BEGIN
  SELECT user_id INTO v_caller_id FROM public.users WHERE auth_id = auth.uid();
  IF NOT EXISTS (
    SELECT 1 FROM public.board_participations
    WHERE post_id = p_post_id AND user_id = v_caller_id AND status = 'joined'
  ) THEN
    RAISE EXCEPTION 'only participants can invite';
  END IF;

  SELECT scheduled_at INTO v_scheduled_at FROM public.board_posts WHERE post_id = p_post_id;
  IF v_scheduled_at IS NOT NULL AND v_scheduled_at < NOW() THEN
    RAISE EXCEPTION 'event_ended';
  END IF;

  INSERT INTO public.board_participations (post_id, user_id, status, invited_by)
  VALUES (p_post_id, p_user_id, 'invited', v_caller_id)
  ON CONFLICT (post_id, user_id) DO UPDATE SET invited_by = v_caller_id
    WHERE public.board_participations.status NOT IN ('joined', 'pending');

  PERFORM public.create_app_notification(
    p_user_id, 'board_invite',
    jsonb_build_object('post_id', p_post_id), v_caller_id
  );
END;
$function$;
