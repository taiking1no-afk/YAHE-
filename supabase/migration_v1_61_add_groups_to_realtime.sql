-- ============================================================
-- Migration v1.61 : groupsテーブルをRealtime配信対象に追加
-- Supabase SQL Editor で実行してください。
-- ------------------------------------------------------------
-- 目的:
--   global_realtime_providers.dart の groupRealtimeProvider で
--   groups テーブルの変更(アイコン・名前編集など)を購読するコードを
--   追加したが、肝心の supabase_realtime パブリケーションに groups
--   テーブル自体が入っておらず、購読が何も拾えていなかった
--   （エラーも出ず静かに何も起きない）。
--
--   何度実行しても安全（冪等）。
-- ============================================================

DO $realtime_setup$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime' AND tablename = 'groups'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.groups;
  END IF;
END $realtime_setup$;
