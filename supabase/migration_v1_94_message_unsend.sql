-- ============================================================
-- Migration v1.94 : メッセージ・写真の送信取り消し（unsend）
-- Supabase SQL Editor で実行してください。前提: v1.40（チャット）, v1.46/v1.58/v1.59
-- （グループチャット・写真）実行済み。
-- ------------------------------------------------------------
-- 背景:
--   1対1 DM・グループチャットとも、送信したメッセージ/写真を後から
--   取り消す手段がなかった。deleted_at を追加し、本文/写真パスを
--   サーバー側でNULL化することで「メッセージは削除されました」を
--   データ層で保証する（クライアント側の非表示だけに頼らない）。
--   行自体は削除せず残すため、既存のSELECT RLSポリシーは変更不要。
--
--   写真の実体はDBのNULL化だけでは消えないため、Storage側にも
--   本人限定のDELETEポリシーを追加する（chat-photosは送信者IDが
--   フォルダ名なので単純に本人チェック、group-chat-photosはグループ
--   単位の共有フォルダのため group_messages.photo_path 経由で
--   送信者本人の投稿分のみ削除可能にする）。
--
--   何度実行しても安全（冪等）。
-- ============================================================

-- ① 論理削除カラム
ALTER TABLE public.chat_messages  ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMPTZ;
ALTER TABLE public.group_messages ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMPTZ;

-- ② unsend_chat_message：送信者本人のみ、本文/写真パスをNULL化
CREATE OR REPLACE FUNCTION public.unsend_chat_message(p_message_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_id UUID;
  v_sender_id UUID;
  v_deleted_at TIMESTAMPTZ;
BEGIN
  SELECT user_id INTO v_caller_id FROM public.users WHERE auth_id = auth.uid();
  IF v_caller_id IS NULL THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'unauthorized');
  END IF;

  SELECT sender_id, deleted_at INTO v_sender_id, v_deleted_at
  FROM public.chat_messages WHERE message_id = p_message_id;

  IF v_sender_id IS NULL THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'message_not_found');
  END IF;
  IF v_sender_id <> v_caller_id THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'forbidden');
  END IF;
  IF v_deleted_at IS NOT NULL THEN
    RETURN jsonb_build_object('success', TRUE, 'already_deleted', TRUE);
  END IF;

  UPDATE public.chat_messages
  SET deleted_at = NOW(), body = NULL, photo_path = NULL
  WHERE message_id = p_message_id;

  RETURN jsonb_build_object('success', TRUE);
END;
$$;

REVOKE ALL ON FUNCTION public.unsend_chat_message(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.unsend_chat_message(UUID) TO authenticated;

-- ③ unsend_group_message：同様
CREATE OR REPLACE FUNCTION public.unsend_group_message(p_message_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_id UUID;
  v_sender_id UUID;
  v_deleted_at TIMESTAMPTZ;
BEGIN
  SELECT user_id INTO v_caller_id FROM public.users WHERE auth_id = auth.uid();
  IF v_caller_id IS NULL THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'unauthorized');
  END IF;

  SELECT sender_id, deleted_at INTO v_sender_id, v_deleted_at
  FROM public.group_messages WHERE message_id = p_message_id;

  IF v_sender_id IS NULL THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'message_not_found');
  END IF;
  IF v_sender_id <> v_caller_id THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'forbidden');
  END IF;
  IF v_deleted_at IS NOT NULL THEN
    RETURN jsonb_build_object('success', TRUE, 'already_deleted', TRUE);
  END IF;

  UPDATE public.group_messages
  SET deleted_at = NOW(), body = NULL, photo_path = NULL
  WHERE message_id = p_message_id;

  RETURN jsonb_build_object('success', TRUE);
END;
$$;

REVOKE ALL ON FUNCTION public.unsend_group_message(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.unsend_group_message(UUID) TO authenticated;

-- ④ Storage DELETEポリシー（本人分のみ）
DO $unsend_storage_rls$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = 'storage' AND table_name = 'objects'
  ) THEN
    DROP POLICY IF EXISTS "chat_photos_delete_own" ON storage.objects;
    CREATE POLICY "chat_photos_delete_own" ON storage.objects
      FOR DELETE TO authenticated
      USING (
        bucket_id = 'chat-photos'
        AND (storage.foldername(name))[1] = (SELECT user_id::text FROM public.users WHERE auth_id = auth.uid())
      );

    DROP POLICY IF EXISTS "group_chat_photos_delete_sender" ON storage.objects;
    CREATE POLICY "group_chat_photos_delete_sender" ON storage.objects
      FOR DELETE TO authenticated
      USING (
        bucket_id = 'group-chat-photos'
        AND EXISTS (
          SELECT 1 FROM public.group_messages gm
          WHERE gm.photo_path = 'group-chat-photos:' || name
            AND gm.sender_id = (SELECT user_id FROM public.users WHERE auth_id = auth.uid())
        )
      );
  END IF;
END $unsend_storage_rls$;

-- ============================================================
-- 動作確認用クエリ（手動実行）
-- ============================================================
-- SELECT column_name FROM information_schema.columns WHERE table_name = 'chat_messages' AND column_name = 'deleted_at';
-- SELECT column_name FROM information_schema.columns WHERE table_name = 'group_messages' AND column_name = 'deleted_at';
-- SELECT proname FROM pg_proc WHERE proname IN ('unsend_chat_message', 'unsend_group_message');
-- SELECT policyname FROM pg_policies WHERE tablename = 'objects' AND policyname LIKE '%delete%';
