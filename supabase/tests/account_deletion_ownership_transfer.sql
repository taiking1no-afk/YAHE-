-- ============================================================
-- v1.106 prepare_account_deletion() の回帰テスト
-- 実行方法: supabase db query -f supabase/tests/account_deletion_ownership_transfer.sql --linked
-- BEGIN/ROLLBACKで囲んでいるため本番データには影響しない。
-- ============================================================

BEGIN;
SET LOCAL search_path = public, extensions;

CREATE TEMP TABLE delacct_results (n INT, line TEXT);
GRANT ALL ON delacct_results TO authenticated;

SELECT plan(6);

DO $fixtures$
DECLARE
  v_auth_a UUID := gen_random_uuid();
  v_auth_b UUID := gen_random_uuid();
  v_user_a UUID := gen_random_uuid();
  v_user_b UUID := gen_random_uuid();
  v_group_id UUID;
  v_post_id UUID;
BEGIN
  INSERT INTO auth.users (id) VALUES (v_auth_a), (v_auth_b);
  INSERT INTO public.users (user_id, auth_id, nickname, birth_date)
  VALUES
    (v_user_a, v_auth_a, 'delacct_A', '2000-01-01'),
    (v_user_b, v_auth_b, 'delacct_B', '2000-01-01');

  -- Aがオーナーのグループ、Bがメンバーとして参加
  INSERT INTO public.groups (owner_id, name, join_mode)
  VALUES (v_user_a, 'delacct group', 'open') RETURNING group_id INTO v_group_id;
  INSERT INTO public.group_memberships (group_id, user_id, status, role)
  VALUES (v_group_id, v_user_a, 'member', 'owner'), (v_group_id, v_user_b, 'member', 'member');

  -- Aが主催のイベント、Bが参加(joined)
  INSERT INTO public.board_posts (organizer_id, post_type, title, visibility)
  VALUES (v_user_a, 'event', 'delacct event', 'open') RETURNING post_id INTO v_post_id;
  INSERT INTO public.board_participations (post_id, user_id, status)
  VALUES (v_post_id, v_user_a, 'joined'), (v_post_id, v_user_b, 'joined');

  PERFORM set_config('delacct.auth_a', v_auth_a::text, false);
  PERFORM set_config('delacct.user_a', v_user_a::text, false);
  PERFORM set_config('delacct.user_b', v_user_b::text, false);
  PERFORM set_config('delacct.group_id', v_group_id::text, false);
  PERFORM set_config('delacct.post_id', v_post_id::text, false);
END $fixtures$;

-- Aの視点で prepare_account_deletion() を実行(実際の退会フローが呼ぶのと同じ)
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', json_build_object('sub', current_setting('delacct.auth_a'))::text, true);
SELECT public.prepare_account_deletion();
RESET ROLE;

-- ① グループのオーナーがBに移譲されている
INSERT INTO delacct_results SELECT 1, is(
  (SELECT owner_id FROM public.groups WHERE group_id = current_setting('delacct.group_id')::uuid)::text,
  current_setting('delacct.user_b'),
  'グループオーナーが他メンバーへ自動移譲される'
);

-- ② Bのgroup_membershipsのroleがownerに更新されている
INSERT INTO delacct_results SELECT 2, is(
  (SELECT role FROM public.group_memberships WHERE group_id = current_setting('delacct.group_id')::uuid AND user_id = current_setting('delacct.user_b')::uuid),
  'owner',
  '新オーナーのroleがownerに更新される'
);

-- ③ イベントの主催者がBに移譲されている
INSERT INTO delacct_results SELECT 3, is(
  (SELECT organizer_id FROM public.board_posts WHERE post_id = current_setting('delacct.post_id')::uuid)::text,
  current_setting('delacct.user_b'),
  'イベント主催者が他の参加者へ自動移譲される'
);

-- ここでAを実際に削除(退会) -> ON DELETE CASCADEが発火する
DELETE FROM auth.users WHERE id = current_setting('delacct.auth_a')::uuid;

-- ④ グループ自体は消えずに残っている(Bのものとして)
INSERT INTO delacct_results SELECT 4, ok(
  EXISTS(SELECT 1 FROM public.groups WHERE group_id = current_setting('delacct.group_id')::uuid),
  '主催者(旧オーナー)退会後もグループは削除されず残る'
);

-- ⑤ Bのgroup_membershipsも残っている(巻き添え削除されていない)
INSERT INTO delacct_results SELECT 5, ok(
  EXISTS(SELECT 1 FROM public.group_memberships WHERE group_id = current_setting('delacct.group_id')::uuid AND user_id = current_setting('delacct.user_b')::uuid),
  '退会後もBのグループ参加履歴が残る'
);

-- ⑥ イベント(board_posts)自体も残っている
INSERT INTO delacct_results SELECT 6, ok(
  EXISTS(SELECT 1 FROM public.board_posts WHERE post_id = current_setting('delacct.post_id')::uuid),
  '主催者退会後もイベント投稿は削除されず残る'
);

INSERT INTO delacct_results SELECT 999, string_agg(t.line, E'\n') FROM finish() AS t(line);

SELECT line FROM delacct_results ORDER BY n;

ROLLBACK;
