-- ============================================================
-- Migration v1.74 : ブロックの可視性を非対称にする + 既存募集への
--                    参加者チャット自動作成の取りこぼし救済
-- Supabase SQL Editor で実行してください。前提: v1.70, v1.71, v1.73 実行済み。
-- ------------------------------------------------------------
-- 要件:
--   ブロックした側(A)からは、ブロックした相手(B)のプロフィール・
--   すれ違い記録・チャット等が引き続き非表示のまま。
--   一方、ブロックされた側(B)からは A のプロフィール等が引き続き
--   閲覧できる（「ブロックされています」と表示）。過去のチャットや
--   すれ違い記録も閲覧できる。ただしいいね・チャット送信はどちらの
--   方向からも一律禁止のまま（send_like/send_like_no_encounter/
--   send_chat_messageは既にブロックを双方向でチェック済みのため変更不要）。
--
-- 変更点:
--   1. can_view_user() / board_posts_select / groups_select_all の
--      ブロック判定を「双方向なら非表示」から「自分が相手をブロック
--      している場合のみ非表示」に変更する（非対称化）。
--   2. block_user() から「いいねの付いていないすれ違いの削除」を除去。
--      削除するとブロックされた側の閲覧記録まで消えてしまうため。
--      非表示自体は各リポジトリのクライアント側フィルタ
--      （fetchBlockedIds は blocks_own ポリシーの制約により元々
--      「自分がブロックした相手」しか返せていなかった＝既に非対称。
--      挙動は変えず、削除だけをやめる）。
--   3. 新規RPC am_i_blocked_by(p_user_id): 指定ユーザーが自分を
--      ブロックしているかどうかを判定する（blocks_ownポリシーの
--      制約でクライアントから直接は分からないため）。
--   4. 既存の募集(board_posts)でチャットがまだ無いもの(chat_group_id
--      IS NULL)に対し、参加者チャットをまとめて作成する
--      （作成者が手動作成する前に本移行が来た分の取りこぼし救済）。
--
--   何度実行しても安全（冪等）。
-- ============================================================

