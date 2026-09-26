-- ============================================================
-- Migration v1.73 : groups RLSの無限再帰を修正（緊急）
-- Supabase SQL Editor で実行してください。
-- ------------------------------------------------------------
-- v1.72で groups_select_all に group_memberships への EXISTS を
-- 直接埋め込んだところ、group_memberships_select 側が groups を
-- 参照しているため相互参照になり、"infinite recursion detected in
-- policy for relation groups" (42P17) でアプリが起動不能になった。
--
-- 対応: メンバーシップ判定を SECURITY DEFINER 関数に切り出す。
--   can_view_user() などと同じパターンで、関数内のクエリはRLSを
--   経由しないため相互参照が断ち切れる。
--
--   何度実行しても安全（冪等）。
-- ============================================================

CREATE OR REPLACE FUNCTION public.is_member_of_group(p_group_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  SELECT EXISTS (
    SELECT 1
    FROM public.group_memberships gm
    JOIN public.users me ON me.auth_id = auth.uid()
    WHERE gm.group_id = p_group_id AND gm.user_id = me.user_id AND gm.status = 'member'
  );
$function$;

DROP POLICY IF EXISTS "groups_select_all" ON public.groups;
CREATE POLICY "groups_select_all" ON public.groups FOR SELECT USING (
  auth.role() = 'authenticated'
  AND (
    public.is_member_of_group(groups.group_id)
    OR NOT EXISTS (
      SELECT 1 FROM public.blocks b
      JOIN public.users me ON me.auth_id = auth.uid()
      WHERE (b.blocker_id = me.user_id AND b.blocked_id = groups.owner_id)
         OR (b.blocker_id = groups.owner_id AND b.blocked_id = me.user_id)
    )
  )
);


-- ============================================================
-- 動作確認用クエリ（手動実行）
-- ============================================================
-- SELECT group_id FROM public.groups LIMIT 1; -- エラーが出ないことを確認
