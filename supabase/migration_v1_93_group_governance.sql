-- ============================================================
-- Migration v1.93 : グループ統治の変更（リーダー制・除名機能）
-- Supabase SQL Editor で実行してください。前提: v1.38（groups）, v1.56（オーナー譲渡）実行済み。
-- ------------------------------------------------------------
-- 背景:
--   これまでグループのロールは owner/member の2種類しかなく、また
--   メンバーを除名する手段（kick）が一切存在しなかった（leave_groupは
--   本人の自主退会のみ）。開発者の要望に基づき、以下のルールを実装する:
--
--   - open（自由参加）: メンバー全員が他の非オーナーメンバーを招待・除名できる
--   - invite_only（招待制）かつ「リーダー制」有効: 招待・除名はオーナー/リーダーのみ
--   - approval（入室許可制）: 現状維持（オーナーのみが実質的な管理権限を持つ）
--
--   join_mode 自体に4つ目の値を足すのではなく、invite_only の意味を保った
--   まま groups.invite_restricted_to_leader フラグで「リーダー限定」を
--   表現する（既存の3値分岐コードへの影響を最小化するため）。
--
--   何度実行しても安全（冪等）。
-- ============================================================

-- ① ロールに 'leader' を追加
ALTER TABLE public.group_memberships DROP CONSTRAINT IF EXISTS group_memberships_role_check;
ALTER TABLE public.group_memberships ADD CONSTRAINT group_memberships_role_check
  CHECK (role IN ('owner', 'leader', 'member'));

-- ② グループに「招待をリーダー限定にする」フラグを追加（invite_only 時のみ意味を持つ）
ALTER TABLE public.groups ADD COLUMN IF NOT EXISTS invite_restricted_to_leader BOOLEAN NOT NULL DEFAULT FALSE;

-- ③ create_group を拡張（p_invite_restricted_to_leader を追加）
DROP FUNCTION IF EXISTS public.create_group(TEXT, TEXT, TEXT, TEXT);

