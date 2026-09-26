-- ============================================================
-- Migration v1.49 : チャット/グループチャットに「ツーリング・イベントに誘いました」表示
-- Supabase SQL Editor で実行してください。前提: v1.40（チャット）, v1.46（グループチャット）, v1.39（掲示板）実行済み。
-- ------------------------------------------------------------
-- 目的:
--   チャット画面・グループチャット画面の「誘う」ボタンで実際にツーリング/イベントへ
--   招待した際、そのチャットスレッド上にも「誘いました/誘われました」というメッセージ
--   カードを残し、タップで募集詳細へ飛べるようにする。
--
--   何度実行しても安全（冪等）。
-- ============================================================

ALTER TABLE public.chat_messages
  ADD COLUMN IF NOT EXISTS related_post_id UUID REFERENCES public.board_posts(post_id) ON DELETE SET NULL;
ALTER TABLE public.group_messages
  ADD COLUMN IF NOT EXISTS related_post_id UUID REFERENCES public.board_posts(post_id) ON DELETE SET NULL;

ALTER TABLE public.chat_messages DROP CONSTRAINT IF EXISTS chat_messages_content_type_check;
ALTER TABLE public.chat_messages ADD CONSTRAINT chat_messages_content_type_check
  CHECK (content_type IN ('text', 'photo', 'sns', 'quick_reply', 'board_invite'));

ALTER TABLE public.group_messages DROP CONSTRAINT IF EXISTS group_messages_content_type_check;
ALTER TABLE public.group_messages ADD CONSTRAINT group_messages_content_type_check
  CHECK (content_type IN ('text', 'quick_reply', 'board_invite'));


-- ============================================================
-- send_chat_message を拡張（p_related_post_id を追加）
-- v1.40の元定義をそのまま踏襲し、board_invite対応の分岐のみ追加する。
-- 引数を追加するためシグネチャが変わり、事前にDROPが必要。
-- ============================================================
DROP FUNCTION IF EXISTS public.send_chat_message(UUID, TEXT, TEXT, TEXT);

CREATE OR REPLACE FUNCTION public.send_chat_message(
  p_match_id UUID,
  p_content_type TEXT,
  p_body TEXT DEFAULT NULL,
  p_photo_path TEXT DEFAULT NULL,
  p_related_post_id UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_id UUID;
  v_a UUID;
  v_b UUID;
  v_other_id UUID;
  v_thread_id UUID;
  v_message_id UUID;
  v_word RECORD;
  v_text TEXT;
BEGIN
  SELECT user_id INTO v_caller_id FROM public.users WHERE auth_id = auth.uid();
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'unauthorized';
  END IF;

  IF p_content_type NOT IN ('text', 'photo', 'sns', 'quick_reply', 'board_invite') THEN
    RAISE EXCEPTION 'invalid content_type';
  END IF;
  IF p_content_type = 'board_invite' AND p_related_post_id IS NULL THEN
    RAISE EXCEPTION 'related_post_id required for board_invite';
  END IF;

  SELECT user_a_id, user_b_id INTO v_a, v_b FROM public.matches WHERE match_id = p_match_id;
  IF v_a IS NULL THEN
    RAISE EXCEPTION 'match not found';
  END IF;
  IF v_caller_id <> v_a AND v_caller_id <> v_b THEN
    RAISE EXCEPTION 'not a participant of this match';
  END IF;
  v_other_id := CASE WHEN v_caller_id = v_a THEN v_b ELSE v_a END;

  -- NGワード検知（同期チェック。検知時は送信自体を拒否する）
  IF p_body IS NOT NULL AND p_body <> '' THEN
    v_text := lower(p_body);
    FOR v_word IN SELECT word FROM public.ng_words LOOP
      IF position(lower(v_word.word) IN v_text) > 0 THEN
        RAISE EXCEPTION 'ng_word_detected';
      END IF;
    END LOOP;
  END IF;

  -- スレッドを遅延作成
  SELECT thread_id INTO v_thread_id FROM public.chat_threads WHERE match_id = p_match_id;
  IF v_thread_id IS NULL THEN
    INSERT INTO public.chat_threads (match_id) VALUES (p_match_id)
    ON CONFLICT (match_id) DO NOTHING
    RETURNING thread_id INTO v_thread_id;

    IF v_thread_id IS NULL THEN
      SELECT thread_id INTO v_thread_id FROM public.chat_threads WHERE match_id = p_match_id;
    END IF;
  END IF;

  INSERT INTO public.chat_messages (thread_id, sender_id, content_type, body, photo_path, related_post_id)
  VALUES (v_thread_id, v_caller_id, p_content_type, p_body, p_photo_path, p_related_post_id)
  RETURNING message_id INTO v_message_id;

  PERFORM public.create_app_notification(
    v_other_id, 'chat_message',
    jsonb_build_object('match_id', p_match_id, 'thread_id', v_thread_id), v_caller_id
  );

  RETURN jsonb_build_object('success', TRUE, 'message_id', v_message_id, 'thread_id', v_thread_id);
END;
$$;

REVOKE ALL ON FUNCTION public.send_chat_message(UUID, TEXT, TEXT, TEXT, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.send_chat_message(UUID, TEXT, TEXT, TEXT, UUID) TO authenticated;


-- ============================================================
-- send_group_message を拡張（p_related_post_id を追加）
-- v1.46の元定義をそのまま踏襲し、board_invite対応の分岐のみ追加する。
-- ============================================================
DROP FUNCTION IF EXISTS public.send_group_message(UUID, TEXT, TEXT);

CREATE OR REPLACE FUNCTION public.send_group_message(
  p_group_id UUID,
  p_content_type TEXT,
  p_body TEXT,
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

  IF p_content_type NOT IN ('text', 'quick_reply', 'board_invite') THEN
    RAISE EXCEPTION 'invalid content_type';
  END IF;
  IF p_content_type = 'board_invite' AND p_related_post_id IS NULL THEN
    RAISE EXCEPTION 'related_post_id required for board_invite';
  END IF;
  IF p_body IS NULL OR trim(p_body) = '' THEN
    RAISE EXCEPTION 'body required';
  END IF;

  v_text := lower(p_body);
  FOR v_word IN SELECT word FROM public.ng_words LOOP
    IF position(lower(v_word.word) IN v_text) > 0 THEN
      RAISE EXCEPTION 'ng_word_detected';
    END IF;
  END LOOP;

  INSERT INTO public.group_messages (group_id, sender_id, content_type, body, related_post_id)
  VALUES (p_group_id, v_caller_id, p_content_type, trim(p_body), p_related_post_id)
  RETURNING message_id INTO v_message_id;

  RETURN v_message_id;
END;
$$;

REVOKE ALL ON FUNCTION public.send_group_message(UUID, TEXT, TEXT, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.send_group_message(UUID, TEXT, TEXT, UUID) TO authenticated;
