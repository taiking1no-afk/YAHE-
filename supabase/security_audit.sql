-- ============================================================
-- YAHE リリース前セキュリティ監査クエリ
-- Supabase SQL Editor で実行し、結果を確認してください
-- ============================================================

-- 1) 危険な RLS ポリシーが残っていないか
SELECT tablename, policyname, cmd, qual, with_check
FROM pg_policies
WHERE schemaname = 'public'
  AND (
    policyname IN (
      'locations_select_authenticated',
      'users_select_public',
      'vehicles_select_others',
      'encounters_insert_own'
    )
    OR (tablename = 'user_locations' AND cmd = 'SELECT' AND policyname <> 'locations_select_own')
  )
ORDER BY tablename, policyname;

-- 2) 必須セキュリティ関数の存在確認
SELECT proname
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND proname IN (
    'nearby_user_ids',
    'can_view_user',
    'register_encounter',
    'debug_seed_encounters'
  )
ORDER BY proname;

-- 3) Storage バケットが非公開か
SELECT id, public
FROM storage.buckets
WHERE id IN ('profile-photos', 'vehicle-photos');

-- 4) user_locations の古い行が溜まっていないか（TTL 稼働確認）
SELECT
  COUNT(*) AS total_rows,
  COUNT(*) FILTER (WHERE updated_at < now() - interval '30 seconds') AS stale_rows
FROM public.user_locations;

-- 5) pg_cron ジョブ（TTL / encounters 削除）
SELECT jobname, schedule, command
FROM cron.job
WHERE jobname IN ('delete-stale-user-locations', 'delete-expired-encounters')
ORDER BY jobname;

-- 6) users 閲覧ポリシーが関係者限定か
SELECT policyname, cmd
FROM pg_policies
WHERE schemaname = 'public'
  AND tablename = 'users'
  AND cmd = 'SELECT';

-- 期待結果:
--   users_select_related のみ（users_select_public / users_select_authenticated は無い）
