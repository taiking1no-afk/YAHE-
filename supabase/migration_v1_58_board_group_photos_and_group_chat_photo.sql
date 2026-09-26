-- ============================================================
-- Migration v1.58 : 掲示板の画像添付・グループ画像添付・グループチャット写真送信
-- Supabase SQL Editor で実行してください。
-- 前提: v1.39（掲示板）, v1.38（グループ）, v1.46/v1.49（グループチャット）実行済み。
-- ------------------------------------------------------------
-- 目的:
--   1) 掲示板投稿(募集)に画像を1枚添付できるようにする。
--   2) グループにプロフィール画像（アイコン）を添付できるようにする
--      （groups.icon_url 列自体はv1.38から存在するが、これまでアップロード
--        経路（Storageバケット・RLS）が一度も用意されていなかった）。
--   3) グループチャットに写真を投稿できるようにする（1:1チャットのphoto送信と
--      同じ方式）。
--
--   何度実行しても安全（冪等）。
-- ============================================================

-- ① 掲示板投稿：画像パス列
ALTER TABLE public.board_posts ADD COLUMN IF NOT EXISTS image_path TEXT;

-- ② グループチャット：写真送信対応
ALTER TABLE public.group_messages ADD COLUMN IF NOT EXISTS photo_path TEXT;

ALTER TABLE public.group_messages DROP CONSTRAINT IF EXISTS group_messages_content_type_check;
ALTER TABLE public.group_messages ADD CONSTRAINT group_messages_content_type_check
  CHECK (content_type IN ('text', 'photo', 'quick_reply', 'board_invite'));

-- send_group_message を拡張（p_photo_path を追加）。
-- v1.49の定義をそのまま踏襲し、photo対応の分岐のみ追加する。
DROP FUNCTION IF EXISTS public.send_group_message(UUID, TEXT, TEXT, UUID);

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

  RETURN v_message_id;
END;
$$;

REVOKE ALL ON FUNCTION public.send_group_message(UUID, TEXT, TEXT, TEXT, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.send_group_message(UUID, TEXT, TEXT, TEXT, UUID) TO authenticated;

-- ============================================================
-- ③ Storageバケット新設
-- ============================================================

INSERT INTO storage.buckets (id, name, public)
VALUES ('board-photos', 'board-photos', false)
ON CONFLICT (id) DO NOTHING;

INSERT INTO storage.buckets (id, name, public)
VALUES ('group-photos', 'group-photos', false)
ON CONFLICT (id) DO NOTHING;

-- board-photos: パスは "{post_id}/{filename}"。主催者のみアップロード/更新/削除可能。
-- 閲覧は既存の board_posts_select と同じ可視性ルール（_board_post_visibility_ok）に揃える。
DROP POLICY IF EXISTS "board_photos_select" ON storage.objects;
CREATE POLICY "board_photos_select" ON storage.objects FOR SELECT USING (
  bucket_id = 'board-photos'
  AND public._board_post_visibility_ok(
        ((storage.foldername(name))[1])::uuid,
        (SELECT user_id FROM public.users WHERE auth_id = auth.uid())
      )
);

DROP POLICY IF EXISTS "board_photos_insert_organizer" ON storage.objects;
CREATE POLICY "board_photos_insert_organizer" ON storage.objects FOR INSERT WITH CHECK (
  bucket_id = 'board-photos'
  AND EXISTS (
    SELECT 1 FROM public.board_posts bp
    WHERE bp.post_id = ((storage.foldername(name))[1])::uuid
      AND bp.organizer_id = (SELECT user_id FROM public.users WHERE auth_id = auth.uid())
  )
);

DROP POLICY IF EXISTS "board_photos_update_organizer" ON storage.objects;
CREATE POLICY "board_photos_update_organizer" ON storage.objects FOR UPDATE USING (
  bucket_id = 'board-photos'
  AND EXISTS (
    SELECT 1 FROM public.board_posts bp
    WHERE bp.post_id = ((storage.foldername(name))[1])::uuid
      AND bp.organizer_id = (SELECT user_id FROM public.users WHERE auth_id = auth.uid())
  )
);

DROP POLICY IF EXISTS "board_photos_delete_organizer" ON storage.objects;
CREATE POLICY "board_photos_delete_organizer" ON storage.objects FOR DELETE USING (
  bucket_id = 'board-photos'
  AND EXISTS (
    SELECT 1 FROM public.board_posts bp
    WHERE bp.post_id = ((storage.foldername(name))[1])::uuid
      AND bp.organizer_id = (SELECT user_id FROM public.users WHERE auth_id = auth.uid())
  )
);

-- group-photos: パスは "{group_id}/{filename}"。オーナーのみアップロード/更新/削除可能。
-- グループ自体は誰でも一覧・検索できる仕様（groups_select_all）に合わせ、閲覧は認証済みなら誰でも可。
DROP POLICY IF EXISTS "group_photos_select" ON storage.objects;
CREATE POLICY "group_photos_select" ON storage.objects FOR SELECT USING (
  bucket_id = 'group-photos' AND auth.role() = 'authenticated'
);

DROP POLICY IF EXISTS "group_photos_insert_owner" ON storage.objects;
CREATE POLICY "group_photos_insert_owner" ON storage.objects FOR INSERT WITH CHECK (
  bucket_id = 'group-photos'
  AND EXISTS (
    SELECT 1 FROM public.groups g
    WHERE g.group_id = ((storage.foldername(name))[1])::uuid
      AND g.owner_id = (SELECT user_id FROM public.users WHERE auth_id = auth.uid())
  )
);

DROP POLICY IF EXISTS "group_photos_update_owner" ON storage.objects;
CREATE POLICY "group_photos_update_owner" ON storage.objects FOR UPDATE USING (
  bucket_id = 'group-photos'
  AND EXISTS (
    SELECT 1 FROM public.groups g
    WHERE g.group_id = ((storage.foldername(name))[1])::uuid
      AND g.owner_id = (SELECT user_id FROM public.users WHERE auth_id = auth.uid())
  )
);

DROP POLICY IF EXISTS "group_photos_delete_owner" ON storage.objects;
CREATE POLICY "group_photos_delete_owner" ON storage.objects FOR DELETE USING (
  bucket_id = 'group-photos'
  AND EXISTS (
    SELECT 1 FROM public.groups g
    WHERE g.group_id = ((storage.foldername(name))[1])::uuid
      AND g.owner_id = (SELECT user_id FROM public.users WHERE auth_id = auth.uid())
  )
);
