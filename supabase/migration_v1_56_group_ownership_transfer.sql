-- ============================================================
-- Migration v1.56 : グループのオーナー権限譲渡
-- Supabase SQL Editor で実行してください。前提: v1.38（groups）実行済み。
-- ------------------------------------------------------------
-- 目的:
--   グループ情報の編集自体は既存の groups_update_own RLS ポリシーで
--   オーナー本人がクライアントから直接 UPDATE できる（owner_id は
--   WITH CHECK が USING を継承するため、他人へのなりすまし変更は
--   RLS上できない）。
--
--   ただし「オーナー権限を他のメンバーに譲渡する」（groups.owner_id の
--   変更 + group_memberships.role の入れ替え）はRLSだけでは安全に
--   表現できないため、専用のSECURITY DEFINER RPCを新設する。
--
--   何度実行しても安全（冪等）。
-- ============================================================

CREATE OR REPLACE FUNCTION public.transfer_group_ownership(p_group_id UUID, p_new_owner_id UUID)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_id UUID;
  v_owner_id  UUID;
  v_group_name TEXT;
BEGIN
  SELECT user_id INTO v_caller_id FROM public.users WHERE auth_id = auth.uid();

  SELECT owner_id, name INTO v_owner_id, v_group_name FROM public.groups WHERE group_id = p_group_id;

  IF v_owner_id IS NULL OR v_owner_id <> v_caller_id THEN
    RAISE EXCEPTION 'only the group owner can transfer ownership';
  END IF;

  IF p_new_owner_id = v_caller_id THEN
    RAISE EXCEPTION 'already the owner';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.group_memberships
    WHERE group_id = p_group_id AND user_id = p_new_owner_id AND status = 'member'
  ) THEN
    RAISE EXCEPTION 'new owner must be an existing member of the group';
  END IF;

  UPDATE public.groups SET owner_id = p_new_owner_id WHERE group_id = p_group_id;

  UPDATE public.group_memberships
  SET role = 'member'
  WHERE group_id = p_group_id AND user_id = v_caller_id AND role = 'owner';

  UPDATE public.group_memberships
  SET role = 'owner'
  WHERE group_id = p_group_id AND user_id = p_new_owner_id;

  PERFORM public.create_app_notification(
    p_new_owner_id, 'group_ownership_transferred',
    jsonb_build_object('group_id', p_group_id, 'group_name', v_group_name), v_caller_id
  );
END;
$$;

REVOKE ALL ON FUNCTION public.transfer_group_ownership(UUID, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.transfer_group_ownership(UUID, UUID) TO authenticated;

-- app_notifications の type にオーナー譲渡を追加
ALTER TABLE public.app_notifications DROP CONSTRAINT IF EXISTS app_notifications_type_check;
ALTER TABLE public.app_notifications ADD CONSTRAINT app_notifications_type_check CHECK (type IN (
  'match', 'like_received', 'custom_interest', 'chat_message',
  'group_invite', 'group_join_request', 'group_invite_declined',
  'board_invite', 'board_join_request', 'board_invite_declined', 'level_up',
  'group_ownership_transferred'
));
