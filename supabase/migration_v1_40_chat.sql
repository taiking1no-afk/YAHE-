-- ============================================================
-- Migration v1.40 : チャット機能（このアプリで初めてSupabase Realtimeを
-- 双方向メッセージングに使う。導入リスクが高いので実装後に必ず2アカウントで
-- 手動確認すること：片方が送信→もう片方に届くか、第三者アカウントには
-- 絶対に届かないか）
-- Supabase SQL Editor で実行してください。前提: v1.13（NGワード辞書）・
-- v1.34（app_notifications）実行済み。
--
--   何度実行しても安全（冪等）。
-- ============================================================

CREATE TABLE IF NOT EXISTS public.chat_threads (
  thread_id  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  match_id   UUID NOT NULL UNIQUE REFERENCES public.matches(match_id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.chat_messages (
  message_id   UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  thread_id    UUID NOT NULL REFERENCES public.chat_threads(thread_id) ON DELETE CASCADE,
  sender_id    UUID NOT NULL REFERENCES public.users(user_id) ON DELETE CASCADE,
  content_type TEXT NOT NULL CHECK (content_type IN ('text', 'photo', 'sns', 'quick_reply')),
  body         TEXT,
  photo_path   TEXT,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  read_at      TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_chat_messages_thread ON public.chat_messages(thread_id, created_at);

ALTER TABLE public.chat_threads ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.chat_messages ENABLE ROW LEVEL SECURITY;

-- スレッド：matches の当事者2人のみ閲覧可
DROP POLICY IF EXISTS "chat_threads_select_participant" ON public.chat_threads;
CREATE POLICY "chat_threads_select_participant" ON public.chat_threads FOR SELECT USING (
  match_id IN (
    SELECT match_id FROM public.matches
    WHERE user_a_id IN (SELECT user_id FROM public.users WHERE auth_id = auth.uid())
       OR user_b_id IN (SELECT user_id FROM public.users WHERE auth_id = auth.uid())
  )
);

-- メッセージ：スレッドの当事者2人のみ閲覧可。書き込みはRPC経由のみ。
DROP POLICY IF EXISTS "chat_messages_select_participant" ON public.chat_messages;
CREATE POLICY "chat_messages_select_participant" ON public.chat_messages FOR SELECT USING (
  thread_id IN (
    SELECT ct.thread_id FROM public.chat_threads ct
    JOIN public.matches m ON m.match_id = ct.match_id
    WHERE m.user_a_id IN (SELECT user_id FROM public.users WHERE auth_id = auth.uid())
       OR m.user_b_id IN (SELECT user_id FROM public.users WHERE auth_id = auth.uid())
  )
);

REVOKE INSERT, UPDATE, DELETE ON public.chat_threads, public.chat_messages FROM authenticated, anon;

-- 未読の既読化のみクライアントから直接許可（それ以外はRPC経由）
GRANT UPDATE (read_at) ON public.chat_messages TO authenticated;
DROP POLICY IF EXISTS "chat_messages_update_read_at" ON public.chat_messages;
CREATE POLICY "chat_messages_update_read_at" ON public.chat_messages FOR UPDATE USING (
  thread_id IN (
    SELECT ct.thread_id FROM public.chat_threads ct
    JOIN public.matches m ON m.match_id = ct.match_id
    WHERE m.user_a_id IN (SELECT user_id FROM public.users WHERE auth_id = auth.uid())
       OR m.user_b_id IN (SELECT user_id FROM public.users WHERE auth_id = auth.uid())
  )
  AND sender_id NOT IN (SELECT user_id FROM public.users WHERE auth_id = auth.uid())
);

-- Realtime配信（RLSにより当事者2人にしか届かないことを実装後に必ず手動確認する）
DO $realtime_setup$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime' AND tablename = 'chat_messages'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.chat_messages;
  END IF;
END $realtime_setup$;

-- ============================================================
-- 送信RPC（NGワード検知時は送信自体をブロックする）
-- ============================================================
CREATE OR REPLACE FUNCTION public.send_chat_message(
  p_match_id UUID,
  p_content_type TEXT,
  p_body TEXT DEFAULT NULL,
  p_photo_path TEXT DEFAULT NULL
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

  IF p_content_type NOT IN ('text', 'photo', 'sns', 'quick_reply') THEN
    RAISE EXCEPTION 'invalid content_type';
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

  INSERT INTO public.chat_messages (thread_id, sender_id, content_type, body, photo_path)
  VALUES (v_thread_id, v_caller_id, p_content_type, p_body, p_photo_path)
  RETURNING message_id INTO v_message_id;

  PERFORM public.create_app_notification(
    v_other_id, 'chat_message',
    jsonb_build_object('match_id', p_match_id, 'thread_id', v_thread_id), v_caller_id
  );

  RETURN jsonb_build_object('success', TRUE, 'message_id', v_message_id, 'thread_id', v_thread_id);
END;
$$;

REVOKE ALL ON FUNCTION public.send_chat_message(UUID, TEXT, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.send_chat_message(UUID, TEXT, TEXT, TEXT) TO authenticated;

-- match_idからthread_idを取得（存在しなければNULL。まだ何もメッセージがない場合）
CREATE OR REPLACE FUNCTION public.get_chat_thread_id(p_match_id UUID)
RETURNS UUID
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT thread_id FROM public.chat_threads WHERE match_id = p_match_id;
$$;

REVOKE ALL ON FUNCTION public.get_chat_thread_id(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_chat_thread_id(UUID) TO authenticated;

-- ============================================================
-- Storageバケット（写真、非公開・署名付きURL方式。vehicle-photosと違い公開バケットにしない）
-- ============================================================
INSERT INTO storage.buckets (id, name, public)
VALUES ('chat-photos', 'chat-photos', false)
ON CONFLICT (id) DO NOTHING;

-- 送信者本人がマッチ相手を閲覧できるかの判定（storage.objectsポリシー用）
CREATE OR REPLACE FUNCTION public.can_view_chat_photo(p_sender_id UUID)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    p_sender_id IN (SELECT user_id FROM public.users WHERE auth_id = auth.uid())
    OR EXISTS (
      SELECT 1 FROM public.matches m
      JOIN public.users me ON me.auth_id = auth.uid()
      WHERE (m.user_a_id = me.user_id AND m.user_b_id = p_sender_id)
         OR (m.user_b_id = me.user_id AND m.user_a_id = p_sender_id)
    );
$$;

REVOKE ALL ON FUNCTION public.can_view_chat_photo(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.can_view_chat_photo(UUID) TO authenticated;

DO $chat_storage_rls$
DECLARE
  v_uid_expr TEXT := '(SELECT user_id::text FROM public.users WHERE auth_id = auth.uid())';
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = 'storage' AND table_name = 'objects'
  ) THEN
    DROP POLICY IF EXISTS "chat_photos_insert_own" ON storage.objects;
    DROP POLICY IF EXISTS "chat_photos_read_participants" ON storage.objects;

    EXECUTE format($pol$
      CREATE POLICY "chat_photos_insert_own" ON storage.objects
        FOR INSERT TO authenticated
        WITH CHECK (
          bucket_id = 'chat-photos'
          AND (storage.foldername(name))[1] = %1$s
        )
    $pol$, v_uid_expr);

    EXECUTE $pol$
      CREATE POLICY "chat_photos_read_participants" ON storage.objects
        FOR SELECT TO authenticated
        USING (
          bucket_id = 'chat-photos'
          AND (storage.foldername(name))[1] IS NOT NULL
          AND (storage.foldername(name))[1] ~ '^[0-9a-f-]{36}$'
          AND public.can_view_chat_photo(((storage.foldername(name))[1])::uuid)
        )
    $pol$;
  END IF;
END $chat_storage_rls$;
