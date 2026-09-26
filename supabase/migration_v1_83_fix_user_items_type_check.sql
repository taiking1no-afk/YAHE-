-- ============================================================
-- Migration v1.83 : user_items のCHECK制約にgear_plus_24hが含まれていない
-- 致命的なバグを修正
-- Supabase SQL Editor で実行してください。
-- ------------------------------------------------------------
-- 背景: migration_v1_27はuser_itemsを`CREATE TABLE IF NOT EXISTS`で作成し、
--   その定義には gear_plus_24h を含む正しいCHECK制約
--   (user_items_type_check) が書かれていた。しかし実際の本番テーブルは
--   それより前に別経路（SQL Editorでの直接作成など、バージョン管理された
--   migrationファイルの外）で既に作られており、item_typeの列挙に
--   gear_plus_24h を含まない古い制約(user_items_item_type_check)のまま
--   だった。IF NOT EXISTSのため、v1_27のCREATE TABLEは無言でno-opになり、
--   この食い違いに誰も気づかないまま残っていた。
--
--   実害: 24時間ギア+ (¥300) をストア・プランどちらの購入導線から買っても、
--   grant_user_items() が INSERT に失敗し例外を投げるため、決済は成立
--   するのにアイテムは一切付与されない状態だった（本番で一度も正常に
--   動作したことがない可能性が高い）。
--
--   何度実行しても安全（冪等）。
-- ============================================================

DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.user_items'::regclass
      AND conname = 'user_items_item_type_check'
  ) THEN
    ALTER TABLE public.user_items DROP CONSTRAINT user_items_item_type_check;
  END IF;
END $$;

ALTER TABLE public.user_items DROP CONSTRAINT IF EXISTS user_items_type_check;
ALTER TABLE public.user_items ADD CONSTRAINT user_items_type_check CHECK (
  item_type IN ('nitro', 'shibu', 'super_nitro', 'geki_shibu', 'gear_plus_24h')
);
