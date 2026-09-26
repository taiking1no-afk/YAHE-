-- ============================================================
-- Migration v1.60 : group-photos RLSの列名衝突バグ修正
-- Supabase SQL Editor で実行してください。前提: v1.58実行済み。
-- ------------------------------------------------------------
-- 目的:
--   v1.58で作成した group_photos_insert_owner / update_owner / delete_owner の
--   WITH CHECK / USING 句が `storage.foldername(name)` と書かれていたが、
--   サブクエリ内で `groups g` を参照しているため、`name` が意図した
--   `storage.objects.name` ではなく `groups.name`（グループの表示名）に
--   解決されてしまっていた（groupsテーブルにも name 列があるため）。
--   結果、EXISTS句が常にfalseになり、オーナーでもアイコンを
--   アップロードできなかった（エラーも出ず静かに失敗する）。
--   board_posts・group_membershipsにはname列が無いため、同じパターンの
--   board-photos・group-chat-photosのポリシーは影響を受けていない。
--
--   `storage.foldername(objects.name)` と明示的に修飾して修正する。
--
--   何度実行しても安全（冪等）。
-- ============================================================

DROP POLICY IF EXISTS "group_photos_insert_owner" ON storage.objects;
CREATE POLICY "group_photos_insert_owner" ON storage.objects FOR INSERT WITH CHECK (
  bucket_id = 'group-photos'
  AND EXISTS (
    SELECT 1 FROM public.groups g
    WHERE g.group_id = ((storage.foldername(objects.name))[1])::uuid
      AND g.owner_id = (SELECT user_id FROM public.users WHERE auth_id = auth.uid())
  )
);

DROP POLICY IF EXISTS "group_photos_update_owner" ON storage.objects;
CREATE POLICY "group_photos_update_owner" ON storage.objects FOR UPDATE USING (
  bucket_id = 'group-photos'
  AND EXISTS (
    SELECT 1 FROM public.groups g
    WHERE g.group_id = ((storage.foldername(objects.name))[1])::uuid
      AND g.owner_id = (SELECT user_id FROM public.users WHERE auth_id = auth.uid())
  )
);

DROP POLICY IF EXISTS "group_photos_delete_owner" ON storage.objects;
CREATE POLICY "group_photos_delete_owner" ON storage.objects FOR DELETE USING (
  bucket_id = 'group-photos'
  AND EXISTS (
    SELECT 1 FROM public.groups g
    WHERE g.group_id = ((storage.foldername(objects.name))[1])::uuid
      AND g.owner_id = (SELECT user_id FROM public.users WHERE auth_id = auth.uid())
  )
);
