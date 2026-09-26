-- ============================================================
-- Migration v1.55 : YAHE・いいね・マッチ・グループ・掲示板をRealtime配信対象に追加
-- Supabase SQL Editor で実行してください。
-- ------------------------------------------------------------
-- 目的:
--   これまで chat_messages / group_messages / app_notifications のみ
--   Realtime配信対象だったため、すれ違い・いいね・マッチ・グループ・掲示板は
--   タブ切替や手動更新をしないと反映されなかった。該当テーブルを
--   supabase_realtime パブリケーションに追加し、クライアント側のRealtime
--   購読（global_realtime_providers.dart）で拾えるようにする。
--
--   各テーブルはRLSが有効なため、購読しても閲覧権限のある行の変更のみ届く。
--
--   何度実行しても安全（冪等）。
-- ============================================================

DO $realtime_setup$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime' AND tablename = 'encounters'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.encounters;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime' AND tablename = 'matches'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.matches;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime' AND tablename = 'likes'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.likes;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime' AND tablename = 'board_posts'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.board_posts;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime' AND tablename = 'board_participations'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.board_participations;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime' AND tablename = 'group_memberships'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.group_memberships;
  END IF;
END $realtime_setup$;
