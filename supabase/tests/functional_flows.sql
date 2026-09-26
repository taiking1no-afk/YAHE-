-- ============================================================
-- 主要フローの機能テスト（RPCの実際の挙動を検証）
-- ------------------------------------------------------------
-- 実行方法: supabase db query -f supabase/tests/functional_flows.sql --linked
-- pgTAPのRLS可視性テスト(rls_priority_tables.sql)とは異なり、こちらは
-- RPC呼び出しの結果（成功/失敗、副作用）を検証する。
-- BEGIN/ROLLBACKで囲んでいるため本番データには影響しない。
-- ============================================================

BEGIN;
SET LOCAL search_path = public, extensions;

CREATE TEMP TABLE functest_results (n INT, line TEXT);
GRANT ALL ON functest_results TO authenticated;

SELECT plan(11);

DO $fixtures$
DECLARE
  v_auth_a UUID := gen_random_uuid();
  v_auth_b UUID := gen_random_uuid();
  v_auth_c UUID := gen_random_uuid();
  v_user_a UUID := gen_random_uuid();
  v_user_b UUID := gen_random_uuid();
  v_user_c UUID := gen_random_uuid();
  v_encounter_id UUID;
  v_group_id UUID;
BEGIN
  INSERT INTO auth.users (id) VALUES (v_auth_a), (v_auth_b), (v_auth_c);
  INSERT INTO public.users (user_id, auth_id, nickname, birth_date)
  VALUES
    (v_user_a, v_auth_a, 'functest_A', '2000-01-01'),
    (v_user_b, v_auth_b, 'functest_B', '2000-01-01'),
    (v_user_c, v_auth_c, 'functest_C', '2000-01-01');

  -- 車種登録（users_can_pass の判定に必要）
  INSERT INTO public.vehicles (user_id, vehicle_type, maker, model, is_active)
  VALUES
    (v_user_a, 'car', 'Test', 'A', true),
    (v_user_b, 'car', 'Test', 'B', true);

  INSERT INTO public.encounters (user_a_id, user_b_id, expires_at)
  VALUES (LEAST(v_user_a, v_user_b), GREATEST(v_user_a, v_user_b), now() + interval '1 day')
  RETURNING encounter_id INTO v_encounter_id;

  INSERT INTO public.groups (owner_id, name, join_mode)
  VALUES (v_user_a, 'functest group', 'open') RETURNING group_id INTO v_group_id;
  INSERT INTO public.group_memberships (group_id, user_id, status, role)
  VALUES (v_group_id, v_user_a, 'member', 'owner'), (v_group_id, v_user_b, 'member', 'member');

  PERFORM set_config('functest.auth_a', v_auth_a::text, false);
  PERFORM set_config('functest.auth_b', v_auth_b::text, false);
  PERFORM set_config('functest.auth_c', v_auth_c::text, false);
  PERFORM set_config('functest.user_a', v_user_a::text, false);
  PERFORM set_config('functest.user_b', v_user_b::text, false);
  PERFORM set_config('functest.user_c', v_user_c::text, false);
  PERFORM set_config('functest.encounter_id', v_encounter_id::text, false);
  PERFORM set_config('functest.group_id', v_group_id::text, false);
END $fixtures$;

-- ① 相互いいねでマッチ成立
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', json_build_object('sub', current_setting('functest.auth_a'))::text, true);
SELECT public.send_like(current_setting('functest.user_a')::uuid, current_setting('functest.user_b')::uuid, current_setting('functest.encounter_id')::uuid);
SELECT set_config('request.jwt.claims', json_build_object('sub', current_setting('functest.auth_b'))::text, true);
INSERT INTO functest_results SELECT 1, ok(
  (public.send_like(current_setting('functest.user_b')::uuid, current_setting('functest.user_a')::uuid, current_setting('functest.encounter_id')::uuid)->>'is_matched')::boolean,
  '相互いいねでis_matched=trueになる'
);
RESET ROLE;

DO $get_match$
DECLARE v_match_id UUID;
BEGIN
  SELECT match_id INTO v_match_id FROM public.matches
  WHERE user_a_id = LEAST(current_setting('functest.user_a')::uuid, current_setting('functest.user_b')::uuid)
    AND user_b_id = GREATEST(current_setting('functest.user_a')::uuid, current_setting('functest.user_b')::uuid);
  PERFORM set_config('functest.match_id', v_match_id::text, false);
END $get_match$;

