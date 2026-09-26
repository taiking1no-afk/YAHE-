-- ============================================================
-- Migration v1.53 : 掲示板の許可制可視性修正 + 招待辞退の通知
-- Supabase SQL Editor で実行してください。前提: v1.38, v1.39, v1.44 実行済み。
-- ------------------------------------------------------------
-- 目的:
--   ① 許可制（approval）の募集が誰でも一覧で見えるようにする
--      （参加には引き続き主催者の承認が必要。招待制のみ非公開のまま）。
--   ② グループ・掲示板の「招待」に招待者を記録し、招待された側が辞退した際に
--      招待者へ通知できるようにする。
--   ③ 掲示板の招待に対する承諾/辞退RPCを新設する
--      （現状 join_board_post は招待制だと即エラーになり、招待の承諾手段がなかった）。
--
--   何度実行しても安全（冪等）。
-- ============================================================

-- ① 許可制の可視性修正
CREATE OR REPLACE FUNCTION public._board_post_visibility_ok(p_post_id UUID, p_caller_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.board_posts bp
    WHERE bp.post_id = p_post_id
      AND (bp.visibility IN ('open', 'approval') OR bp.organizer_id = p_caller_id)
  );
$$;

DROP POLICY IF EXISTS "board_posts_select" ON public.board_posts;
CREATE POLICY "board_posts_select" ON public.board_posts FOR SELECT USING (
  visibility IN ('open', 'approval')
  OR organizer_id IN (SELECT user_id FROM public.users WHERE auth_id = auth.uid())
  OR public._is_board_post_participant(
       post_id, (SELECT user_id FROM public.users WHERE auth_id = auth.uid())
     )
);

-- ② 招待者の記録
ALTER TABLE public.group_memberships ADD COLUMN IF NOT EXISTS invited_by UUID REFERENCES public.users(user_id) ON DELETE SET NULL;
ALTER TABLE public.board_participations ADD COLUMN IF NOT EXISTS invited_by UUID REFERENCES public.users(user_id) ON DELETE SET NULL;

CREATE OR REPLACE FUNCTION public.invite_to_group(p_group_id UUID, p_user_id UUID)
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

  IF NOT EXISTS (
    SELECT 1 FROM public.group_memberships
    WHERE group_id = p_group_id AND user_id = v_caller_id AND status = 'member'
  ) THEN
    RAISE EXCEPTION 'only members can invite';
  END IF;

  INSERT INTO public.group_memberships (group_id, user_id, status, role, invited_by)
  VALUES (p_group_id, p_user_id, 'invited', 'member', v_caller_id)
  ON CONFLICT (group_id, user_id) DO UPDATE SET invited_by = v_caller_id
    WHERE public.group_memberships.status NOT IN ('member', 'pending');

  PERFORM public.create_app_notification(
    p_user_id, 'group_invite',
    jsonb_build_object('group_id', p_group_id), v_caller_id
  );
END;
$$;

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

  INSERT INTO public.board_participations (post_id, user_id, status, invited_by)
  VALUES (p_post_id, p_user_id, 'invited', v_caller_id)
  ON CONFLICT (post_id, user_id) DO UPDATE SET invited_by = v_caller_id
    WHERE public.board_participations.status NOT IN ('joined', 'pending');

  PERFORM public.create_app_notification(
    p_user_id, 'board_invite',
    jsonb_build_object('post_id', p_post_id), v_caller_id
  );
END;
$$;

-- ③ 辞退時の通知（グループ）
CREATE OR REPLACE FUNCTION public.respond_to_group_invite(p_membership_id UUID, p_accept BOOLEAN)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_id UUID;
  v_group_id  UUID;
  v_inviter   UUID;
BEGIN
  SELECT user_id INTO v_caller_id FROM public.users WHERE auth_id = auth.uid();

  SELECT group_id, invited_by INTO v_group_id, v_inviter
  FROM public.group_memberships
  WHERE membership_id = p_membership_id AND user_id = v_caller_id AND status = 'invited';

  IF p_accept THEN
    UPDATE public.group_memberships
    SET status = 'member', responded_at = NOW()
    WHERE membership_id = p_membership_id AND user_id = v_caller_id AND status = 'invited';
  ELSE
    DELETE FROM public.group_memberships
    WHERE membership_id = p_membership_id AND user_id = v_caller_id AND status = 'invited';

    IF v_inviter IS NOT NULL THEN
      PERFORM public.create_app_notification(
        v_inviter, 'group_invite_declined',
        jsonb_build_object('group_id', v_group_id), v_caller_id
      );
    END IF;
  END IF;
END;
$$;

-- ③ 掲示板の招待に対する承諾/辞退RPC（新設）
CREATE OR REPLACE FUNCTION public.respond_to_board_invite(p_participation_id UUID, p_accept BOOLEAN)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
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
$$;

REVOKE ALL ON FUNCTION public.respond_to_board_invite(UUID, BOOLEAN) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.respond_to_board_invite(UUID, BOOLEAN) TO authenticated;

-- app_notifications の type に辞退系を追加
ALTER TABLE public.app_notifications DROP CONSTRAINT IF EXISTS app_notifications_type_check;
ALTER TABLE public.app_notifications ADD CONSTRAINT app_notifications_type_check CHECK (type IN (
  'match', 'like_received', 'custom_interest', 'chat_message',
  'group_invite', 'group_join_request', 'group_invite_declined',
  'board_invite', 'board_join_request', 'board_invite_declined', 'level_up'
));
