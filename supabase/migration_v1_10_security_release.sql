-- ============================================================
-- Migration v1.10: リリース前セキュリティ最終対策
-- 前提: v1.8 / v1.9 実行済み
-- 内容:
--   1) user_locations の古い行を自動削除（TTL）
--   2) users 閲覧を「関係者のみ」に制限 + ブロック除外
--   3) nearby_user_ids にブロック/匿名モード除外
--   4) register_encounter RPC（クライアント直呼び INSERT を廃止）
--   5) send_like の本人確認
--   6) Storage バケット非公開化 + 関係者のみ読み取り
-- ============================================================

-- ------------------------------------------------------------
-- 1) user_locations TTL（30秒超過分を毎分削除）
-- ------------------------------------------------------------
DO $cron_locations$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'pg_cron') THEN
    CREATE EXTENSION IF NOT EXISTS pg_cron;
    IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'delete-stale-user-locations') THEN
      PERFORM cron.unschedule('delete-stale-user-locations');
    END IF;
    PERFORM cron.schedule(
      'delete-stale-user-locations',
      '* * * * *',
      $job$DELETE FROM public.user_locations WHERE updated_at < now() - interval '30 seconds'$job$
    );
  END IF;
END $cron_locations$;

-- ------------------------------------------------------------
-- 2) users 閲覧: 本人 / すれ違い / マッチ / いいね関係のみ
--    ブロック関係にあるユーザーは相互に見えない
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.can_view_user(p_target_user_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    p_target_user_id IN (
      SELECT user_id FROM public.users WHERE auth_id = auth.uid()
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
    );
$$;

REVOKE ALL ON FUNCTION public.can_view_user(uuid) FROM public;
GRANT EXECUTE ON FUNCTION public.can_view_user(uuid) TO authenticated;

DROP POLICY IF EXISTS "users_select_public" ON public.users;
DROP POLICY IF EXISTS "users_select_authenticated" ON public.users;
DROP POLICY IF EXISTS "users_select_related" ON public.users;

CREATE POLICY "users_select_related" ON public.users
FOR SELECT USING (public.can_view_user(user_id));

-- ------------------------------------------------------------
-- 3) nearby_user_ids: ブロック/匿名モードユーザーを除外
-- ------------------------------------------------------------
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
  JOIN public.users ou ON ou.user_id = ul.user_id
  WHERE ul.user_id <> (SELECT u.user_id FROM public.users u WHERE u.auth_id = auth.uid())
    AND ou.anonymous_mode = false
    AND ul.updated_at > now() - make_interval(secs => p_max_age_seconds)
    AND NOT EXISTS (
      SELECT 1
      FROM public.blocks b
      JOIN public.users me ON me.auth_id = auth.uid()
      WHERE (b.blocker_id = me.user_id AND b.blocked_id = ul.user_id)
         OR (b.blocker_id = ul.user_id AND b.blocked_id = me.user_id)
    )
    AND 6371000 * 2 * asin(
          sqrt(
            power(sin(radians(ul.lat - p_lat) / 2), 2)
            + cos(radians(p_lat)) * cos(radians(ul.lat))
              * power(sin(radians(ul.lng - p_lng) / 2), 2)
          )
        ) <= p_radius_m;
$$;

