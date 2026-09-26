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

-- 7) v1.28: 課金 RPC / debug seed / fulfill の権限
SELECT
  p.proname,
  has_function_privilege('authenticated', p.oid, 'EXECUTE') AS auth_can_exec,
  has_function_privilege('service_role', p.oid, 'EXECUTE') AS service_can_exec
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname IN (
    'sync_subscription_plan',
    'grant_gear_plus',
    'debug_seed_encounters',
    'fulfill_consumable_purchase',
    'activate_timed_item',
    'send_like'
  )
ORDER BY p.proname;
-- 期待:
--   sync_subscription_plan / grant_gear_plus / debug_seed_encounters / fulfill_consumable_purchase
--     → auth_can_exec = false, service_can_exec = true
--   activate_timed_item / send_like → auth_can_exec = true

-- 8) likes 一意制約（相手ユーザー単位）
SELECT conname, pg_get_constraintdef(oid)
FROM pg_constraint
WHERE conrelid = 'public.likes'::regclass
  AND conname = 'likes_unique_pair';
-- 期待: UNIQUE (from_user_id, to_user_id)
