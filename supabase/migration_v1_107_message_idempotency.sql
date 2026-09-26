-- ============================================================
-- Migration v1.107 : メッセージ送信の重複防止（冪等キー）
-- 前提: v1.106まで実行済み。
-- ------------------------------------------------------------
-- 対象: 【BUG-012】チャット/グループメッセージ送信にDBレベルの重複防止が
-- 無く、通信リトライやクライアントの多重送信で同一内容のメッセージが
-- 複数行作成されうる。クライアントが送信1回ごとに生成するUUID
-- (client_message_id)を受け取り、同じ送信者・同じUUIDでの再送は
-- 新規挿入せず既存行を返す（冪等化）。
-- ============================================================

ALTER TABLE public.chat_messages ADD COLUMN IF NOT EXISTS client_message_id UUID;
ALTER TABLE public.group_messages ADD COLUMN IF NOT EXISTS client_message_id UUID;

CREATE UNIQUE INDEX IF NOT EXISTS idx_chat_messages_client_dedupe
  ON public.chat_messages (sender_id, client_message_id)
  WHERE client_message_id IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS idx_group_messages_client_dedupe
  ON public.group_messages (sender_id, client_message_id)
  WHERE client_message_id IS NOT NULL;

-- send_chat_message: p_client_message_id を追加
DROP FUNCTION IF EXISTS public.send_chat_message(uuid, text, text, text, uuid);

CREATE OR REPLACE FUNCTION public.send_chat_message(
  p_match_id uuid,
  p_content_type text,
  p_body text DEFAULT NULL::text,
  p_photo_path text DEFAULT NULL::text,
  p_related_post_id uuid DEFAULT NULL::uuid,
  p_client_message_id uuid DEFAULT NULL::uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_caller_id UUID;
  v_a UUID;
  v_b UUID;
  v_dissolved_at TIMESTAMPTZ;
  v_other_id UUID;
  v_thread_id UUID;
  v_message_id UUID;
  v_word RECORD;
  v_text TEXT;
  v_recent_count INT;
  v_is_new BOOLEAN;
BEGIN
  SELECT user_id INTO v_caller_id FROM public.users WHERE auth_id = auth.uid();
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'unauthorized';
  END IF;

  SELECT count(*) INTO v_recent_count
  FROM public.chat_messages
  WHERE sender_id = v_caller_id AND created_at > now() - interval '1 minute';
  IF v_recent_count >= 60 THEN
    RAISE EXCEPTION 'rate_limited';
  END IF;

  IF p_content_type NOT IN ('text', 'photo', 'sns', 'quick_reply', 'board_invite') THEN
    RAISE EXCEPTION 'invalid content_type';
  END IF;
  IF p_content_type = 'board_invite' AND p_related_post_id IS NULL THEN
    RAISE EXCEPTION 'related_post_id required for board_invite';
  END IF;

  SELECT user_a_id, user_b_id, dissolved_at INTO v_a, v_b, v_dissolved_at
  FROM public.matches WHERE match_id = p_match_id;
  IF v_a IS NULL THEN
    RAISE EXCEPTION 'match not found';
  END IF;
  IF v_caller_id <> v_a AND v_caller_id <> v_b THEN
    RAISE EXCEPTION 'not a participant of this match';
  END IF;
  IF v_dissolved_at IS NOT NULL THEN
    RAISE EXCEPTION 'match_dissolved';
  END IF;
  v_other_id := CASE WHEN v_caller_id = v_a THEN v_b ELSE v_a END;

  IF EXISTS (
    SELECT 1 FROM public.blocks
    WHERE (blocker_id = v_caller_id AND blocked_id = v_other_id)
       OR (blocker_id = v_other_id AND blocked_id = v_caller_id)
  ) THEN
    RAISE EXCEPTION 'blocked';
  END IF;

  IF p_body IS NOT NULL AND p_body <> '' THEN
    v_text := lower(p_body);
    FOR v_word IN SELECT word FROM public.ng_words LOOP
      IF position(lower(v_word.word) IN v_text) > 0 THEN
        RAISE EXCEPTION 'ng_word_detected';
      END IF;
    END LOOP;
  END IF;

  SELECT thread_id INTO v_thread_id FROM public.chat_threads WHERE match_id = p_match_id;
  IF v_thread_id IS NULL THEN
    INSERT INTO public.chat_threads (match_id) VALUES (p_match_id)
    ON CONFLICT (match_id) DO NOTHING
    RETURNING thread_id INTO v_thread_id;

    IF v_thread_id IS NULL THEN
      SELECT thread_id INTO v_thread_id FROM public.chat_threads WHERE match_id = p_match_id;
    END IF;
  END IF;

  -- p_client_message_idが同じ送信者から再送された場合、新規行を作らず
  -- 既存行のmessage_idをそのまま返す（通信リトライ等での二重メッセージ防止）。
  INSERT INTO public.chat_messages
    (thread_id, sender_id, content_type, body, photo_path, related_post_id, client_message_id)
  VALUES
    (v_thread_id, v_caller_id, p_content_type, p_body, p_photo_path, p_related_post_id, p_client_message_id)
  ON CONFLICT (sender_id, client_message_id) WHERE client_message_id IS NOT NULL
  DO UPDATE SET client_message_id = EXCLUDED.client_message_id
  RETURNING message_id, (xmax = 0) INTO v_message_id, v_is_new;

  -- 既存行が返っただけ(=新規挿入ではない、同じclient_message_idの再送)場合は
  -- 通知も再送しない。
  IF NOT v_is_new THEN
    RETURN jsonb_build_object('success', TRUE, 'message_id', v_message_id, 'thread_id', v_thread_id);
  END IF;

  PERFORM public.create_app_notification(
    v_other_id, 'chat_message',
    jsonb_build_object('match_id', p_match_id, 'thread_id', v_thread_id), v_caller_id
  );

  RETURN jsonb_build_object('success', TRUE, 'message_id', v_message_id, 'thread_id', v_thread_id);
END;
$function$;

REVOKE ALL ON FUNCTION public.send_chat_message(uuid, text, text, text, uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.send_chat_message(uuid, text, text, text, uuid, uuid) TO authenticated;

-- send_group_message: p_client_message_id を追加
DROP FUNCTION IF EXISTS public.send_group_message(uuid, text, text, text, uuid);

CREATE OR REPLACE FUNCTION public.send_group_message(
  p_group_id UUID,
  p_content_type TEXT,
  p_body TEXT DEFAULT NULL,
  p_photo_path TEXT DEFAULT NULL,
  p_related_post_id UUID DEFAULT NULL,
  p_client_message_id UUID DEFAULT NULL
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
  v_is_new BOOLEAN;
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

  INSERT INTO public.group_messages
    (group_id, sender_id, content_type, body, photo_path, related_post_id, client_message_id)
  VALUES
    (p_group_id, v_caller_id, p_content_type, NULLIF(trim(coalesce(p_body, '')), ''), p_photo_path, p_related_post_id, p_client_message_id)
  ON CONFLICT (sender_id, client_message_id) WHERE client_message_id IS NOT NULL
  DO UPDATE SET client_message_id = EXCLUDED.client_message_id
  RETURNING message_id, (xmax = 0) INTO v_message_id, v_is_new;

  -- 既存行が返っただけ(=新規挿入ではない)場合は通知を再送しない。
  IF NOT v_is_new THEN
    RETURN v_message_id;
  END IF;

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

REVOKE ALL ON FUNCTION public.send_group_message(uuid, text, text, text, uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.send_group_message(uuid, text, text, text, uuid, uuid) TO authenticated;