-- ------------------------------------------------------------
-- 4) register_encounter RPC（呼び出し元のみが当事者）
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.register_encounter(p_other_user_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_my_user_id   uuid;
  v_sorted_a     uuid;
  v_sorted_b     uuid;
  v_a_premium    boolean;
  v_b_premium    boolean;
  v_expires_at   timestamptz;
  v_occurrence   integer;
BEGIN
  SELECT user_id, is_premium
    INTO v_my_user_id, v_a_premium
  FROM public.users
  WHERE auth_id = auth.uid();

  IF v_my_user_id IS NULL THEN
    RAISE EXCEPTION 'not authenticated';
  END IF;

  IF p_other_user_id IS NULL OR p_other_user_id = v_my_user_id THEN
    RETURN;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.users WHERE user_id = p_other_user_id) THEN
    RETURN;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.blocks b
    WHERE (b.blocker_id = v_my_user_id AND b.blocked_id = p_other_user_id)
       OR (b.blocker_id = p_other_user_id AND b.blocked_id = v_my_user_id)
  ) THEN
    RETURN;
  END IF;

  v_sorted_a := LEAST(v_my_user_id, p_other_user_id);
  v_sorted_b := GREATEST(v_my_user_id, p_other_user_id);

  IF EXISTS (
    SELECT 1
    FROM public.encounters
    WHERE user_a_id = v_sorted_a
      AND user_b_id = v_sorted_b
      AND time > now() - interval '5 minutes'
  ) THEN
    RETURN;
  END IF;

  SELECT is_premium INTO v_b_premium
  FROM public.users
  WHERE user_id = p_other_user_id;

  v_expires_at := CASE
    WHEN v_a_premium AND v_b_premium THEN now() + interval '7 days'
    ELSE now() + interval '24 hours'
  END;

  SELECT COUNT(*) + 1
    INTO v_occurrence
  FROM public.encounters
  WHERE user_a_id = v_sorted_a
    AND user_b_id = v_sorted_b;

  INSERT INTO public.encounters (
    user_a_id,
    user_b_id,
    expires_at,
    occurrence_number
  ) VALUES (
    v_sorted_a,
    v_sorted_b,
    v_expires_at,
    v_occurrence
  );
END;
$$;

REVOKE ALL ON FUNCTION public.register_encounter(uuid) FROM public;
GRANT EXECUTE ON FUNCTION public.register_encounter(uuid) TO authenticated;

-- デバッグ用（固定テストユーザーとのすれ違いシードのみ許可）
CREATE OR REPLACE FUNCTION public.debug_seed_encounters(
  p_partner_user_id uuid,
  p_hours_ago integer DEFAULT 0
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_my_user_id uuid;
  v_sorted_a   uuid;
  v_sorted_b   uuid;
  v_occurrence integer;
BEGIN
  IF p_partner_user_id <> '00000000-0000-0000-0000-000000000002'::uuid THEN
    RAISE EXCEPTION 'debug partner only';
  END IF;

  SELECT user_id INTO v_my_user_id FROM public.users WHERE auth_id = auth.uid();
  IF v_my_user_id IS NULL THEN
    RAISE EXCEPTION 'not authenticated';
  END IF;

  v_sorted_a := LEAST(v_my_user_id, p_partner_user_id);
  v_sorted_b := GREATEST(v_my_user_id, p_partner_user_id);

  SELECT COUNT(*) + 1 INTO v_occurrence
  FROM public.encounters
  WHERE user_a_id = v_sorted_a AND user_b_id = v_sorted_b;

  INSERT INTO public.encounters (
    user_a_id, user_b_id, time, expires_at, occurrence_number
  ) VALUES (
    v_sorted_a,
    v_sorted_b,
    now() - make_interval(hours => p_hours_ago),
    now() + interval '24 hours',
    v_occurrence
  );
END;
$$;

REVOKE ALL ON FUNCTION public.debug_seed_encounters(uuid, integer) FROM public;
GRANT EXECUTE ON FUNCTION public.debug_seed_encounters(uuid, integer) TO authenticated;

-- 旧クライアントの直接 INSERT を禁止
DROP POLICY IF EXISTS "encounters_insert_own" ON public.encounters;

-- ------------------------------------------------------------
-- 5) send_like: 送信者が本人であることを強制
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.send_like(
  p_from_user_id UUID,
  p_to_user_id   UUID,
  p_encounter_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_is_matched   BOOLEAN := FALSE;
  v_match_id     UUID;
  v_like_count   INT;
  v_is_premium   BOOLEAN;
  v_user_a       UUID;
  v_user_b       UUID;
BEGIN
  IF p_from_user_id NOT IN (
    SELECT user_id FROM public.users WHERE auth_id = auth.uid()
  ) THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'forbidden');
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.blocks b
    WHERE (b.blocker_id = p_from_user_id AND b.blocked_id = p_to_user_id)
       OR (b.blocker_id = p_to_user_id AND b.blocked_id = p_from_user_id)
  ) THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'blocked');
  END IF;

  SELECT is_premium INTO v_is_premium FROM public.users WHERE user_id = p_from_user_id;

  IF NOT v_is_premium THEN
    SELECT like_count INTO v_like_count
    FROM public.today_like_counts
    WHERE from_user_id = p_from_user_id;

    IF COALESCE(v_like_count, 0) >= 10 THEN
      RETURN jsonb_build_object('success', FALSE, 'error', 'daily_limit_exceeded');
    END IF;
  END IF;

  INSERT INTO public.likes (from_user_id, to_user_id, encounter_id)
  VALUES (p_from_user_id, p_to_user_id, p_encounter_id)
  ON CONFLICT (from_user_id, to_user_id, encounter_id) DO NOTHING;

  IF EXISTS (
    SELECT 1 FROM public.likes
    WHERE from_user_id = p_to_user_id
      AND to_user_id = p_from_user_id
      AND encounter_id = p_encounter_id
  ) THEN
    v_user_a := LEAST(p_from_user_id, p_to_user_id);
    v_user_b := GREATEST(p_from_user_id, p_to_user_id);

    INSERT INTO public.matches (user_a_id, user_b_id)
    VALUES (v_user_a, v_user_b)
    ON CONFLICT (user_a_id, user_b_id) DO NOTHING
    RETURNING match_id INTO v_match_id;

    v_is_matched := TRUE;
  END IF;

  RETURN jsonb_build_object(
    'success',    TRUE,
    'is_matched', v_is_matched,
    'match_id',   v_match_id
  );
