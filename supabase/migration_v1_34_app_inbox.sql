-- ============================================================
-- Migration v1.34 : アプリ内通知（インボックス）共通基盤
-- Supabase SQL Editor で実行してください。
-- ------------------------------------------------------------
-- 目的:
--   マッチ・いいね受信・気になるカスタム・チャット・グループ招待/参加申請・
--   掲示板招待/参加申請など、「何かが起きたことをユーザーに知らせる」処理を
--   今後すべてこのテーブルに集約する。各機能は create_app_notification() を
--   呼ぶだけで済み、通知テーブルを毎回individually作らない。
--
--   何度実行しても安全（冪等）。
-- ============================================================

-- ============================================================
-- ① テーブル
-- ============================================================
CREATE TABLE IF NOT EXISTS public.app_notifications (
  notification_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         UUID NOT NULL REFERENCES public.users(user_id) ON DELETE CASCADE,
  type            TEXT NOT NULL CHECK (type IN (
                    'match', 'like_received', 'custom_interest', 'chat_message',
                    'group_invite', 'group_join_request',
                    'board_invite', 'board_join_request', 'level_up'
                  )),
  payload         JSONB NOT NULL DEFAULT '{}'::jsonb,
  related_user_id UUID REFERENCES public.users(user_id) ON DELETE SET NULL,
  is_read         BOOLEAN NOT NULL DEFAULT FALSE,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_app_notifications_user_unread
  ON public.app_notifications(user_id, is_read, created_at DESC);

ALTER TABLE public.app_notifications ENABLE ROW LEVEL SECURITY;

-- クライアントからの直接INSERT/DELETEは禁止。SELECT/UPDATEは本人の行のみ。
DROP POLICY IF EXISTS "app_notifications_select_own" ON public.app_notifications;
CREATE POLICY "app_notifications_select_own" ON public.app_notifications
  FOR SELECT USING (
    user_id IN (SELECT user_id FROM public.users WHERE auth_id = auth.uid())
  );

DROP POLICY IF EXISTS "app_notifications_update_own_read" ON public.app_notifications;
CREATE POLICY "app_notifications_update_own_read" ON public.app_notifications
  FOR UPDATE USING (
    user_id IN (SELECT user_id FROM public.users WHERE auth_id = auth.uid())
  ) WITH CHECK (
    user_id IN (SELECT user_id FROM public.users WHERE auth_id = auth.uid())
  );

REVOKE INSERT, DELETE ON public.app_notifications FROM authenticated, anon;

-- ============================================================
-- ② 書き込みは SECURITY DEFINER 関数経由のみ
--    （他のRPCから内部的に呼ばれる。クライアントから直接は呼ばせない）
-- ============================================================
CREATE OR REPLACE FUNCTION public.create_app_notification(
  p_user_id         UUID,
  p_type            TEXT,
  p_payload         JSONB DEFAULT '{}'::jsonb,
  p_related_user_id UUID DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_id UUID;
BEGIN
  INSERT INTO public.app_notifications (user_id, type, payload, related_user_id)
  VALUES (p_user_id, p_type, p_payload, p_related_user_id)
  RETURNING notification_id INTO v_id;
  RETURN v_id;
END;
$$;

REVOKE ALL ON FUNCTION public.create_app_notification(UUID, TEXT, JSONB, UUID) FROM PUBLIC;
-- authenticated には付与しない（他のSECURITY DEFINER関数の内部からのみ呼ばれる想定）。
-- service_roleのみ念のため付与。
GRANT EXECUTE ON FUNCTION public.create_app_notification(UUID, TEXT, JSONB, UUID) TO service_role;

-- 未読を既読にする（クライアントから直接呼べるRPC）
CREATE OR REPLACE FUNCTION public.mark_notification_read(p_notification_id UUID)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_user_id UUID;
BEGIN
  SELECT user_id INTO v_caller_user_id FROM public.users WHERE auth_id = auth.uid();

  UPDATE public.app_notifications
  SET is_read = TRUE
  WHERE notification_id = p_notification_id
    AND user_id = v_caller_user_id;
END;
$$;

REVOKE ALL ON FUNCTION public.mark_notification_read(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.mark_notification_read(UUID) TO authenticated;

-- ============================================================
-- ③ Realtime（未読バッジ用。最初の低リスクな導入）
-- ============================================================
DO $realtime_setup$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime' AND tablename = 'app_notifications'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.app_notifications;
  END IF;
END $realtime_setup$;
