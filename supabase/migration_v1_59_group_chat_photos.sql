-- ============================================================
-- Migration v1.59 : グループチャット写真送信用のStorageバケット
-- Supabase SQL Editor で実行してください。前提: v1.58実行済み。
-- ------------------------------------------------------------
-- 目的:
--   グループチャットの写真送信で既存の chat-photos バケットを流用すると、
--   そのSELECTポリシー(can_view_chat_photo)は「1:1マッチの相手」しか
--   想定しておらず、マッチしていないグループの他メンバーが写真を見られない。
--   専用バケットを新設し、「そのグループのメンバーなら閲覧可」に揃える。
--
--   パスは "{group_id}/{filename}"。
--
--   何度実行しても安全（冪等）。
-- ============================================================

INSERT INTO storage.buckets (id, name, public)
VALUES ('group-chat-photos', 'group-chat-photos', false)
ON CONFLICT (id) DO NOTHING;

DROP POLICY IF EXISTS "group_chat_photos_select_members" ON storage.objects;
CREATE POLICY "group_chat_photos_select_members" ON storage.objects FOR SELECT USING (
  bucket_id = 'group-chat-photos'
  AND EXISTS (
    SELECT 1 FROM public.group_memberships gm
    WHERE gm.group_id = ((storage.foldername(name))[1])::uuid
      AND gm.user_id = (SELECT user_id FROM public.users WHERE auth_id = auth.uid())
      AND gm.status = 'member'
  )
);

DROP POLICY IF EXISTS "group_chat_photos_insert_members" ON storage.objects;
CREATE POLICY "group_chat_photos_insert_members" ON storage.objects FOR INSERT WITH CHECK (
  bucket_id = 'group-chat-photos'
  AND EXISTS (
    SELECT 1 FROM public.group_memberships gm
    WHERE gm.group_id = ((storage.foldername(name))[1])::uuid
      AND gm.user_id = (SELECT user_id FROM public.users WHERE auth_id = auth.uid())
      AND gm.status = 'member'
  )
);