END;
$$;

-- ------------------------------------------------------------
-- 6) Storage: バケット非公開 + 関係者のみ読み取り
-- ------------------------------------------------------------
UPDATE storage.buckets
SET public = false
WHERE id IN ('profile-photos', 'vehicle-photos');

DO $storage_v10$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = 'storage' AND table_name = 'objects'
  ) THEN
    DROP POLICY IF EXISTS "yaeh_storage_read_public" ON storage.objects;
    DROP POLICY IF EXISTS "yaeh_storage_read_related" ON storage.objects;

    CREATE POLICY "yaeh_storage_read_related" ON storage.objects
    FOR SELECT TO authenticated
    USING (
      bucket_id IN ('profile-photos', 'vehicle-photos')
      AND (
        -- 自分のプロフィール写真
        (
          bucket_id = 'profile-photos'
          AND name LIKE 'avatar_' || (
            SELECT user_id::text FROM public.users WHERE auth_id = auth.uid()
          ) || '_%'
        )
        -- 自分の車両写真（userId/ 配下）
        OR (
          bucket_id = 'vehicle-photos'
          AND (storage.foldername(name))[1] = (
            SELECT user_id::text FROM public.users WHERE auth_id = auth.uid()
          )
        )
        -- 関係者のプロフィール写真
        OR (
          bucket_id = 'profile-photos'
          AND name ~ '^avatar_[0-9a-f-]{36}_'
          AND public.can_view_user(
            (regexp_match(name, '^avatar_([0-9a-f-]{36})_'))[1]::uuid
          )
        )
        -- 関係者の車両写真（userId/ 配下）
        OR (
          bucket_id = 'vehicle-photos'
          AND (storage.foldername(name))[1] IS NOT NULL
          AND (storage.foldername(name))[1] ~ '^[0-9a-f-]{36}$'
          AND public.can_view_user(((storage.foldername(name))[1])::uuid)
        )
        -- レガシー: vehicle-photos 直下のファイル名（移行期間のみ）
        OR (
          bucket_id = 'vehicle-photos'
          AND name NOT LIKE '%/%'
          AND EXISTS (
            SELECT 1
            FROM public.vehicles v
            WHERE v.photos::text LIKE '%' || name || '%'
              AND public.can_view_user(v.user_id)
          )
        )
      )
    );
  END IF;
END $storage_v10$;
