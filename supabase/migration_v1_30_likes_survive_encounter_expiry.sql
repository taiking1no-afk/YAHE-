-- ============================================================
-- v1.30: いいねが「すれ違いの期限切れ」で消えてしまう不具合の修正
-- ------------------------------------------------------------
-- 背景:
--   likes.encounter_id は encounters(encounter_id) への
--   ON DELETE CASCADE になっている。一方、pg_cron の
--   'delete-expired-encounters' ジョブ（毎時0分）が
--   `DELETE FROM encounters WHERE expires_at < now()` を実行しており、
--   すれ違い自体は無料24h/有料7dで消える仕様どおり削除される。
--   このとき、そのすれ違いから生まれた「いいねした/された」の
--   likes 行までCASCADEで巻き添え削除されていた
--   （likes自体には元々、時間経過で消す仕様は無い）。
--
-- 方針:
--   likes.encounter_id の NOT NULL / FK は変えない
--   （send_like() が encounters の実在チェックに使っているため）。
--   代わりに cron の削除条件を変更し、「いいねが1件でも紐づいている
--   encounters」は期限切れでも削除対象から除外する。
--   ホームのタイムライン表示は fetchEncounters() 側の
--   `expires_at > now()` フィルタで従来どおり非表示になるため、
--   表示上の「すれ違いは時間で消える」という仕様には影響しない。
-- ============================================================

DO $cron_setup$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'pg_cron') THEN
    IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'delete-expired-encounters') THEN
      PERFORM cron.unschedule('delete-expired-encounters');
    END IF;
    PERFORM cron.schedule(
      'delete-expired-encounters', '0 * * * *',
      $job$
      DELETE FROM public.encounters e
      WHERE e.expires_at < now()
        AND NOT EXISTS (
          SELECT 1 FROM public.likes l WHERE l.encounter_id = e.encounter_id
        )
      $job$
    );
  END IF;
END;
$cron_setup$;
