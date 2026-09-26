-- ============================================================
-- v1.107 メッセージ送信の冪等キー(client_message_id)の回帰テスト
-- 実行方法: supabase db query -f supabase/tests/message_idempotency.sql --linked
-- BEGIN/ROLLBACKで囲んでいるため本番データには影響しない。
-- ============================================================

BEGIN;
SET LOCAL search_path = public, extensions;

CREATE TEMP TABLE idem_results (n INT, line TEXT);
GRANT ALL ON idem_results TO authenticated;

SELECT plan(5);

DO $fixtures$
DECLARE
  v_auth_a UUID := gen_random_uuid();
  v_auth_b UUID := gen_random_uuid();
  v_user_a UUID := gen_random_uuid();
  v_user_b UUID := gen_random_uuid();
  v_group_id UUID;
  v_client_msg_id UUID := gen_random_uuid();
  v_client_group_msg_id UUID := gen_random_uuid();
BEGIN
  INSERT INTO auth.users (id) VALUES (v_auth_a), (v_auth_b);
  INSERT INTO public.users (user_id, auth_id, nickname, birth_date)
  VALUES
    (v_user_a, v_auth_a, 'idem_A', '2000-01-01'),
    (v_user_b, v_auth_b, 'idem_B', '2000-01-01');

  INSERT INTO public.vehicles (user_id, vehicle_type, maker, model, is_active)
  VALUES (v_user_a, 'car', 'Test', 'A', true), (v_user_b, 'car', 'Test', 'B', true);

  INSERT INTO public.groups (owner_id, name, join_mode)
  VALUES (v_user_a, 'idem group', 'open') RETURNING group_id INTO v_group_id;
  INSERT INTO public.group_memberships (group_id, user_id, status, role)
  VALUES (v_group_id, v_user_a, 'member', 'owner'), (v_group_id, v_user_b, 'member', 'member');

  PERFORM set_config('idem.auth_a', v_auth_a::text, false);
  PERFORM set_config('idem.auth_b', v_auth_b::text, false);
  PERFORM set_config('idem.user_a', v_user_a::text, false);
  PERFORM set_config('idem.user_b', v_user_b::text, false);
  PERFORM set_config('idem.group_id', v_group_id::text, false);
  PERFORM set_config('idem.client_msg_id', v_client_msg_id::text, false);
  PERFORM set_config('idem.client_group_msg_id', v_client_group_msg_id::text, false);
END $fixtures$;

DO $encounter$
DECLARE
  v_encounter_id UUID;
BEGIN
  INSERT INTO public.encounters (user_a_id, user_b_id, expires_at)
  VALUES (
    LEAST(current_setting('idem.user_a')::uuid, current_setting('idem.user_b')::uuid),
    GREATEST(current_setting('idem.user_a')::uuid, current_setting('idem.user_b')::uuid),
    now() + interval '1 day'
  ) RETURNING encounter_id INTO v_encounter_id;
  PERFORM set_config('idem.encounter_id', v_encounter_id::text, false);
END $encounter$;

-- マッチ成立
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', json_build_object('sub', current_setting('idem.auth_a'))::text, true);
SELECT public.send_like(current_setting('idem.user_a')::uuid, current_setting('idem.user_b')::uuid, current_setting('idem.encounter_id')::uuid);
SELECT set_config('request.jwt.claims', json_build_object('sub', current_setting('idem.auth_b'))::text, true);
SELECT public.send_like(current_setting('idem.user_b')::uuid, current_setting('idem.user_a')::uuid, current_setting('idem.encounter_id')::uuid);
RESET ROLE;

DO $get_match$
DECLARE v_match_id UUID;
BEGIN
  SELECT match_id INTO v_match_id FROM public.matches
  WHERE user_a_id = LEAST(current_setting('idem.user_a')::uuid, current_setting('idem.user_b')::uuid)
    AND user_b_id = GREATEST(current_setting('idem.user_a')::uuid, current_setting('idem.user_b')::uuid);
  PERFORM set_config('idem.match_id', v_match_id::text, false);