-- ② マッチ済み・解消前はメッセージ送信できる
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', json_build_object('sub', current_setting('functest.auth_a'))::text, true);
INSERT INTO functest_results SELECT 2, ok(
  (public.send_chat_message(current_setting('functest.match_id')::uuid, 'text', 'hello before dissolve')->>'success')::boolean,
  '解消前はメッセージを送信できる'
);
RESET ROLE;

-- ③ 参加者以外はマッチを解消できない
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', json_build_object('sub', current_setting('functest.auth_c'))::text, true);
INSERT INTO functest_results SELECT 3, is(
  public.dissolve_match(current_setting('functest.match_id')::uuid)->>'error',
  'forbidden',
  '非参加者はマッチを解消できない'
);
RESET ROLE;

-- ④ 参加者本人はマッチを解消できる
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', json_build_object('sub', current_setting('functest.auth_a'))::text, true);
INSERT INTO functest_results SELECT 4, ok(
  (public.dissolve_match(current_setting('functest.match_id')::uuid)->>'success')::boolean,
  '参加者本人はマッチを解消できる'
);
RESET ROLE;

-- ⑤ 解消後は新規メッセージを送信できない
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', json_build_object('sub', current_setting('functest.auth_a'))::text, true);
INSERT INTO functest_results SELECT 5, throws_ok(
  format('SELECT public.send_chat_message(%L::uuid, %L, %L)', current_setting('functest.match_id'), 'text', 'should fail'),
  'match_dissolved',
  '解消後はメッセージ送信が拒否される'
);
RESET ROLE;

-- ⑥ 解消後も過去のメッセージ履歴は閲覧できる（Bから見て）
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', json_build_object('sub', current_setting('functest.auth_b'))::text, true);
INSERT INTO functest_results SELECT 6, isnt_empty(
  format('SELECT 1 FROM public.chat_messages WHERE body = %L', 'hello before dissolve'),
  '解消後も過去のチャット履歴は閲覧できる'
);
RESET ROLE;

-- ⑦ 解消後に再度相互いいねすると再マッチする
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', json_build_object('sub', current_setting('functest.auth_a'))::text, true);
SELECT public.send_like(current_setting('functest.user_a')::uuid, current_setting('functest.user_b')::uuid, current_setting('functest.encounter_id')::uuid);
SELECT set_config('request.jwt.claims', json_build_object('sub', current_setting('functest.auth_b'))::text, true);
INSERT INTO functest_results SELECT 7, ok(
  (public.send_like(current_setting('functest.user_b')::uuid, current_setting('functest.user_a')::uuid, current_setting('functest.encounter_id')::uuid)->>'is_matched')::boolean,
  '解消後に再度相互いいねすると再マッチする'
);
RESET ROLE;

INSERT INTO functest_results SELECT 8, is(
  (SELECT dissolved_at FROM public.matches WHERE match_id = current_setting('functest.match_id')::uuid)::text,
  NULL,
  '再マッチ後はdissolved_atがNULLに戻る'
);

-- ⑨ openグループでもオーナーは除名できない
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', json_build_object('sub', current_setting('functest.auth_b'))::text, true);
INSERT INTO functest_results SELECT 9, throws_ok(
  format('SELECT public.kick_group_member(%L::uuid, %L::uuid)', current_setting('functest.group_id'), current_setting('functest.user_a')),
  'cannot kick the owner',
  'openグループでもオーナーは除名できない'
);
RESET ROLE;

-- ⑩ 送信取り消し：スレッド参加者であっても送信者本人以外は取り消せない
-- （Cは非参加者でありRLS上メッセージが見えないため、参加者Bで検証する）
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', json_build_object('sub', current_setting('functest.auth_b'))::text, true);
INSERT INTO functest_results SELECT 10, is(
  (SELECT public.unsend_chat_message((SELECT message_id FROM public.chat_messages WHERE body = 'hello before dissolve'))->>'error'),
  'forbidden',
  '参加者であっても送信者本人以外は取り消せない'
);
RESET ROLE;

-- ⑪ 送信取り消し：本人が取り消すと本文がNULL化される
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', json_build_object('sub', current_setting('functest.auth_a'))::text, true);
SELECT public.unsend_chat_message((SELECT message_id FROM public.chat_messages WHERE body = 'hello before dissolve'));
INSERT INTO functest_results SELECT 11, is(
  (SELECT body FROM public.chat_messages WHERE deleted_at IS NOT NULL LIMIT 1),
  NULL,
  '送信者本人が取り消すと本文がNULL化される'
);
RESET ROLE;

INSERT INTO functest_results SELECT 999, string_agg(t.line, E'\n') FROM finish() AS t(line);

SELECT line FROM functest_results ORDER BY n;

ROLLBACK;
