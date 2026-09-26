-- ============================================================
-- Migration v1.98 : Storageバケットのサイズ/MIME制限
-- Supabase SQL Editor で実行してください。
-- ------------------------------------------------------------
-- 背景:
--   chat-photos, group-chat-photos, board-photos, group-photos,
--   vehicle-photos, profile-photos のいずれも file_size_limit /
--   allowed_mime_types が未設定で、Storage側でのサイズ・形式チェックが
--   一切効いていなかった。image_sanitizer.dart側で1600px・JPEG再エンコード
--   済みだが、Storageバケット自体にも上限を課して二重に防御する。
--
--   board-photos / group-photos は既にDELETEポリシー
--   (board_photos_delete_organizer / group_photos_delete_owner) が
--   存在することを確認済み。chat-photos / group-chat-photos のDELETEは
--   v1.94で追加済み。写真削除経路は既に4バケットとも揃っている。
--
--   何度実行しても安全（冪等）。
-- ============================================================

UPDATE storage.buckets
SET file_size_limit = 8388608,  -- 8MB
    allowed_mime_types = ARRAY['image/jpeg', 'image/png', 'image/webp']
WHERE id IN (
  'chat-photos', 'group-chat-photos', 'board-photos',
  'group-photos', 'vehicle-photos', 'profile-photos'
);

-- ============================================================
-- 動作確認用クエリ（手動実行）
-- ============================================================
-- SELECT id, file_size_limit, allowed_mime_types FROM storage.buckets
-- WHERE id IN ('chat-photos','group-chat-photos','board-photos','group-photos','vehicle-photos','profile-photos');
