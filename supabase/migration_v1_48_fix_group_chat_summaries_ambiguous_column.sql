-- ============================================================
-- Migration v1.48 : get_my_group_chat_summaries の "group_id is ambiguous" を修正
-- Supabase SQL Editor で実行してください。前提: v1.46（グループチャット）実行済み。
-- ------------------------------------------------------------
-- 問題:
--   RETURNS TABLE(group_id UUID, ...) で暗黙的に作られるPL/pgSQL変数 group_id と、
--   関数内のLATERALサブクエリで無条件（テーブル名なし）に参照していた
--   group_messages.group_id が名前衝突し、"column reference group_id is ambiguous"
--   (42702) でクライアント側が例外落ちしていた（ログイン直後にMainScaffoldが
--   常時マウントのIndexedStack経由でこのRPCを呼ぶため、ログイン時に赤画面が出ていた）。
--
-- 対応:
--   サブクエリのテーブルにエイリアスを付けて全列を明示的に修飾する。
--
--   何度実行しても安全（冪等）。
-- ============================================================

CREATE OR REPLACE FUNCTION public.get_my_group_chat_summaries()
RETURNS TABLE(
  group_id UUID,
  last_message_body TEXT,
  last_message_at TIMESTAMPTZ,
  unread_count BIGINT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_id UUID;
BEGIN
  SELECT user_id INTO v_caller_id FROM public.users WHERE auth_id = auth.uid();
  IF v_caller_id IS NULL THEN
    RETURN;
  END IF;

  RETURN QUERY
  SELECT
    gm.group_id,
    lm.body,
    lm.created_at,
    COUNT(unread.message_id)
  FROM public.group_memberships gm
  LEFT JOIN LATERAL (
    SELECT gmsg.body, gmsg.created_at
    FROM public.group_messages gmsg
    WHERE gmsg.group_id = gm.group_id
    ORDER BY gmsg.created_at DESC
    LIMIT 1
  ) lm ON TRUE
  LEFT JOIN public.group_message_reads gr ON gr.group_id = gm.group_id AND gr.user_id = v_caller_id
  LEFT JOIN public.group_messages unread ON unread.group_id = gm.group_id
    AND unread.sender_id <> v_caller_id
    AND unread.created_at > COALESCE(gr.last_read_at, 'epoch'::timestamptz)
  WHERE gm.user_id = v_caller_id AND gm.status = 'member'
  GROUP BY gm.group_id, lm.body, lm.created_at;
END;
$$;

REVOKE ALL ON FUNCTION public.get_my_group_chat_summaries() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_my_group_chat_summaries() TO authenticated;
