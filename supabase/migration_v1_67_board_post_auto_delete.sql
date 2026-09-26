-- ============================================================
-- Migration v1.67 : 終了した掲示板投稿を開催日の1ヶ月後に自動削除
-- Supabase SQL Editor で実行してください。
-- ------------------------------------------------------------
-- board_participations は ON DELETE CASCADE、board_posts.chat_group_id
-- を参照する groups への外部キーは ON DELETE SET NULL のため、
-- board_posts の削除だけで安全に片付く（migration_v1_39, v1_65）。
--
-- 何度実行しても安全（冪等）。
-- ============================================================

DO $cron_setup$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'pg_cron') THEN
    CREATE EXTENSION IF NOT EXISTS pg_cron;

    -- 終了(開催日)から1ヶ月経過した掲示板投稿を削除（毎日 15:10 UTC = 翌0:10 JST）
    IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'delete-expired-board-posts') THEN
      PERFORM cron.unschedule('delete-expired-board-posts');
    END IF;
    PERFORM cron.schedule(
      'delete-expired-board-posts', '10 15 * * *',
      $job$DELETE FROM public.board_posts WHERE scheduled_at IS NOT NULL AND scheduled_at < now() - INTERVAL '1 month'$job$
    );
  END IF;
END $cron_setup$;


-- ============================================================
-- 動作確認用クエリ（手動実行）
-- ============================================================
-- SELECT jobname, schedule, command FROM cron.job WHERE jobname = 'delete-expired-board-posts';
-- SELECT count(*) FROM public.board_posts WHERE scheduled_at IS NOT NULL AND scheduled_at < now() - INTERVAL '1 month';
