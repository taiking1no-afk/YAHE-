-- ============================================================
-- Migration v1.69 : ブロック機能の修正
-- Supabase SQL Editor で実行してください。
-- ------------------------------------------------------------
-- 現状の問題:
--   1. can_view_user() は「ブロック関係がある場合は常に非表示」という
--      ANDロジックになっており、v1.62で追加したはずの「同じグループ／
--      同じ募集への参加者同士は例外的に閲覧可能」が実質機能していない
--      （NOT EXISTS(blocks) が例外条件も含めて全体をAND修飾していた）。
--   2. ブロックリスト画面が対象ユーザーの nickname/avatar_url を
--      users テーブルへの直接SELECTで取得しており、can_view_user() が
--      ブロック関係を理由に false を返すため、ブロックした本人からも
--      常に見えず「ユーザー」というプレースホルダーしか出ない。
--      → ブロックした本人が自分のブロックリストを見るための専用RPCを追加。
--   3. board_posts はブロックによる絞り込みが一切ない
--      （ブロックした相手が作成した募集がそのまま一覧に出続ける）。
--   4. send_chat_message はブロック関係のチェックが一切ない
--      （マッチ一覧からは非表示になっていても、チャット画面が開いたまま
--      だったり直リンクされたりすると送信自体は通ってしまう）。
--
-- 方針:
--   ブロックは「相手の投稿・プロフィール・すれ違い・チャット」を隠すが、
--   「同じグループのメンバー」または「同じ募集(board_participations)の
--   参加者」同士である場合はその文脈での閲覧・コンタクトを優先する
--   （ブロック相手が作成した募集そのものは例外なく非表示のまま）。
--
--   何度実行しても安全（冪等）。
-- ============================================================

