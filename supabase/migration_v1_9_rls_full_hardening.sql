-- ============================================================
-- Migration v1.9 : RLS 全監査 & 残存リスクの排除
-- 前提: v1.8 (security hardening) 実行済み
-- 目的:
--   1) vehicles の総取り(スクレイピング)防止
--   2) matches / users の DELETE 不可バグ修正（RLS不足）
--   3) fcm_token を専用テーブルへ分離（プッシュトークン漏洩防止）
--   4) today_like_counts ビューを呼び出し元権限で評価（他人のいいね数を見せない）
--   5) Storage バケットの書き込みをログインユーザー限定に
-- ※ 何度実行しても安全な冪等スクリプト
-- ============================================================

-- ------------------------------------------------------------
-- 1) VEHICLES: 他人の車両を無条件に全件閲覧できる穴を塞ぐ
--    閲覧できるのは「自分の車両」または
--    「すれ違い(encounters)/マッチ(matches)で関係のある相手の車両」のみ
-- ------------------------------------------------------------
DROP POLICY IF EXISTS "vehicles_select_others" ON public.vehicles;
DROP POLICY IF EXISTS "vehicles_select_related" ON public.vehicles;

CREATE POLICY "vehicles_select_related" ON public.vehicles
FOR SELECT USING (
  -- 自分の車両
  user_id IN (SELECT user_id FROM public.users WHERE auth_id = auth.uid())
  -- すれ違い関係にある相手の車両
  OR EXISTS (
    SELECT 1
    FROM public.encounters e
    JOIN public.users me ON me.auth_id = auth.uid()
    WHERE (e.user_a_id = vehicles.user_id AND e.user_b_id = me.user_id)
       OR (e.user_b_id = vehicles.user_id AND e.user_a_id = me.user_id)
  )
  -- マッチ関係にある相手の車両（すれ違い期限切れ後も閲覧可）
  OR EXISTS (
    SELECT 1
    FROM public.matches m
    JOIN public.users me ON me.auth_id = auth.uid()
    WHERE (m.user_a_id = vehicles.user_id AND m.user_b_id = me.user_id)
       OR (m.user_b_id = vehicles.user_id AND m.user_a_id = me.user_id)
  )
);

-- ------------------------------------------------------------
-- 2) MATCHES: 自分が関係するマッチの削除(マッチ解除)を許可
--    （これまで SELECT ポリシーのみで DELETE が RLS で拒否されていた）
-- ------------------------------------------------------------
DROP POLICY IF EXISTS "matches_delete_own" ON public.matches;
CREATE POLICY "matches_delete_own" ON public.matches
FOR DELETE USING (
  user_a_id IN (SELECT user_id FROM public.users WHERE auth_id = auth.uid())
  OR user_b_id IN (SELECT user_id FROM public.users WHERE auth_id = auth.uid())
);

-- ------------------------------------------------------------
-- 2b) USERS: 自分のアカウント削除(退会)を許可
--    （DELETE ポリシー不足で退会処理が RLS に阻まれていた）
-- ------------------------------------------------------------
DROP POLICY IF EXISTS "users_delete_own" ON public.users;
CREATE POLICY "users_delete_own" ON public.users
FOR DELETE USING (auth.uid() = auth_id);

-- ------------------------------------------------------------
-- 3) FCM トークンを専用テーブルへ分離
--    users.fcm_token は認証ユーザーから読めてしまうため、本人のみ読める
--    別テーブルへ移動。サーバー(service_role)はRLSを無視して読めるので
--    プッシュ送信は引き続き可能。
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.user_push_tokens (
  user_id    UUID PRIMARY KEY REFERENCES public.users(user_id) ON DELETE CASCADE,
  fcm_token  TEXT,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE public.user_push_tokens ENABLE ROW LEVEL SECURITY;

-- 既存の users.fcm_token を移行（カラムが存在する場合のみ）
DO $migrate_fcm$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'users' AND column_name = 'fcm_token'
  ) THEN
    INSERT INTO public.user_push_tokens (user_id, fcm_token)
    SELECT user_id, fcm_token
    FROM public.users
    WHERE fcm_token IS NOT NULL
    ON CONFLICT (user_id) DO UPDATE SET fcm_token = EXCLUDED.fcm_token;

    ALTER TABLE public.users DROP COLUMN fcm_token;
  END IF;
