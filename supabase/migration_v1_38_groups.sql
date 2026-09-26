-- ============================================================
-- Migration v1.38 : グループ機能
-- Supabase SQL Editor で実行してください。前提: v1.34（app_notifications）実行済み。
-- ------------------------------------------------------------
-- 目的:
--   自由参加/招待制/入室許可制のグループ。誰でも一覧・検索できる。
--   ここで作る「参加/承認」のRPCパターンは、次のマイグレーション(v1.39 掲示板)
--   でほぼそのまま複製する想定。
--
--   何度実行しても安全（冪等）。
-- ============================================================

CREATE TABLE IF NOT EXISTS public.groups (
  group_id    UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  owner_id    UUID NOT NULL REFERENCES public.users(user_id) ON DELETE CASCADE,
  name        TEXT NOT NULL,
  description TEXT,
  join_mode   TEXT NOT NULL CHECK (join_mode IN ('open', 'invite_only', 'approval')),
  icon_url    TEXT,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.group_memberships (
  membership_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  group_id      UUID NOT NULL REFERENCES public.groups(group_id) ON DELETE CASCADE,
  user_id       UUID NOT NULL REFERENCES public.users(user_id) ON DELETE CASCADE,
  status        TEXT NOT NULL CHECK (status IN ('member', 'pending', 'invited')),
  role          TEXT NOT NULL DEFAULT 'member' CHECK (role IN ('owner', 'member')),
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  responded_at  TIMESTAMPTZ,
  CONSTRAINT group_memberships_unique UNIQUE (group_id, user_id)
);

CREATE INDEX IF NOT EXISTS idx_group_memberships_group ON public.group_memberships(group_id);
CREATE INDEX IF NOT EXISTS idx_group_memberships_user  ON public.group_memberships(user_id);

ALTER TABLE public.groups ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.group_memberships ENABLE ROW LEVEL SECURITY;

-- グループは誰でも一覧・検索できる（合意事項）
DROP POLICY IF EXISTS "groups_select_all" ON public.groups;
CREATE POLICY "groups_select_all" ON public.groups FOR SELECT USING (auth.role() = 'authenticated');

-- グループ自体の作成はRLS経由で許可（owner_idは自分自身のみ）。更新/削除はオーナーのみ。
DROP POLICY IF EXISTS "groups_insert_own" ON public.groups;
CREATE POLICY "groups_insert_own" ON public.groups FOR INSERT WITH CHECK (
  owner_id IN (SELECT user_id FROM public.users WHERE auth_id = auth.uid())
);
DROP POLICY IF EXISTS "groups_update_own" ON public.groups;
CREATE POLICY "groups_update_own" ON public.groups FOR UPDATE USING (
  owner_id IN (SELECT user_id FROM public.users WHERE auth_id = auth.uid())
);
DROP POLICY IF EXISTS "groups_delete_own" ON public.groups;
CREATE POLICY "groups_delete_own" ON public.groups FOR DELETE USING (
  owner_id IN (SELECT user_id FROM public.users WHERE auth_id = auth.uid())
);

-- メンバーシップ：グループメンバー本人 + 当該行の本人のみ閲覧可
DROP POLICY IF EXISTS "group_memberships_select" ON public.group_memberships;
CREATE POLICY "group_memberships_select" ON public.group_memberships FOR SELECT USING (
  user_id IN (SELECT user_id FROM public.users WHERE auth_id = auth.uid())
  OR group_id IN (
    SELECT group_id FROM public.group_memberships gm2
    WHERE gm2.user_id IN (SELECT user_id FROM public.users WHERE auth_id = auth.uid())
      AND gm2.status = 'member'
  )
);

-- ミューテーションはRPC経由のみ（クライアントからの直接書き込み禁止）
REVOKE INSERT, UPDATE, DELETE ON public.group_memberships FROM authenticated, anon;

-- ============================================================
-- RPC群
-- ============================================================

-- グループ作成
CREATE OR REPLACE FUNCTION public.create_group(
  p_name TEXT,
  p_description TEXT,
  p_join_mode TEXT,
  p_icon_url TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_id UUID;
  v_group_id  UUID;
BEGIN
  SELECT user_id INTO v_caller_id FROM public.users WHERE auth_id = auth.uid();
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'unauthorized';
  END IF;
  IF p_join_mode NOT IN ('open', 'invite_only', 'approval') THEN
    RAISE EXCEPTION 'invalid join_mode';
  END IF;
  IF p_name IS NULL OR trim(p_name) = '' THEN
    RAISE EXCEPTION 'name required';
  END IF;

  INSERT INTO public.groups (owner_id, name, description, join_mode, icon_url)
  VALUES (v_caller_id, trim(p_name), p_description, p_join_mode, p_icon_url)
  RETURNING group_id INTO v_group_id;

  INSERT INTO public.group_memberships (group_id, user_id, status, role)
  VALUES (v_group_id, v_caller_id, 'member', 'owner');

  RETURN v_group_id;
END;
$$;

REVOKE ALL ON FUNCTION public.create_group(TEXT, TEXT, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_group(TEXT, TEXT, TEXT, TEXT) TO authenticated;

-- 参加リクエスト（open→即参加 / approval→承認待ち / invite_only→拒否）
CREATE OR REPLACE FUNCTION public.request_join_group(p_group_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_id UUID;
  v_owner_id  UUID;
  v_join_mode TEXT;
  v_status    TEXT;
BEGIN
  SELECT user_id INTO v_caller_id FROM public.users WHERE auth_id = auth.uid();
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'unauthorized';
  END IF;

  SELECT owner_id, join_mode INTO v_owner_id, v_join_mode
  FROM public.groups WHERE group_id = p_group_id;
  IF v_owner_id IS NULL THEN
    RAISE EXCEPTION 'group not found';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.group_memberships
    WHERE group_id = p_group_id AND user_id = v_caller_id AND status IN ('member', 'pending')
  ) THEN
    RETURN jsonb_build_object('success', TRUE, 'status', 'already_requested');
  END IF;

  IF v_join_mode = 'invite_only' THEN
    RAISE EXCEPTION 'this group is invite-only';
  END IF;

  v_status := CASE WHEN v_join_mode = 'open' THEN 'member' ELSE 'pending' END;

  INSERT INTO public.group_memberships (group_id, user_id, status, role)
  VALUES (p_group_id, v_caller_id, v_status, 'member')
  ON CONFLICT (group_id, user_id) DO UPDATE SET status = v_status, responded_at = NULL;

  IF v_status = 'pending' THEN
    PERFORM public.create_app_notification(
      v_owner_id, 'group_join_request',
      jsonb_build_object('group_id', p_group_id), v_caller_id
    );
  END IF;

  RETURN jsonb_build_object('success', TRUE, 'status', v_status);
END;
$$;

REVOKE ALL ON FUNCTION public.request_join_group(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.request_join_group(UUID) TO authenticated;

-- 招待（オーナー/既存メンバーが招待できる）
CREATE OR REPLACE FUNCTION public.invite_to_group(p_group_id UUID, p_user_id UUID)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_id UUID;
BEGIN
  SELECT user_id INTO v_caller_id FROM public.users WHERE auth_id = auth.uid();
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'unauthorized';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.group_memberships
    WHERE group_id = p_group_id AND user_id = v_caller_id AND status = 'member'
  ) THEN
    RAISE EXCEPTION 'only members can invite';
  END IF;

  INSERT INTO public.group_memberships (group_id, user_id, status, role)
  VALUES (p_group_id, p_user_id, 'invited', 'member')
  ON CONFLICT (group_id, user_id) DO NOTHING;

  PERFORM public.create_app_notification(
    p_user_id, 'group_invite',
    jsonb_build_object('group_id', p_group_id), v_caller_id
  );
END;
$$;

REVOKE ALL ON FUNCTION public.invite_to_group(UUID, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.invite_to_group(UUID, UUID) TO authenticated;

-- 招待への応答（本人のみ）
CREATE OR REPLACE FUNCTION public.respond_to_group_invite(p_membership_id UUID, p_accept BOOLEAN)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_id UUID;
BEGIN
  SELECT user_id INTO v_caller_id FROM public.users WHERE auth_id = auth.uid();

  IF p_accept THEN
    UPDATE public.group_memberships
    SET status = 'member', responded_at = NOW()
    WHERE membership_id = p_membership_id AND user_id = v_caller_id AND status = 'invited';
  ELSE
    DELETE FROM public.group_memberships
    WHERE membership_id = p_membership_id AND user_id = v_caller_id AND status = 'invited';
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.respond_to_group_invite(UUID, BOOLEAN) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.respond_to_group_invite(UUID, BOOLEAN) TO authenticated;

-- 参加申請の承認/却下（オーナーのみ）
CREATE OR REPLACE FUNCTION public.approve_group_join_request(p_membership_id UUID, p_approve BOOLEAN)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_id UUID;
  v_group_id  UUID;
  v_owner_id  UUID;
BEGIN
  SELECT user_id INTO v_caller_id FROM public.users WHERE auth_id = auth.uid();

  SELECT group_id INTO v_group_id FROM public.group_memberships WHERE membership_id = p_membership_id;
  SELECT owner_id INTO v_owner_id FROM public.groups WHERE group_id = v_group_id;

  IF v_owner_id IS NULL OR v_owner_id <> v_caller_id THEN
    RAISE EXCEPTION 'only the group owner can approve requests';
  END IF;

  IF p_approve THEN
    UPDATE public.group_memberships
    SET status = 'member', responded_at = NOW()
    WHERE membership_id = p_membership_id AND status = 'pending';
  ELSE
    DELETE FROM public.group_memberships
    WHERE membership_id = p_membership_id AND status = 'pending';
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.approve_group_join_request(UUID, BOOLEAN) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.approve_group_join_request(UUID, BOOLEAN) TO authenticated;

-- 退会
CREATE OR REPLACE FUNCTION public.leave_group(p_group_id UUID)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_id UUID;
BEGIN
  SELECT user_id INTO v_caller_id FROM public.users WHERE auth_id = auth.uid();
  DELETE FROM public.group_memberships
  WHERE group_id = p_group_id AND user_id = v_caller_id AND role <> 'owner';
END;
$$;

REVOKE ALL ON FUNCTION public.leave_group(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.leave_group(UUID) TO authenticated;