CREATE OR REPLACE FUNCTION public.create_group(
  p_name TEXT,
  p_description TEXT,
  p_join_mode TEXT,
  p_icon_url TEXT DEFAULT NULL,
  p_invite_restricted_to_leader BOOLEAN DEFAULT FALSE
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_id UUID;
  v_group_id  UUID;
BEGIN
  SELECT user_id INTO v_caller_id FROM public.users WHERE auth_id = auth.uid();
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'unauthorized';
  END IF;
  IF p_join_mode NOT IN ('open', 'invite_only', 'approval') THEN
    RAISE EXCEPTION 'invalid join_mode';
  END IF;
  IF p_name IS NULL OR trim(p_name) = '' THEN
    RAISE EXCEPTION 'name required';
  END IF;

  INSERT INTO public.groups (owner_id, name, description, join_mode, icon_url, invite_restricted_to_leader)
  VALUES (v_caller_id, trim(p_name), p_description, p_join_mode, p_icon_url, COALESCE(p_invite_restricted_to_leader, FALSE))
  RETURNING group_id INTO v_group_id;

  INSERT INTO public.group_memberships (group_id, user_id, status, role)
  VALUES (v_group_id, v_caller_id, 'member', 'owner');

  RETURN v_group_id;
END;
$$;

REVOKE ALL ON FUNCTION public.create_group(TEXT, TEXT, TEXT, TEXT, BOOLEAN) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_group(TEXT, TEXT, TEXT, TEXT, BOOLEAN) TO authenticated;

-- ④ invite_to_group を更新：invite_only かつ invite_restricted_to_leader の場合は
--    オーナー/リーダーのみ招待可能にする（それ以外は従来通りメンバー全員可）
CREATE OR REPLACE FUNCTION public.invite_to_group(p_group_id UUID, p_user_id UUID)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_id  UUID;
  v_caller_role TEXT;
  v_join_mode  TEXT;
  v_restricted BOOLEAN;
BEGIN
  SELECT user_id INTO v_caller_id FROM public.users WHERE auth_id = auth.uid();
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'unauthorized';
  END IF;

  SELECT role INTO v_caller_role
  FROM public.group_memberships
  WHERE group_id = p_group_id AND user_id = v_caller_id AND status = 'member';

  IF v_caller_role IS NULL THEN
    RAISE EXCEPTION 'only members can invite';
  END IF;

  SELECT join_mode, invite_restricted_to_leader INTO v_join_mode, v_restricted
  FROM public.groups WHERE group_id = p_group_id;

  IF v_join_mode = 'invite_only' AND v_restricted AND v_caller_role NOT IN ('owner', 'leader') THEN
    RAISE EXCEPTION 'only the owner or leaders can invite to this group';
  END IF;

  INSERT INTO public.group_memberships (group_id, user_id, status, role)
  VALUES (p_group_id, p_user_id, 'invited', 'member')
  ON CONFLICT (group_id, user_id) DO NOTHING;

  PERFORM public.create_app_notification(
    p_user_id, 'group_invite',
    jsonb_build_object('group_id', p_group_id), v_caller_id
  );
END;
$$;

REVOKE ALL ON FUNCTION public.invite_to_group(UUID, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.invite_to_group(UUID, UUID) TO authenticated;

-- ⑤ promote_group_member：オーナーのみ、リーダーの昇格/降格
CREATE OR REPLACE FUNCTION public.promote_group_member(
  p_group_id UUID,
  p_user_id UUID,
  p_role TEXT
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_id UUID;
  v_owner_id  UUID;
BEGIN
  SELECT user_id INTO v_caller_id FROM public.users WHERE auth_id = auth.uid();
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'unauthorized';
  END IF;

  IF p_role NOT IN ('leader', 'member') THEN
    RAISE EXCEPTION 'invalid role';
  END IF;

  SELECT owner_id INTO v_owner_id FROM public.groups WHERE group_id = p_group_id;
  IF v_owner_id IS NULL OR v_owner_id <> v_caller_id THEN
    RAISE EXCEPTION 'only the group owner can change member roles';
  END IF;

  UPDATE public.group_memberships
  SET role = p_role
  WHERE group_id = p_group_id AND user_id = p_user_id AND status = 'member' AND role <> 'owner';
END;
$$;

REVOKE ALL ON FUNCTION public.promote_group_member(UUID, UUID, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.promote_group_member(UUID, UUID, TEXT) TO authenticated;

-- ⑥ kick_group_member：join_mode別の権限ルールでメンバーを除名する
CREATE OR REPLACE FUNCTION public.kick_group_member(
  p_group_id UUID,
  p_target_user_id UUID
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_id   UUID;
  v_caller_role TEXT;
  v_target_role TEXT;
  v_join_mode   TEXT;
  v_group_name  TEXT;
BEGIN
  SELECT user_id INTO v_caller_id FROM public.users WHERE auth_id = auth.uid();
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'unauthorized';
  END IF;

  IF p_target_user_id = v_caller_id THEN
    RAISE EXCEPTION 'cannot kick yourself; use leave_group instead';
  END IF;

  SELECT join_mode, name INTO v_join_mode, v_group_name
  FROM public.groups WHERE group_id = p_group_id;
  IF v_join_mode IS NULL THEN
    RAISE EXCEPTION 'group not found';
  END IF;

  SELECT role INTO v_caller_role
  FROM public.group_memberships
  WHERE group_id = p_group_id AND user_id = v_caller_id AND status = 'member';
  IF v_caller_role IS NULL THEN
    RAISE EXCEPTION 'not a member';
  END IF;

  SELECT role INTO v_target_role
  FROM public.group_memberships
  WHERE group_id = p_group_id AND user_id = p_target_user_id AND status = 'member';
  IF v_target_role IS NULL THEN
    RAISE EXCEPTION 'target is not a member';
  END IF;
  IF v_target_role = 'owner' THEN
    RAISE EXCEPTION 'cannot kick the owner';
  END IF;

  -- open: メンバー全員が除名可能。invite_only/approval: オーナー/リーダーのみ。
  IF v_join_mode <> 'open' AND v_caller_role NOT IN ('owner', 'leader') THEN
    RAISE EXCEPTION 'only the owner or leaders can remove members from this group';
  END IF;

  DELETE FROM public.group_memberships
  WHERE group_id = p_group_id AND user_id = p_target_user_id AND role <> 'owner';

  PERFORM public.create_app_notification(
    p_target_user_id, 'group_removed',
    jsonb_build_object('group_id', p_group_id, 'group_name', v_group_name), v_caller_id
  );
END;
$$;

REVOKE ALL ON FUNCTION public.kick_group_member(UUID, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.kick_group_member(UUID, UUID) TO authenticated;

-- ⑦ app_notifications.type に group_removed を追加
ALTER TABLE public.app_notifications DROP CONSTRAINT IF EXISTS app_notifications_type_check;
ALTER TABLE public.app_notifications ADD CONSTRAINT app_notifications_type_check CHECK (type IN (
  'match', 'like_received', 'custom_interest', 'chat_message',
  'group_invite', 'group_join_request', 'group_invite_declined',
  'board_invite', 'board_join_request', 'board_invite_declined', 'level_up',
  'group_ownership_transferred', 'group_removed'
));

-- ============================================================
-- 動作確認用クエリ（手動実行）
-- ============================================================
-- SELECT conname FROM pg_constraint WHERE conrelid = 'public.group_memberships'::regclass AND conname = 'group_memberships_role_check';
-- SELECT column_name FROM information_schema.columns WHERE table_name = 'groups' AND column_name = 'invite_restricted_to_leader';
-- SELECT proname FROM pg_proc WHERE proname IN ('kick_group_member', 'promote_group_member');
