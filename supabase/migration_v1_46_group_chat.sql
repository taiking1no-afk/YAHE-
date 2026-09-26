-- ============================================================
-- Migration v1.46 : グループチャット（メンバー間のメッセージ）
-- Supabase SQL Editor で実行してください。前提: v1.38（グループ）, v1.40（チャット/NGワード）実行済み。
-- ------------------------------------------------------------
-- 目的:
--   グループに「メンバー限定のメッセージやり取り」を追加する。
--   1:1チャット（v1.40）と同じ方針:
--     - メッセージ本文はRPC経由のみ書き込み可能（直接INSERT禁止）
--     - NGワード検知時は送信自体をブロック
--     - Realtimeでリアルタイム反映
--   写真送信は今回のスコープ外（テキスト・定型文のみ）。
--
--   何度実行しても安全（冪等）。
-- ============================================================

CREATE TABLE IF NOT EXISTS public.group_messages (
  message_id   UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  group_id     UUID NOT NULL REFERENCES public.groups(group_id) ON DELETE CASCADE,
  sender_id    UUID NOT NULL REFERENCES public.users(user_id) ON DELETE CASCADE,
  content_type TEXT NOT NULL DEFAULT 'text' CHECK (content_type IN ('text', 'quick_reply')),
  body         TEXT,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_group_messages_group_created ON public.group_messages(group_id, created_at);

CREATE TABLE IF NOT EXISTS public.group_message_reads (
  group_id     UUID NOT NULL REFERENCES public.groups(group_id) ON DELETE CASCADE,
  user_id      UUID NOT NULL REFERENCES public.users(user_id) ON DELETE CASCADE,
  last_read_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (group_id, user_id)
);

ALTER TABLE public.group_messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.group_message_reads ENABLE ROW LEVEL SECURITY;

-- メンバー（status='member'）のみ閲覧可能。
-- group_membershipsのポリシー(v1.45)はgroup_messagesを参照しないため循環しない。
DROP POLICY IF EXISTS "group_messages_select" ON public.group_messages;
CREATE POLICY "group_messages_select" ON public.group_messages FOR SELECT USING (
  EXISTS (
    SELECT 1 FROM public.group_memberships gm
    WHERE gm.group_id = group_messages.group_id
      AND gm.status = 'member'
      AND gm.user_id IN (SELECT user_id FROM public.users WHERE auth_id = auth.uid())
  )
);

REVOKE INSERT, UPDATE, DELETE ON public.group_messages FROM authenticated, anon;

DROP POLICY IF EXISTS "group_message_reads_select_own" ON public.group_message_reads;
CREATE POLICY "group_message_reads_select_own" ON public.group_message_reads FOR SELECT USING (
  user_id IN (SELECT user_id FROM public.users WHERE auth_id = auth.uid())
);

REVOKE INSERT, UPDATE, DELETE ON public.group_message_reads FROM authenticated, anon;

-- ============================================================
-- RPC群
-- ============================================================

CREATE OR REPLACE FUNCTION public.send_group_message(
  p_group_id UUID,
  p_content_type TEXT,
  p_body TEXT
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

  IF p_content_type NOT IN ('text', 'quick_reply') THEN
    RAISE EXCEPTION 'invalid content_type';
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

  INSERT INTO public.group_messages (group_id, sender_id, content_type, body)
  VALUES (p_group_id, v_caller_id, p_content_type, trim(p_body))
  RETURNING message_id INTO v_message_id;

  RETURN v_message_id;
END;
$$;

REVOKE ALL ON FUNCTION public.send_group_message(UUID, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.send_group_message(UUID, TEXT, TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION public.mark_group_read(p_group_id UUID)
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
    RETURN;
  END IF;

  INSERT INTO public.group_message_reads (group_id, user_id, last_read_at)
  VALUES (p_group_id, v_caller_id, NOW())
  ON CONFLICT (group_id, user_id) DO UPDATE SET last_read_at = NOW();
END;
$$;

REVOKE ALL ON FUNCTION public.mark_group_read(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.mark_group_read(UUID) TO authenticated;

-- 自分が参加中の各グループについて、未読件数・最終メッセージをまとめて取得する
-- （クライアントでN+1にしないためRPCで集計する）
CREATE OR REPLACE FUNCTION public.get_my_group_chat_summaries()
RETURNS TABLE(
  group_id UUID,
  last_message_body TEXT,
  last_message_at TIMESTAMPTZ,
  unread_count BIGINT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_id UUID;
BEGIN
  SELECT user_id INTO v_caller_id FROM public.users WHERE auth_id = auth.uid();
  IF v_caller_id IS NULL THEN
    RETURN;
  END IF;

  RETURN QUERY
  SELECT
    gm.group_id,
    lm.body,
    lm.created_at,
    COUNT(unread.message_id)
  FROM public.group_memberships gm
  LEFT JOIN LATERAL (
    SELECT gmsg.body, gmsg.created_at
    FROM public.group_messages gmsg
    WHERE gmsg.group_id = gm.group_id
    ORDER BY gmsg.created_at DESC
    LIMIT 1
  ) lm ON TRUE
  LEFT JOIN public.group_message_reads gr ON gr.group_id = gm.group_id AND gr.user_id = v_caller_id
  LEFT JOIN public.group_messages unread ON unread.group_id = gm.group_id
    AND unread.sender_id <> v_caller_id
    AND unread.created_at > COALESCE(gr.last_read_at, 'epoch'::timestamptz)
  WHERE gm.user_id = v_caller_id AND gm.status = 'member'
  GROUP BY gm.group_id, lm.body, lm.created_at;
END;
$$;

REVOKE ALL ON FUNCTION public.get_my_group_chat_summaries() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_my_group_chat_summaries() TO authenticated;

DO $realtime_setup$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime' AND tablename = 'group_messages'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.group_messages;
  END IF;
END $realtime_setup$;
