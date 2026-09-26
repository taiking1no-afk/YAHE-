-- ============================================================
-- 重点8テーブルのRLS自動テスト（pgTAP）
-- ------------------------------------------------------------
-- 実行方法:
--   supabase db query -f supabase/tests/rls_priority_tables.sql --linked
-- または（ローカルDBがある場合）:
--   supabase test db
--
-- 前提: migration_v1_100_enable_pgtap.sql 実行済み（pgtap拡張）。
--
-- 全体を BEGIN/ROLLBACK で囲んでいるため、フィクスチャ行は実行後に
-- 全て消え、本番データには一切影響しない。
--
-- 各アサーションの結果は一時テーブルに集約し、最後に1回のSELECTで
-- まとめて出力する（DB接続方式によってはマルチステートメント実行時に
-- 最後のSELECT結果しか表示されないため）。
--
-- 対象8テーブル: chat_messages, group_messages, user_locations,
-- privacy_zones, reports, blocks, app_notifications, user_push_tokens
-- ============================================================

BEGIN;
SET LOCAL search_path = public, extensions;

CREATE TEMP TABLE rlstest_results (n INT, line TEXT);
GRANT ALL ON rlstest_results TO authenticated;

SELECT plan(17);

-- ------------------------------------------------------------
-- フィクスチャ準備（postgresロールのまま、RLSをバイパスして作成）
-- ------------------------------------------------------------
DO $fixtures$
DECLARE
  v_auth_a UUID := gen_random_uuid();
  v_auth_b UUID := gen_random_uuid();
  v_auth_c UUID := gen_random_uuid();
  v_user_a UUID := gen_random_uuid();
  v_user_b UUID := gen_random_uuid();
  v_user_c UUID := gen_random_uuid();
  v_match_id UUID;
  v_thread_id UUID;
  v_group_id UUID;
BEGIN
  INSERT INTO auth.users (id) VALUES (v_auth_a), (v_auth_b), (v_auth_c);

  INSERT INTO public.users (user_id, auth_id, nickname)
  VALUES
    (v_user_a, v_auth_a, 'rlstest_A'),
    (v_user_b, v_auth_b, 'rlstest_B'),
    (v_user_c, v_auth_c, 'rlstest_C');

  INSERT INTO public.matches (user_a_id, user_b_id)
  VALUES (LEAST(v_user_a, v_user_b), GREATEST(v_user_a, v_user_b))
  RETURNING match_id INTO v_match_id;
  INSERT INTO public.chat_threads (match_id) VALUES (v_match_id) RETURNING thread_id INTO v_thread_id;
  INSERT INTO public.chat_messages (thread_id, sender_id, content_type, body)
  VALUES (v_thread_id, v_user_a, 'text', 'rlstest message');

  INSERT INTO public.groups (owner_id, name, join_mode)
  VALUES (v_user_a, 'rlstest group', 'open') RETURNING group_id INTO v_group_id;
  INSERT INTO public.group_memberships (group_id, user_id, status, role)
  VALUES (v_group_id, v_user_a, 'member', 'owner'), (v_group_id, v_user_b, 'member', 'member');
  INSERT INTO public.group_messages (group_id, sender_id, content_type, body)
  VALUES (v_group_id, v_user_a, 'text', 'rlstest group message');

  INSERT INTO public.user_locations (user_id, lat, lng)
  VALUES (v_user_a, 35.0, 139.0);

  INSERT INTO public.privacy_zones (user_id, lat, lng, label)
  VALUES (v_user_a, 35.1, 139.1, '自宅');

  INSERT INTO public.reports (reporter_id, target_id, target_type, category)
  VALUES (v_user_c, v_user_a, 'user', 'spam');

  INSERT INTO public.blocks (blocker_id, blocked_id)
  VALUES (v_user_a, v_user_b);

  PERFORM public.create_app_notification(v_user_a, 'match', '{}'::jsonb, v_user_b);

  INSERT INTO public.user_push_tokens (user_id, fcm_token)
  VALUES (v_user_a, 'rlstest-token');

  PERFORM set_config('rlstest.auth_a', v_auth_a::text, false);
  PERFORM set_config('rlstest.auth_b', v_auth_b::text, false);
  PERFORM set_config('rlstest.auth_c', v_auth_c::text, false);
  PERFORM set_config('rlstest.user_a', v_user_a::text, false);
  PERFORM set_config('rlstest.user_b', v_user_b::text, false);
END $fixtures$;

-- ① chat_messages
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', json_build_object('sub', current_setting('rlstest.auth_c'))::text, true);
INSERT INTO rlstest_results SELECT 1, is_empty(
  $$SELECT 1 FROM public.chat_messages WHERE body = 'rlstest message'$$,
  'chat_messages: 非当事者(C)には見えない'
);
SELECT set_config('request.jwt.claims', json_build_object('sub', current_setting('rlstest.auth_b'))::text, true);
INSERT INTO rlstest_results SELECT 2, isnt_empty(
  $$SELECT 1 FROM public.chat_messages WHERE body = 'rlstest message'$$,
  'chat_messages: 当事者(B)には見える'
);
RESET ROLE;

-- ② group_messages
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', json_build_object('sub', current_setting('rlstest.auth_c'))::text, true);
INSERT INTO rlstest_results SELECT 3, is_empty(
  $$SELECT 1 FROM public.group_messages WHERE body = 'rlstest group message'$$,
  'group_messages: 非メンバー(C)には見えない'
);
SELECT set_config('request.jwt.claims', json_build_object('sub', current_setting('rlstest.auth_b'))::text, true);
INSERT INTO rlstest_results SELECT 4, isnt_empty(
  $$SELECT 1 FROM public.group_messages WHERE body = 'rlstest group message'$$,
  'group_messages: メンバー(B)には見える'
);
RESET ROLE;

