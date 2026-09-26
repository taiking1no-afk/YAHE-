-- ============================================================
-- Migration v1.106 : 総合QAで発見した重大バグの修正
-- 前提: v1.105まで実行済み。
-- ------------------------------------------------------------
-- 対象:
--   ① [Critical] アカウント削除時、グループオーナー/イベント主催者の
--      退会によって groups.owner_id / board_posts.organizer_id の
--      ON DELETE CASCADE が発火し、他メンバー・他参加者の参加履歴や
--      チャット履歴まで本人の同意なく巻き添えで消える。
--      → 退会前にオーナー/主催者を他のメンバー/参加者へ自動移譲する
--        RPCを新設し、退会フロー(delete-account)から呼び出す。
--        他に誰もいない(自分だけ)場合のみ、従来通りCASCADE削除に任せる
--        （この場合は第三者への影響がないため問題ない）。
--   ② [Medium] invite_to_group が approval(承認制)モードのグループでも
--      一般メンバーからの招待を許可してしまい、オーナー承認を
--      バイパスして直接メンバーになれてしまう抜け道がある。
--   ③ [Medium] send_group_message にプッシュ通知/アプリ内通知の
--      送信が一切なく、DM(send_chat_message)と非対称。バックグラウンド
--      時にグループメッセージへ気付けない。
-- ============================================================

-- ① アカウント削除前のオーナー/主催者自動移譲
-- 呼び出し元(auth.uid())自身が対象。他人を指定して実行することはできない。
CREATE OR REPLACE FUNCTION public.prepare_account_deletion()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_id UUID;
  v_group RECORD;
  v_post RECORD;
  v_new_owner UUID;
  v_new_organizer UUID;
BEGIN
  SELECT user_id INTO v_caller_id FROM public.users WHERE auth_id = auth.uid();
  IF v_caller_id IS NULL THEN
    RETURN; -- 既に退会済み等、対象がなければ何もしない
  END IF;

  -- グループオーナーの移譲（他のメンバーがいる場合のみ）
  FOR v_group IN SELECT group_id, name FROM public.groups WHERE owner_id = v_caller_id LOOP
    SELECT user_id INTO v_new_owner
    FROM public.group_memberships
    WHERE group_id = v_group.group_id AND user_id <> v_caller_id AND status = 'member'
    ORDER BY created_at ASC
    LIMIT 1;

    IF v_new_owner IS NOT NULL THEN
      UPDATE public.groups SET owner_id = v_new_owner WHERE group_id = v_group.group_id;
      UPDATE public.group_memberships SET role = 'owner'
        WHERE group_id = v_group.group_id AND user_id = v_new_owner;
      PERFORM public.create_app_notification(
        v_new_owner, 'group_ownership_transferred',
        jsonb_build_object('group_id', v_group.group_id, 'group_name', v_group.name),
        v_caller_id
      );
    END IF;
    -- 他に誰もいない場合は移譲せず、後続のON DELETE CASCADEに任せる
    -- （自分だけのグループが消えるだけで第三者への影響はない）
  END LOOP;

  -- イベント/ツーリング募集(board_posts)主催者の移譲（他の参加者がいる場合のみ）
  FOR v_post IN SELECT post_id FROM public.board_posts WHERE organizer_id = v_caller_id LOOP
    SELECT user_id INTO v_new_organizer
    FROM public.board_participations
    WHERE post_id = v_post.post_id AND user_id <> v_caller_id AND status = 'joined'
    ORDER BY created_at ASC
    LIMIT 1;

    IF v_new_organizer IS NOT NULL THEN
      UPDATE public.board_posts SET organizer_id = v_new_organizer WHERE post_id = v_post.post_id;
    END IF;
  END LOOP;
END;
$$;

REVOKE ALL ON FUNCTION public.prepare_account_deletion() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.prepare_account_deletion() TO authenticated;

-- ② invite_to_group: approval(承認制)モードはオーナーのみ招待可能にする
--    （invite_only+リーダー制の既存チェックに、approvalモードの抜け道封鎖を追加）
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

  IF v_join_mode = 'approval' AND v_caller_role <> 'owner' THEN
    RAISE EXCEPTION 'only the owner can invite to an approval-only group';
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

-- ③ send_group_message: 送信者以外の全メンバーへアプリ内通知を送る
--    （app_notifications.type に group_message を追加）
ALTER TABLE public.app_notifications DROP CONSTRAINT IF EXISTS app_notifications_type_check;
ALTER TABLE public.app_notifications ADD CONSTRAINT app_notifications_type_check CHECK (type IN (
  'match', 'like_received', 'custom_interest', 'chat_message',
  'group_invite', 'group_join_request', 'group_invite_declined',
  'board_invite', 'board_join_request', 'board_invite_declined', 'level_up',
  'group_ownership_transferred', 'group_removed', 'group_message'
));

CREATE OR REPLACE FUNCTION public.send_group_message(
  p_group_id UUID,
  p_content_type TEXT,
  p_body TEXT DEFAULT NULL,
  p_photo_path TEXT DEFAULT NULL,
  p_related_post_id UUID DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_id UUID;
  v_message_id UUID;
  v_word RECORD;
  v_text TEXT;
  v_recent_count INT;
  v_group_name TEXT;
  v_member RECORD;
BEGIN
  SELECT user_id INTO v_caller_id FROM public.users WHERE auth_id = auth.uid();
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'unauthorized';
  END IF;

  SELECT count(*) INTO v_recent_count
  FROM public.group_messages
  WHERE sender_id = v_caller_id AND created_at > now() - interval '1 minute';
  IF v_recent_count >= 60 THEN
    RAISE EXCEPTION 'rate_limited';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.group_memberships
    WHERE group_id = p_group_id AND user_id = v_caller_id AND status = 'member'
  ) THEN
    RAISE EXCEPTION 'not a member';
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

  SELECT name INTO v_group_name FROM public.groups WHERE group_id = p_group_id;

  FOR v_member IN
    SELECT user_id FROM public.group_memberships
    WHERE group_id = p_group_id AND user_id <> v_caller_id AND status = 'member'
  LOOP
    PERFORM public.create_app_notification(
      v_member.user_id, 'group_message',
      jsonb_build_object('group_id', p_group_id, 'group_name', v_group_name), v_caller_id
    );
  END LOOP;

  RETURN v_message_id;
END;
$$;

REVOKE ALL ON FUNCTION public.send_group_message(UUID, TEXT, TEXT, TEXT, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.send_group_message(UUID, TEXT, TEXT, TEXT, UUID) TO authenticated;