-- ① can_view_user(): 非対称化
CREATE OR REPLACE FUNCTION public.can_view_user(p_target_user_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  SELECT
    p_target_user_id IN (
      SELECT user_id FROM public.users WHERE auth_id = auth.uid()
    )
    OR (
      EXISTS (
        SELECT 1
        FROM public.group_memberships gm_me
        JOIN public.group_memberships gm_target
          ON gm_target.group_id = gm_me.group_id
        JOIN public.users me ON me.auth_id = auth.uid()
        WHERE gm_me.user_id = me.user_id AND gm_me.status = 'member'
          AND gm_target.user_id = p_target_user_id AND gm_target.status = 'member'
      )
      OR EXISTS (
        SELECT 1
        FROM public.board_participations bp_me
        JOIN public.board_participations bp_target
          ON bp_target.post_id = bp_me.post_id
        JOIN public.users me ON me.auth_id = auth.uid()
        WHERE bp_me.user_id = me.user_id AND bp_me.status IN ('joined', 'interested')
          AND bp_target.user_id = p_target_user_id AND bp_target.status IN ('joined', 'interested')
      )
      OR (
        -- 自分が相手をブロックしている場合のみ非表示にする
        -- （相手が自分をブロックしていても、自分からは引き続き見える）
        NOT EXISTS (
          SELECT 1
          FROM public.blocks b
          JOIN public.users me ON me.auth_id = auth.uid()
          WHERE b.blocker_id = me.user_id AND b.blocked_id = p_target_user_id
        )
        AND (
          EXISTS (
            SELECT 1
            FROM public.encounters e
            JOIN public.users me ON me.auth_id = auth.uid()
            WHERE (e.user_a_id = p_target_user_id AND e.user_b_id = me.user_id)
               OR (e.user_b_id = p_target_user_id AND e.user_a_id = me.user_id)
          )
          OR EXISTS (
            SELECT 1
            FROM public.matches m
            JOIN public.users me ON me.auth_id = auth.uid()
            WHERE (m.user_a_id = p_target_user_id AND m.user_b_id = me.user_id)
               OR (m.user_b_id = p_target_user_id AND m.user_a_id = me.user_id)
          )
          OR EXISTS (
            SELECT 1
            FROM public.likes l
            JOIN public.users me ON me.auth_id = auth.uid()
            WHERE (l.from_user_id = me.user_id AND l.to_user_id = p_target_user_id)
               OR (l.to_user_id = me.user_id AND l.from_user_id = p_target_user_id)
          )
        )
      )
    );
$function$;

-- ② board_posts_select: 非対称化（自分がブロックした相手が主催する募集のみ非表示）
DROP POLICY IF EXISTS "board_posts_select" ON public.board_posts;
CREATE POLICY "board_posts_select" ON public.board_posts FOR SELECT USING (
  NOT EXISTS (
    SELECT 1 FROM public.blocks b
    JOIN public.users me ON me.auth_id = auth.uid()
    WHERE b.blocker_id = me.user_id AND b.blocked_id = board_posts.organizer_id
  )
  AND (
    visibility IN ('open', 'approval')
    OR organizer_id IN (SELECT user_id FROM public.users WHERE auth_id = auth.uid())
    OR public._is_board_post_participant(post_id, (SELECT user_id FROM public.users WHERE auth_id = auth.uid()))
  )
);

-- ③ groups_select_all: 非対称化（自分がブロックした相手がオーナーの未参加グループのみ非表示）
DROP POLICY IF EXISTS "groups_select_all" ON public.groups;
CREATE POLICY "groups_select_all" ON public.groups FOR SELECT USING (
  auth.role() = 'authenticated'
  AND (
    public.is_member_of_group(groups.group_id)
    OR NOT EXISTS (
      SELECT 1 FROM public.blocks b
      JOIN public.users me ON me.auth_id = auth.uid()
      WHERE b.blocker_id = me.user_id AND b.blocked_id = groups.owner_id
    )
  )
);

-- ④ block_user(): すれ違い記録の削除をやめる（ブロックされた側の閲覧記録を保持するため）
CREATE OR REPLACE FUNCTION public.block_user(p_blocked_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_me uuid;
  v_post RECORD;
BEGIN
  SELECT user_id INTO v_me FROM public.users WHERE auth_id = auth.uid();
  IF v_me IS NULL OR v_me = p_blocked_id THEN
    RETURN;
  END IF;

  INSERT INTO public.blocks (blocker_id, blocked_id)
  VALUES (v_me, p_blocked_id)
  ON CONFLICT (blocker_id, blocked_id) DO NOTHING;

  -- ブロックした相手が主催する募集への自分の関わり（気になる・参加済み・
  -- 参加申請中・招待中）をすべて解除する。ブロック解除しても復元しない。
  FOR v_post IN
    SELECT bp.post_id, bp.chat_group_id
    FROM public.board_posts bp
    WHERE bp.organizer_id = p_blocked_id
  LOOP
    DELETE FROM public.board_participations
    WHERE post_id = v_post.post_id AND user_id = v_me;

    IF v_post.chat_group_id IS NOT NULL THEN
      DELETE FROM public.group_memberships
      WHERE group_id = v_post.chat_group_id AND user_id = v_me AND role <> 'owner';
    END IF;
  END LOOP;
END;
$function$;

-- ⑤ 自分が相手にブロックされているかを調べる専用RPC
--    （blocks_ownポリシーは blocker_id=自分 の行しか見せないため、
--     「相手が自分をブロックしているか」はクライアントから直接分からない）
CREATE OR REPLACE FUNCTION public.am_i_blocked_by(p_user_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  SELECT EXISTS (
    SELECT 1 FROM public.blocks b
    JOIN public.users me ON me.auth_id = auth.uid()
    WHERE b.blocker_id = p_user_id AND b.blocked_id = me.user_id
  );
$function$;

REVOKE ALL ON FUNCTION public.am_i_blocked_by(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.am_i_blocked_by(uuid) TO authenticated;

-- ⑥ 既存募集のうち参加者チャット未作成のものをまとめて作成する（取りこぼし救済）
DO $backfill$
DECLARE
  v_post RECORD;
  v_new_group_id UUID;
BEGIN
  FOR v_post IN
    SELECT post_id, organizer_id, title, scheduled_at
    FROM public.board_posts
    WHERE chat_group_id IS NULL
  LOOP
    INSERT INTO public.groups (owner_id, name, description, join_mode, expires_at)
    VALUES (
      v_post.organizer_id,
      v_post.title,
      '参加者限定の期間限定チャットです。',
      'invite_only',
      CASE WHEN v_post.scheduled_at IS NOT NULL THEN v_post.scheduled_at + INTERVAL '1 day' ELSE NOW() + INTERVAL '90 days' END
    )
    RETURNING group_id INTO v_new_group_id;

    INSERT INTO public.group_memberships (group_id, user_id, status, role)
    SELECT v_new_group_id, bp.user_id, 'member',
           CASE WHEN bp.user_id = v_post.organizer_id THEN 'owner' ELSE 'member' END
    FROM public.board_participations bp
    WHERE bp.post_id = v_post.post_id AND bp.status = 'joined';

    INSERT INTO public.group_memberships (group_id, user_id, status, role)
    VALUES (v_new_group_id, v_post.organizer_id, 'member', 'owner')
    ON CONFLICT (group_id, user_id) DO NOTHING;

    UPDATE public.board_posts SET chat_group_id = v_new_group_id WHERE post_id = v_post.post_id;
  END LOOP;
END $backfill$;


-- ============================================================
-- 動作確認用クエリ（手動実行）
-- ============================================================
-- SELECT count(*) FROM public.board_posts WHERE chat_group_id IS NULL; -- 0件になっているはず
-- SELECT has_function_privilege('authenticated', 'public.am_i_blocked_by(uuid)', 'execute') AS can_exec;
