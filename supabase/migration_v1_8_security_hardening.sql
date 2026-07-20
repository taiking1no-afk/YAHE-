-- ============================================================
-- Migration v1.8: セキュリティ強化（リリース前 必須）
-- Supabase SQL Editor で実行してください
--
-- 内容:
--   ① 位置情報(user_locations)の生座標を他人に読ませない
--      + 近傍判定をサーバー側RPC化（座標はサーバーから出さない）
--   ② SNSリンク(sns_links)をマッチ済みユーザーのみ閲覧可に分離
--   ③ 期限切れ encounters の自動削除
-- ============================================================


-- ============================================================
-- ① 位置情報のセキュリティ修正
-- ------------------------------------------------------------
-- 旧ポリシー:
--   - locations_select_authenticated: 認証ユーザーなら全員の生座標が読めた（重大）
--   - insert/update/delete: auth.uid() = user_id で比較していたが、
--     user_id は users.user_id（auth_id とは別UUID）のため実際には一致せず
--     書き込みが通らない不整合があった。正しいマッピングに修正する。
-- ============================================================

DROP POLICY IF EXISTS "locations_select_authenticated" ON public.user_locations;
DROP POLICY IF EXISTS "locations_select_own"           ON public.user_locations;
DROP POLICY IF EXISTS "locations_insert_own"          ON public.user_locations;
DROP POLICY IF EXISTS "locations_update_own"          ON public.user_locations;
DROP POLICY IF EXISTS "locations_delete_own"          ON public.user_locations;

-- 自分の行のみ参照可（他人の生座標は一切読めない）
CREATE POLICY "locations_select_own" ON public.user_locations
  FOR SELECT USING (
    user_id IN (SELECT user_id FROM public.users WHERE auth_id = auth.uid())
  );

CREATE POLICY "locations_insert_own" ON public.user_locations
  FOR INSERT WITH CHECK (
    user_id IN (SELECT user_id FROM public.users WHERE auth_id = auth.uid())
  );

CREATE POLICY "locations_update_own" ON public.user_locations
  FOR UPDATE USING (
    user_id IN (SELECT user_id FROM public.users WHERE auth_id = auth.uid())
  );

CREATE POLICY "locations_delete_own" ON public.user_locations
  FOR DELETE USING (
    user_id IN (SELECT user_id FROM public.users WHERE auth_id = auth.uid())
  );

-- 近傍ユーザーIDのみを返すRPC（生座標はクライアントに出さない）
-- 呼び出し元は「自分の現在地」を渡し、半径内の他ユーザーの user_id だけを受け取る
CREATE OR REPLACE FUNCTION public.nearby_user_ids(
  p_lat             double precision,
  p_lng             double precision,
  p_radius_m        double precision DEFAULT 200,
  p_max_age_seconds integer          DEFAULT 10
)
RETURNS TABLE(user_id uuid)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT ul.user_id
  FROM public.user_locations ul
  WHERE ul.user_id <> (SELECT u.user_id FROM public.users u WHERE u.auth_id = auth.uid())
    AND ul.updated_at > now() - make_interval(secs => p_max_age_seconds)
    -- ハーバーサイン距離（メートル）
    AND 6371000 * 2 * asin(
          sqrt(
            power(sin(radians(ul.lat - p_lat) / 2), 2)
            + cos(radians(p_lat)) * cos(radians(ul.lat))
              * power(sin(radians(ul.lng - p_lng) / 2), 2)
          )
        ) <= p_radius_m;
$$;

REVOKE ALL  ON FUNCTION public.nearby_user_ids(double precision, double precision, double precision, integer) FROM public;
GRANT EXECUTE ON FUNCTION public.nearby_user_ids(double precision, double precision, double precision, integer) TO authenticated;


-- ============================================================
-- ② SNSリンクをマッチ済みのみ閲覧可に分離
-- ------------------------------------------------------------
-- 旧: users_select_public USING(true) により、誰でも全員の sns_links を
--     API 経由で読めた（「相互いいねで初めて開示」というコンセプトが崩壊）。
-- 新: sns_links を専用テーブルに移し、本人 or マッチ済み相手のみ閲覧可にする。
-- ============================================================