END $get_match$;

-- ① 同じclient_message_idで2回送信 -> 1回目は成功しmessage_idを返す
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', json_build_object('sub', current_setting('idem.auth_a'))::text, true);
DO $$
DECLARE v_result jsonb;
BEGIN
  v_result := public.send_chat_message(
    current_setting('idem.match_id')::uuid, 'text', 'hello idempotent',
    NULL, NULL, current_setting('idem.client_msg_id')::uuid
  );
  PERFORM set_config('idem.first_message_id', v_result->>'message_id', false);
END $$;
RESET ROLE;

-- ② 同じclient_message_idで再送 -> 新規行を作らず同じmessage_idを返す
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', json_build_object('sub', current_setting('idem.auth_a'))::text, true);
DO $$
DECLARE v_result jsonb;
BEGIN
  v_result := public.send_chat_message(
    current_setting('idem.match_id')::uuid, 'text', 'hello idempotent (retry)',
    NULL, NULL, current_setting('idem.client_msg_id')::uuid
  );
  PERFORM set_config('idem.second_message_id', v_result->>'message_id', false);
END $$;
RESET ROLE;

INSERT INTO idem_results SELECT 1, is(
  current_setting('idem.second_message_id'),
  current_setting('idem.first_message_id'),
  '同じclient_message_idで再送すると同じmessage_idが返る（新規行を作らない）'
);

INSERT INTO idem_results SELECT 2, is(
  (SELECT count(*) FROM public.chat_messages WHERE thread_id = (
    SELECT thread_id FROM public.chat_threads WHERE match_id = current_setting('idem.match_id')::uuid
  ))::int,
  1,
  '同じclient_message_idの再送ではchat_messagesの行が増えない'
);

-- ③ client_message_idを指定しない従来通りの送信は引き続き正常に複数行作れる
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', json_build_object('sub', current_setting('idem.auth_a'))::text, true);
SELECT public.send_chat_message(current_setting('idem.match_id')::uuid, 'text', 'no idempotency key');
RESET ROLE;

INSERT INTO idem_results SELECT 3, is(
  (SELECT count(*) FROM public.chat_messages WHERE thread_id = (
    SELECT thread_id FROM public.chat_threads WHERE match_id = current_setting('idem.match_id')::uuid
  ))::int,
  2,
  'client_message_id無しの通常送信は引き続き新規行を作る'
);

-- ④ グループメッセージも同様に冪等
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', json_build_object('sub', current_setting('idem.auth_a'))::text, true);
DO $$
DECLARE v_id1 UUID; v_id2 UUID;
BEGIN
  v_id1 := public.send_group_message(current_setting('idem.group_id')::uuid, 'text', 'group hello',
    NULL, NULL, current_setting('idem.client_group_msg_id')::uuid);
  v_id2 := public.send_group_message(current_setting('idem.group_id')::uuid, 'text', 'group hello (retry)',
    NULL, NULL, current_setting('idem.client_group_msg_id')::uuid);
  PERFORM set_config('idem.group_msg_same', (v_id1 = v_id2)::text, false);
END $$;
RESET ROLE;

INSERT INTO idem_results SELECT 4, ok(
  current_setting('idem.group_msg_same')::boolean,
  'グループメッセージも同じclient_message_idの再送で同じmessage_idを返す'
);

INSERT INTO idem_results SELECT 5, is(
  (SELECT count(*) FROM public.group_messages WHERE group_id = current_setting('idem.group_id')::uuid)::int,
  1,
  'グループメッセージも再送でgroup_messagesの行が増えない'
);

INSERT INTO idem_results SELECT 999, string_agg(t.line, E'\n') FROM finish() AS t(line);

SELECT line FROM idem_results ORDER BY n;

ROLLBACK;