-- ③ user_locations
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', json_build_object('sub', current_setting('rlstest.auth_b'))::text, true);
INSERT INTO rlstest_results SELECT 5, is_empty(
  $$SELECT 1 FROM public.user_locations WHERE lat = 35.0 AND lng = 139.0$$,
  'user_locations: 他人(B)には見えない'
);
SELECT set_config('request.jwt.claims', json_build_object('sub', current_setting('rlstest.auth_a'))::text, true);
INSERT INTO rlstest_results SELECT 6, isnt_empty(
  $$SELECT 1 FROM public.user_locations WHERE lat = 35.0 AND lng = 139.0$$,
  'user_locations: 本人(A)には見える'
);
RESET ROLE;

-- ④ privacy_zones
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', json_build_object('sub', current_setting('rlstest.auth_b'))::text, true);
INSERT INTO rlstest_results SELECT 7, is_empty(
  $$SELECT 1 FROM public.privacy_zones WHERE label = '自宅' AND lat = 35.1$$,
  'privacy_zones: 他人(B)には見えない'
);
SELECT set_config('request.jwt.claims', json_build_object('sub', current_setting('rlstest.auth_a'))::text, true);
INSERT INTO rlstest_results SELECT 8, isnt_empty(
  $$SELECT 1 FROM public.privacy_zones WHERE label = '自宅' AND lat = 35.1$$,
  'privacy_zones: 本人(A)には見える'
);
RESET ROLE;

-- ⑤ reports
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', json_build_object('sub', current_setting('rlstest.auth_a'))::text, true);
INSERT INTO rlstest_results SELECT 9, is_empty(
  $$SELECT 1 FROM public.reports WHERE target_id = current_setting('rlstest.user_a')::uuid$$,
  'reports: 通報された側(A)には自分への通報が見えない'
);
SELECT set_config('request.jwt.claims', json_build_object('sub', current_setting('rlstest.auth_c'))::text, true);
INSERT INTO rlstest_results SELECT 10, isnt_empty(
  $$SELECT 1 FROM public.reports WHERE target_id = current_setting('rlstest.user_a')::uuid$$,
  'reports: 通報した側(C)には自分の通報が見える'
);
RESET ROLE;

-- ⑥ blocks
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', json_build_object('sub', current_setting('rlstest.auth_b'))::text, true);
INSERT INTO rlstest_results SELECT 11, is_empty(
  $$SELECT 1 FROM public.blocks WHERE blocked_id = current_setting('rlstest.user_b')::uuid$$,
  'blocks: ブロックされた側(B)には行が見えない（blocks_ownの制約通り）'
);
SELECT set_config('request.jwt.claims', json_build_object('sub', current_setting('rlstest.auth_a'))::text, true);
INSERT INTO rlstest_results SELECT 12, isnt_empty(
  $$SELECT 1 FROM public.blocks WHERE blocked_id = current_setting('rlstest.user_b')::uuid$$,
  'blocks: ブロックした側(A)には自分が作成した行が見える'
);
RESET ROLE;

-- ⑦ app_notifications
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', json_build_object('sub', current_setting('rlstest.auth_b'))::text, true);
INSERT INTO rlstest_results SELECT 13, is_empty(
  $$SELECT 1 FROM public.app_notifications WHERE user_id = current_setting('rlstest.user_a')::uuid$$,
  'app_notifications: 他人(B)には見えない'
);
SELECT set_config('request.jwt.claims', json_build_object('sub', current_setting('rlstest.auth_a'))::text, true);
INSERT INTO rlstest_results SELECT 14, isnt_empty(
  $$SELECT 1 FROM public.app_notifications WHERE user_id = current_setting('rlstest.user_a')::uuid$$,
  'app_notifications: 本人(A)には見える'
);
RESET ROLE;

-- ⑧ user_push_tokens
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', json_build_object('sub', current_setting('rlstest.auth_b'))::text, true);
INSERT INTO rlstest_results SELECT 15, is_empty(
  $$SELECT 1 FROM public.user_push_tokens WHERE fcm_token = 'rlstest-token'$$,
  'user_push_tokens: 他人(B)には見えない'
);
SELECT set_config('request.jwt.claims', json_build_object('sub', current_setting('rlstest.auth_a'))::text, true);
INSERT INTO rlstest_results SELECT 16, isnt_empty(
  $$SELECT 1 FROM public.user_push_tokens WHERE fcm_token = 'rlstest-token'$$,
  'user_push_tokens: 本人(A)には見える'
);
RESET ROLE;

-- ⑨ can_view_user(): Phase5回帰確認（ブロックした側からは不可視）
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', json_build_object('sub', current_setting('rlstest.auth_a'))::text, true);
INSERT INTO rlstest_results SELECT 17, is(
  (SELECT public.can_view_user(current_setting('rlstest.user_b')::uuid))::text,
  'false',
  'can_view_user: ブロックした側(A)からブロック対象(B)は不可視'
);
RESET ROLE;

INSERT INTO rlstest_results SELECT 999, string_agg(t.line, E'\n') FROM finish() AS t(line);

SELECT line FROM rlstest_results ORDER BY n;

ROLLBACK;