-- SNS専用テーブル
CREATE TABLE IF NOT EXISTS public.user_sns_links (
  user_id    UUID PRIMARY KEY REFERENCES public.users(user_id) ON DELETE CASCADE,
  links      JSONB NOT NULL DEFAULT '[]'::jsonb,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 既存データを移行（users.sns_links が存在する場合のみ）
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'users' AND column_name = 'sns_links'
  ) THEN
    INSERT INTO public.user_sns_links (user_id, links)
    SELECT user_id, COALESCE(sns_links, '[]'::jsonb) FROM public.users
    ON CONFLICT (user_id) DO NOTHING;

    -- users から sns_links を削除（もう公開テーブルには置かない）
    ALTER TABLE public.users DROP COLUMN sns_links;
  END IF;
END $$;

ALTER TABLE public.user_sns_links ENABLE ROW LEVEL SECURITY;

-- 参照: 本人、またはマッチ済みの相手のみ
DROP POLICY IF EXISTS "user_sns_select_owner_or_matched" ON public.user_sns_links;
CREATE POLICY "user_sns_select_owner_or_matched" ON public.user_sns_links
  FOR SELECT USING (
    user_id IN (SELECT user_id FROM public.users WHERE auth_id = auth.uid())
    OR EXISTS (
      SELECT 1
      FROM public.matches m
      JOIN public.users me ON me.auth_id = auth.uid()
      WHERE (m.user_a_id = public.user_sns_links.user_id AND m.user_b_id = me.user_id)
         OR (m.user_b_id = public.user_sns_links.user_id AND m.user_a_id = me.user_id)
    )
  );

-- 追加/更新/削除: 本人のみ
DROP POLICY IF EXISTS "user_sns_insert_owner" ON public.user_sns_links;
CREATE POLICY "user_sns_insert_owner" ON public.user_sns_links
  FOR INSERT WITH CHECK (
    user_id IN (SELECT user_id FROM public.users WHERE auth_id = auth.uid())
  );
DROP POLICY IF EXISTS "user_sns_update_owner" ON public.user_sns_links;
CREATE POLICY "user_sns_update_owner" ON public.user_sns_links
  FOR UPDATE USING (
    user_id IN (SELECT user_id FROM public.users WHERE auth_id = auth.uid())
  );
DROP POLICY IF EXISTS "user_sns_delete_owner" ON public.user_sns_links;
CREATE POLICY "user_sns_delete_owner" ON public.user_sns_links
  FOR DELETE USING (
    user_id IN (SELECT user_id FROM public.users WHERE auth_id = auth.uid())
  );

-- users の閲覧は「ログイン済み」に限定（匿名ロールには開かない）
DROP POLICY IF EXISTS "users_select_public" ON public.users;
DROP POLICY IF EXISTS "users_select_authenticated" ON public.users;
CREATE POLICY "users_select_authenticated" ON public.users
  FOR SELECT USING (auth.role() = 'authenticated');


-- ============================================================
-- ③ 期限切れ encounters の自動削除
-- ------------------------------------------------------------
-- expires_at を過ぎた行を定期削除（無料24h / 有料7d 設計を実際に効かせる）
-- pg_cron が使えない環境では、この DO ブロックはスキップされる。
-- その場合は Supabase の「Scheduled Functions」等で
--   DELETE FROM public.encounters WHERE expires_at < now();
-- を1時間ごとに実行してください。
-- ============================================================

DO $cron_setup$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'pg_cron') THEN
    CREATE EXTENSION IF NOT EXISTS pg_cron;
    IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'delete-expired-encounters') THEN
      PERFORM cron.unschedule('delete-expired-encounters');
    END IF;
    PERFORM cron.schedule(
      'delete-expired-encounters',
      '0 * * * *',
      $cron_job$DELETE FROM public.encounters WHERE expires_at < now()$cron_job$
    );
  END IF;
END $cron_setup$;


-- ============================================================
-- 確認クエリ
-- ============================================================
SELECT tablename, policyname, cmd
FROM pg_policies
WHERE tablename IN ('user_locations', 'users', 'user_sns_links')
ORDER BY tablename, policyname;