END $migrate_fcm$;

-- 本人のみ自分のトークンを読み書きできる（他人からは一切見えない）
DROP POLICY IF EXISTS "push_tokens_select_own" ON public.user_push_tokens;
CREATE POLICY "push_tokens_select_own" ON public.user_push_tokens
FOR SELECT USING (
  user_id IN (SELECT user_id FROM public.users WHERE auth_id = auth.uid())
);

DROP POLICY IF EXISTS "push_tokens_insert_own" ON public.user_push_tokens;
CREATE POLICY "push_tokens_insert_own" ON public.user_push_tokens
FOR INSERT WITH CHECK (
  user_id IN (SELECT user_id FROM public.users WHERE auth_id = auth.uid())
);

DROP POLICY IF EXISTS "push_tokens_update_own" ON public.user_push_tokens;
CREATE POLICY "push_tokens_update_own" ON public.user_push_tokens
FOR UPDATE USING (
  user_id IN (SELECT user_id FROM public.users WHERE auth_id = auth.uid())
);

DROP POLICY IF EXISTS "push_tokens_delete_own" ON public.user_push_tokens;
CREATE POLICY "push_tokens_delete_own" ON public.user_push_tokens
FOR DELETE USING (
  user_id IN (SELECT user_id FROM public.users WHERE auth_id = auth.uid())
);

-- ------------------------------------------------------------
-- 4) today_like_counts ビュー: 呼び出し元の権限(RLS)で評価させ、
--    他人のいいね数が見えないようにする。
--    send_like() は SECURITY DEFINER のため内部では全件参照でき、
--    1日制限ロジックは従来どおり動作する。
-- ------------------------------------------------------------
ALTER VIEW public.today_like_counts SET (security_invoker = true);

-- ------------------------------------------------------------
-- 5) Storage バケットの書き込みをログインユーザー限定に。
--    読み取りは公開URL表示のため public のまま（写真は共有前提）。
--    匿名ユーザーによるアップロード/改ざん/削除を禁止する。
-- ------------------------------------------------------------
DO $storage_rls$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = 'storage' AND table_name = 'objects'
  ) THEN
    -- 認証ユーザーのみアップロード可
    DROP POLICY IF EXISTS "yaeh_storage_insert_auth" ON storage.objects;
    CREATE POLICY "yaeh_storage_insert_auth" ON storage.objects
      FOR INSERT TO authenticated
      WITH CHECK (bucket_id IN ('profile-photos', 'vehicle-photos'));

    -- 認証ユーザーのみ更新可
    DROP POLICY IF EXISTS "yaeh_storage_update_auth" ON storage.objects;
    CREATE POLICY "yaeh_storage_update_auth" ON storage.objects
      FOR UPDATE TO authenticated
      USING (bucket_id IN ('profile-photos', 'vehicle-photos'));

    -- 認証ユーザーのみ削除可
    DROP POLICY IF EXISTS "yaeh_storage_delete_auth" ON storage.objects;
    CREATE POLICY "yaeh_storage_delete_auth" ON storage.objects
      FOR DELETE TO authenticated
      USING (bucket_id IN ('profile-photos', 'vehicle-photos'));

    -- 公開読み取り（画像表示のため）
    DROP POLICY IF EXISTS "yaeh_storage_read_public" ON storage.objects;
    CREATE POLICY "yaeh_storage_read_public" ON storage.objects
      FOR SELECT USING (bucket_id IN ('profile-photos', 'vehicle-photos'));
  END IF;
END $storage_rls$;
