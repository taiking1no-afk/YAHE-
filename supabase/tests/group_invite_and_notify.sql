-- ============================================================
-- v1.106 invite_to_group(承認制の抜け道封鎖) と
--        send_group_message(通知送信) の回帰テスト
-- 実行方法: supabase db query -f supabase/tests/group_invite_and_notify.sql --linked
-- BEGIN/ROLLBACKで囲んでいるため本番データには影響しない。
-- ============================================================

BEGIN;
SET LOCAL search_path = public, extensions;

CREATE TEMP TABLE ginv_results (n INT, line TEXT);
GRANT ALL ON ginv_results TO authenticated;

SELECT plan(4);

DO $fixtures$
DECLARE
  v_auth_a UUID := gen_random_uuid();
  v_auth_b UUID := gen_random_uuid();
  v_auth_c UUID := gen_random_uuid();
  v_user_a UUID := gen_random_uuid();
  v_user_b UUID := gen_random_uuid();
  v_user_c UUID := gen_random_uuid();
  v_group_id UUID;
BEGIN
  INSERT INTO auth.users (id) VALUES (v_auth_a), (v_auth_b), (v_auth_c);
  INSERT INTO public.users (user_id, auth_id, nickname, birth_date)
  VALUES
    (v_user_a, v_auth_a, 'ginv_A', '2000-01-01'),
    (v_user_b, v_auth_b, 'ginv_B', '2000-01-01'),
    (v_user_c, v_auth_c, 'ginv_C', '2000-01-01');

  -- Aがオーナーの承認制(approval)グループ、Bは一般メンバー
  INSERT INTO public.groups (owner_id, name, join_mode)
  VALUES (v_user_a, 'ginv approval group', 'approval') RETURNING group_id INTO v_group_id;
  INSERT INTO public.group_memberships (group_id, user_id, status, role)
  VALUES (v_group_id, v_user_a, 'member', 'owner'), (v_group_id, v_user_b, 'member', 'member');

  PERFORM set_config('ginv.auth_a', v_auth_a::text, false);
  PERFORM set_config('ginv.auth_b', v_auth_b::text, false);
  PERFORM set_config('ginv.user_b', v_user_b::text, false);
  PERFORM set_config('ginv.user_c', v_user_c::text, false);
  PERFORM set_config('ginv.group_id', v_group_id::text, false);
END $fixtures$;

-- ① approval制グループで、オーナーでないB(一般メンバー)がCを招待しようとすると拒否される
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', json_build_object('sub', current_setting('ginv.auth_b'))::text, true);
INSERT INTO ginv_results SELECT 1, throws_ok(
  format('SELECT public.invite_to_group(%L::uuid, %L::uuid)', current_setting('ginv.group_id'), current_setting('ginv.user_c')),
  'only the owner can invite to an approval-only group',
  '承認制グループでは一般メンバーは招待できない'
);
RESET ROLE;

-- ② オーナーA自身なら招待できる
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', json_build_object('sub', current_setting('ginv.auth_a'))::text, true);
SELECT public.invite_to_group(current_setting('ginv.group_id')::uuid, current_setting('ginv.user_c')::uuid);
RESET ROLE;
-- RLS(招待中の行は本人以外に見えない)にテスト検証自体がマスキングされないよう、
-- postgres権限に戻ってから確認する
INSERT INTO ginv_results SELECT 2, ok(
  EXISTS(SELECT 1 FROM public.group_memberships WHERE group_id = current_setting('ginv.group_id')::uuid AND user_id = current_setting('ginv.user_c')::uuid AND status = 'invited'),
  '承認制グループでもオーナー本人は招待できる'
);

-- ③ AがBのいるグループへメッセージ送信すると、B(送信者以外の全メンバー)へgroup_message通知が作られる
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', json_build_object('sub', current_setting('ginv.auth_a'))::text, true);
SELECT public.send_group_message(current_setting('ginv.group_id')::uuid, 'text', 'hello group');
RESET ROLE;

INSERT INTO ginv_results SELECT 3, ok(
  EXISTS(
    SELECT 1 FROM public.app_notifications
    WHERE user_id = current_setting('ginv.user_b')::uuid AND type = 'group_message'
  ),
  'グループメッセージ送信で送信者以外のメンバーに通知が作られる'
);

-- ④ 送信者自身には通知が作られない
INSERT INTO ginv_results SELECT 4, is(
  (SELECT count(*) FROM public.app_notifications
   WHERE related_user_id IS NOT NULL AND type = 'group_message'
     AND user_id = (SELECT owner_id FROM public.groups WHERE group_id = current_setting('ginv.group_id')::uuid))::int,
  0,
  '送信者自身には自分宛の通知が作られない'
);

INSERT INTO ginv_results SELECT 999, string_agg(t.line, E'\n') FROM finish() AS t(line);

SELECT line FROM ginv_results ORDER BY n;

ROLLBACK;