-- ① can_view_user(): グループ/募集共通参加の例外をブロック判定より優先する
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
      -- 同じグループのメンバー同士、または同じ募集への参加者同士は
      -- ブロック関係があっても例外的に閲覧・コンタクト可能にする
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
        NOT EXISTS (
          SELECT 1
          FROM public.blocks b
          JOIN public.users me ON me.auth_id = auth.uid()
          WHERE (b.blocker_id = me.user_id AND b.blocked_id = p_target_user_id)
             OR (b.blocker_id = p_target_user_id AND b.blocked_id = me.user_id)
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

-- ② ブロックした相手が主催する募集を一覧・詳細から除外する
--    （その募集への参加者同士としての閲覧例外は board_participations 側に
--     一切ブロック絞り込みが無いため従来どおり維持される＝別要件の
--     「他ユーザーが作成した募集に参加している場合は確認可能」を満たす）
DROP POLICY IF EXISTS "board_posts_select" ON public.board_posts;
CREATE POLICY "board_posts_select" ON public.board_posts FOR SELECT USING (
  NOT EXISTS (
    SELECT 1 FROM public.blocks b
    JOIN public.users me ON me.auth_id = auth.uid()
    WHERE (b.blocker_id = me.user_id AND b.blocked_id = board_posts.organizer_id)
       OR (b.blocker_id = board_posts.organizer_id AND b.blocked_id = me.user_id)
  )
  AND (
    visibility IN ('open', 'approval')
    OR organizer_id IN (SELECT user_id FROM public.users WHERE auth_id = auth.uid())
    OR public._is_board_post_participant(post_id, (SELECT user_id FROM public.users WHERE auth_id = auth.uid()))
  )
);

-- ③ ブロック関係にあるマッチ相手へのチャット送信を拒否する
--    （マッチ一覧からは既にクライアント側で非表示にしているが、
--     チャット画面を開いたままブロックされた場合の保険として追加）
CREATE OR REPLACE FUNCTION public.send_chat_message(p_match_id uuid, p_content_type text, p_body text DEFAULT NULL::text, p_photo_path text DEFAULT NULL::text, p_related_post_id uuid DEFAULT NULL::uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_caller_id UUID;
  v_a UUID;
  v_b UUID;
  v_other_id UUID;
  v_thread_id UUID;
  v_message_id UUID;
  v_word RECORD;
  v_text TEXT;
BEGIN
  SELECT user_id INTO v_caller_id FROM public.users WHERE auth_id = auth.uid();
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'unauthorized';
  END IF;

  IF p_content_type NOT IN ('text', 'photo', 'sns', 'quick_reply', 'board_invite') THEN
    RAISE EXCEPTION 'invalid content_type';
  END IF;
  IF p_content_type = 'board_invite' AND p_related_post_id IS NULL THEN
    RAISE EXCEPTION 'related_post_id required for board_invite';
  END IF;

  SELECT user_a_id, user_b_id INTO v_a, v_b FROM public.matches WHERE match_id = p_match_id;
  IF v_a IS NULL THEN
    RAISE EXCEPTION 'match not found';
  END IF;
  IF v_caller_id <> v_a AND v_caller_id <> v_b THEN
    RAISE EXCEPTION 'not a participant of this match';
  END IF;
  v_other_id := CASE WHEN v_caller_id = v_a THEN v_b ELSE v_a END;

  IF EXISTS (
    SELECT 1 FROM public.blocks
    WHERE (blocker_id = v_caller_id AND blocked_id = v_other_id)
       OR (blocker_id = v_other_id AND blocked_id = v_caller_id)
  ) THEN
    RAISE EXCEPTION 'blocked';
  END IF;

  -- NGワード検知（同期チェック。検知時は送信自体を拒否する）
  IF p_body IS NOT NULL AND p_body <> '' THEN
    v_text := lower(p_body);
    FOR v_word IN SELECT word FROM public.ng_words LOOP
      IF position(lower(v_word.word) IN v_text) > 0 THEN
        RAISE EXCEPTION 'ng_word_detected';
      END IF;
    END LOOP;
  END IF;

  -- スレッドを遅延作成
  SELECT thread_id INTO v_thread_id FROM public.chat_threads WHERE match_id = p_match_id;
  IF v_thread_id IS NULL THEN
    INSERT INTO public.chat_threads (match_id) VALUES (p_match_id)
    ON CONFLICT (match_id) DO NOTHING
    RETURNING thread_id INTO v_thread_id;

    IF v_thread_id IS NULL THEN
      SELECT thread_id INTO v_thread_id FROM public.chat_threads WHERE match_id = p_match_id;
    END IF;
  END IF;

  INSERT INTO public.chat_messages (thread_id, sender_id, content_type, body, photo_path, related_post_id)
  VALUES (v_thread_id, v_caller_id, p_content_type, p_body, p_photo_path, p_related_post_id)
  RETURNING message_id INTO v_message_id;

  PERFORM public.create_app_notification(
    v_other_id, 'chat_message',
    jsonb_build_object('match_id', p_match_id, 'thread_id', v_thread_id), v_caller_id
  );

  RETURN jsonb_build_object('success', TRUE, 'message_id', v_message_id, 'thread_id', v_thread_id);
END;
$function$;

-- ④ 自分がブロックしたユーザー一覧を、身元情報つきで取得する専用RPC。
--    can_view_user() 経由の users テーブル直接SELECTだとブロック関係
--    そのものによって弾かれてしまうため、「自分が作成したblocksの行に
--    紐づくユーザーの基本情報だけ」を返す狭いRPCとして用意する
--    （blocks_own ポリシーにより blocker_id = 自分 の行しか読めないのと
--     同じスコープなので、既存の権限モデルより広い情報開示にはならない）。
CREATE OR REPLACE FUNCTION public.get_my_blocked_users()
RETURNS TABLE (
  block_id uuid,
  blocked_id uuid,
  nickname text,
  avatar_url text,
  blocked_at timestamptz
)
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  SELECT b.block_id, b.blocked_id, u.nickname, u.avatar_url, b.created_at
  FROM public.blocks b
  JOIN public.users u ON u.user_id = b.blocked_id
  JOIN public.users me ON me.auth_id = auth.uid()
  WHERE b.blocker_id = me.user_id
  ORDER BY b.created_at DESC;
$function$;

REVOKE ALL ON FUNCTION public.get_my_blocked_users() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_my_blocked_users() TO authenticated;


-- ============================================================
-- 動作確認用クエリ（手動実行）
-- ============================================================
-- SELECT prosrc ILIKE '%group_memberships%' AND prosrc ILIKE '%board_participations%' AS has_exception FROM pg_proc WHERE proname = 'can_view_user';
-- SELECT policyname, qual FROM pg_policies WHERE tablename = 'board_posts' AND policyname = 'board_posts_select';
-- SELECT prosrc ILIKE '%blocked%' FROM pg_proc WHERE proname = 'send_chat_message';
-- SELECT * FROM public.get_my_blocked_users();
