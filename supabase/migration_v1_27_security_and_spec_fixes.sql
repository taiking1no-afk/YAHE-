-- ============================================================
-- Migration v1.27 : 監査指摘の一括修正
-- 前提: v1.1〜v1.26 実行済み。冪等。
-- ------------------------------------------------------------
-- ① user_locations SELECT を v1.8 の正しい auth_id マッピングに戻す
-- ② users 保護列のクライアント書換禁止トリガー
-- ③ sync_subscription_plan / grant_gear_plus を service_role のみに
--    + Gear R 解約時 is_verified クリア
-- ④ send_like: encounter 当事者・期限・ブロック検証 + likes 直INSERT禁止
-- ⑤ すれ違い expires_at: どちらかが premium なら 7日
-- ⑥ 車両台数・愛車ガード件数の DB 上限
-- ⑦ Storage 書き込みを所有者パスに制限
-- ⑧ user_items / purchase_history 整備 + アイテムRPC
-- ============================================================


-- ============================================================
-- ① user_locations SELECT 修正（v1.26 退行の復旧）
-- ============================================================
DROP POLICY IF EXISTS "locations_select_authenticated" ON public.user_locations;
DROP POLICY IF EXISTS "locations_select_own" ON public.user_locations;

CREATE POLICY "locations_select_own" ON public.user_locations
  FOR SELECT USING (
    user_id IN (SELECT user_id FROM public.users WHERE auth_id = auth.uid())
  );


-- ============================================================
-- ② users 保護列ガード
-- ------------------------------------------------------------
-- プロフィール等の更新は許可。plan / is_premium / is_verified /
-- is_suspended / premium_override_* / trial_* / encounter_test_mode 等は
-- service_role（および SECURITY DEFINER 関数）以外から変更不可。
-- ============================================================
CREATE OR REPLACE FUNCTION public.protect_users_sensitive_columns()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_jwt_role TEXT := COALESCE(
    current_setting('request.jwt.claim.role', true),
    ''
  );
BEGIN
  -- 信頼済み RPC 内（set_config で許可）
  IF current_setting('yaeh.allow_sensitive_update', true) = '1' THEN
    RETURN NEW;
  END IF;

  -- 他トリガー経由（通報自動停止など）は通過
  IF pg_trigger_depth() > 1 THEN
    RETURN NEW;
  END IF;

  -- service_role 経由（Webhook / Edge Function）は通過
  IF v_jwt_role = 'service_role'
     OR current_setting('role', true) = 'service_role' THEN
    RETURN NEW;
  END IF;

  -- JWT なし（pg_cron / 内部ジョブ）は通過
  IF v_jwt_role = '' THEN
    RETURN NEW;
  END IF;

  IF TG_OP = 'UPDATE' AND v_jwt_role = 'authenticated' THEN
    IF NEW.plan IS DISTINCT FROM OLD.plan
       OR NEW.is_premium IS DISTINCT FROM OLD.is_premium
       OR NEW.is_verified IS DISTINCT FROM OLD.is_verified
       OR COALESCE(NEW.is_suspended, FALSE) IS DISTINCT FROM COALESCE(OLD.is_suspended, FALSE)
       OR NEW.premium_override_plan IS DISTINCT FROM OLD.premium_override_plan
       OR NEW.premium_override_expires_at IS DISTINCT FROM OLD.premium_override_expires_at
       OR NEW.premium_override_source IS DISTINCT FROM OLD.premium_override_source
       OR NEW.premium_override_reason IS DISTINCT FROM OLD.premium_override_reason
       OR NEW.trial_ends_at IS DISTINCT FROM OLD.trial_ends_at
       OR NEW.gear_plus_trial_used_at IS DISTINCT FROM OLD.gear_plus_trial_used_at
       OR NEW.gear_r_applied_at IS DISTINCT FROM OLD.gear_r_applied_at
       OR COALESCE(NEW.encounter_test_mode, FALSE) IS DISTINCT FROM COALESCE(OLD.encounter_test_mode, FALSE)
    THEN
      RAISE EXCEPTION 'forbidden: sensitive user columns are server-managed';
    END IF;

    IF NEW.verified_label IS DISTINCT FROM OLD.verified_label
       AND public.user_effective_plan(OLD.user_id) <> 'gear_r' THEN
      RAISE EXCEPTION 'forbidden: verified_label requires gear_r';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_protect_users_sensitive ON public.users;
CREATE TRIGGER trg_protect_users_sensitive
  BEFORE UPDATE ON public.users
  FOR EACH ROW
  EXECUTE FUNCTION public.protect_users_sensitive_columns();


-- ============================================================
-- ③ sync_subscription_plan（解約時バッジ解除 + service_role のみ）
-- ============================================================
CREATE OR REPLACE FUNCTION public.sync_subscription_plan(
  p_user_id          UUID,
  p_plan             TEXT,
  p_trial_ends_at    TIMESTAMPTZ DEFAULT NULL,
  p_mark_trial_used  BOOLEAN DEFAULT FALSE
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_effective TEXT;
  v_prev_plan TEXT;
BEGIN
  PERFORM set_config('yaeh.allow_sensitive_update', '1', true);

  IF p_plan NOT IN ('free', 'pit_in', 'gear_plus', 'gear_r') THEN
    RAISE EXCEPTION 'invalid plan: %', p_plan;
  END IF;

  SELECT plan INTO v_prev_plan FROM public.users WHERE user_id = p_user_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'user not found';
  END IF;

  IF p_plan = 'free' THEN
    UPDATE public.users
    SET
      plan = 'free',
      trial_ends_at = NULL,
      is_verified = CASE
        WHEN plan = 'gear_r' THEN FALSE
        ELSE is_verified
      END,
      verified_label = CASE
        WHEN plan = 'gear_r' THEN NULL
        ELSE verified_label
      END
    WHERE user_id = p_user_id
      AND plan IN ('pit_in', 'gear_plus', 'gear_r');
  ELSIF p_plan = 'gear_r' THEN
    UPDATE public.users
    SET
      plan = 'gear_r',
      trial_ends_at = NULL,
      gear_plus_trial_used_at = COALESCE(gear_plus_trial_used_at, NOW()),
      is_verified = TRUE,
      gear_r_applied_at = COALESCE(gear_r_applied_at, NOW())
    WHERE user_id = p_user_id;
  ELSIF p_plan = 'gear_plus' THEN
    UPDATE public.users
    SET
      plan = 'gear_plus',
      trial_ends_at = p_trial_ends_at,
      gear_plus_trial_used_at = CASE
        WHEN p_mark_trial_used THEN COALESCE(gear_plus_trial_used_at, NOW())
        ELSE gear_plus_trial_used_at
      END,
      -- Gear R → Gear+ 降格時もバッジ解除
      is_verified = CASE
        WHEN v_prev_plan = 'gear_r' THEN FALSE
        ELSE is_verified
      END,
      verified_label = CASE
        WHEN v_prev_plan = 'gear_r' THEN NULL
        ELSE verified_label
      END
    WHERE user_id = p_user_id;
  ELSE
    -- pit_in
    UPDATE public.users
    SET
      plan = 'pit_in',
      is_verified = CASE
        WHEN v_prev_plan = 'gear_r' THEN FALSE
        ELSE is_verified
      END,
      verified_label = CASE
        WHEN v_prev_plan = 'gear_r' THEN NULL
        ELSE verified_label
      END
    WHERE user_id = p_user_id;
  END IF;

  PERFORM public.sync_user_premium(p_user_id);
  v_effective := public.user_effective_plan(p_user_id);

  RETURN jsonb_build_object(
    'success',        TRUE,
    'effective_plan', v_effective
  );
END;
$$;

REVOKE ALL ON FUNCTION public.sync_subscription_plan(UUID, TEXT, TIMESTAMPTZ, BOOLEAN) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.sync_subscription_plan(UUID, TEXT, TIMESTAMPTZ, BOOLEAN) FROM authenticated;
REVOKE ALL ON FUNCTION public.sync_subscription_plan(UUID, TEXT, TIMESTAMPTZ, BOOLEAN) FROM anon;
GRANT EXECUTE ON FUNCTION public.sync_subscription_plan(UUID, TEXT, TIMESTAMPTZ, BOOLEAN) TO service_role;

-- grant_gear_plus はクライアントから呼べない（運営/Webhook のみ）
CREATE OR REPLACE FUNCTION public.grant_gear_plus(p_user_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM public.sync_subscription_plan(p_user_id, 'gear_plus', NULL, TRUE);
END;
$$;

REVOKE ALL ON FUNCTION public.grant_gear_plus(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.grant_gear_plus(UUID) FROM authenticated;
REVOKE ALL ON FUNCTION public.grant_gear_plus(UUID) FROM anon;
GRANT EXECUTE ON FUNCTION public.grant_gear_plus(UUID) TO service_role;


-- ============================================================
-- ④ send_like 強化 + likes 直 INSERT 禁止
-- ============================================================
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
  v_is_suspended BOOLEAN;
  v_caller       UUID;
  v_user_a       UUID;
  v_user_b       UUID;
  v_enc_a        UUID;
  v_enc_b        UUID;
  v_expires      TIMESTAMPTZ;
  v_rowcount     INT := 0;
BEGIN
  SELECT user_id INTO v_caller FROM public.users WHERE auth_id = auth.uid();
  IF v_caller IS NULL OR v_caller <> p_from_user_id THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'forbidden');
  END IF;

  IF p_from_user_id = p_to_user_id THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'invalid_target');
  END IF;

  SELECT user_a_id, user_b_id, expires_at
  INTO v_enc_a, v_enc_b, v_expires
  FROM public.encounters
  WHERE encounter_id = p_encounter_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'encounter_not_found');
  END IF;

  IF v_expires <= NOW() THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'encounter_expired');
  END IF;

  IF NOT (
    (v_enc_a = p_from_user_id AND v_enc_b = p_to_user_id) OR
    (v_enc_b = p_from_user_id AND v_enc_a = p_to_user_id)
  ) THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'not_encounter_party');
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.blocks b
    WHERE (b.blocker_id = p_from_user_id AND b.blocked_id = p_to_user_id)
       OR (b.blocker_id = p_to_user_id AND b.blocked_id = p_from_user_id)
  ) THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'blocked');
  END IF;

  v_is_premium := public.user_is_premium(p_from_user_id);

  SELECT is_suspended INTO v_is_suspended
  FROM public.users WHERE user_id = p_from_user_id;

  IF COALESCE(v_is_suspended, FALSE) THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'suspended');
  END IF;

  SELECT like_count INTO v_like_count
  FROM public.today_like_counts
  WHERE from_user_id = p_from_user_id;

  IF NOT v_is_premium AND COALESCE(v_like_count, 0) >= 10 THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'daily_limit_exceeded');
  END IF;

  INSERT INTO public.likes (from_user_id, to_user_id, encounter_id)
  VALUES (p_from_user_id, p_to_user_id, p_encounter_id)
  ON CONFLICT (from_user_id, to_user_id, encounter_id) DO NOTHING;

  GET DIAGNOSTICS v_rowcount = ROW_COUNT;
  -- 0 なら重複いいね
  IF v_rowcount = 0 THEN
    IF EXISTS (
      SELECT 1 FROM public.likes
      WHERE from_user_id = p_to_user_id
        AND to_user_id = p_from_user_id
        AND encounter_id = p_encounter_id
    ) OR EXISTS (
      SELECT 1 FROM public.matches
      WHERE user_a_id = LEAST(p_from_user_id, p_to_user_id)
        AND user_b_id = GREATEST(p_from_user_id, p_to_user_id)
    ) THEN
      RETURN jsonb_build_object(
        'success', TRUE,
        'is_matched', TRUE,
        'already_liked', TRUE
      );
    END IF;
    RETURN jsonb_build_object(
      'success', TRUE,
      'is_matched', FALSE,
      'already_liked', TRUE
    );
  END IF;

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
    'match_id',   v_match_id,
    'already_liked', FALSE
  );
END;
$$;

DROP POLICY IF EXISTS "likes_insert_own" ON public.likes;
-- INSERT は send_like (SECURITY DEFINER) 経由のみ


-- ============================================================
-- ⑤ expires_at: どちらかが premium なら 7日
-- ============================================================
CREATE OR REPLACE FUNCTION public._register_encounter_one(
  v_my_user_id   uuid,
  p_other_user_id uuid,
  p_test_mode    boolean
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_sorted_a        uuid;
  v_sorted_b        uuid;
  v_a_premium       boolean;
  v_b_premium       boolean;
  v_expires_at      timestamptz;
  v_occurrence      integer;
  v_dedupe_interval interval := interval '1 day';
  v_test_allowed    boolean;
BEGIN
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

  IF NOT public.users_can_pass(v_my_user_id, p_other_user_id) THEN
    RETURN;
  END IF;

  IF p_test_mode THEN
    SELECT COALESCE(encounter_test_mode, false)
    INTO v_test_allowed
    FROM public.users
    WHERE user_id = v_my_user_id;

    IF v_test_allowed THEN
      v_dedupe_interval := interval '5 minutes';
    END IF;
  END IF;

  v_sorted_a := LEAST(v_my_user_id, p_other_user_id);
  v_sorted_b := GREATEST(v_my_user_id, p_other_user_id);

  IF EXISTS (
    SELECT 1
    FROM public.encounters
    WHERE user_a_id = v_sorted_a
      AND user_b_id = v_sorted_b
      AND time > now() - v_dedupe_interval
  ) THEN
    RETURN;
  END IF;

  v_a_premium := public.user_is_premium(v_my_user_id);
  v_b_premium := public.user_is_premium(p_other_user_id);

  -- どちらかが premium なら 7日保持（閲覧側フィルタはクライアントで無料24h）
  v_expires_at := CASE
    WHEN v_a_premium OR v_b_premium THEN now() + interval '7 days'
    ELSE now() + interval '24 hours'
  END;

  SELECT COUNT(*) + 1
  INTO v_occurrence
  FROM public.encounters
  WHERE user_a_id = v_sorted_a
    AND user_b_id = v_sorted_b;

  INSERT INTO public.encounters (
    user_a_id, user_b_id, time, expires_at, occurrence_number
  ) VALUES (
    v_sorted_a, v_sorted_b, now(), v_expires_at, v_occurrence
  );
END;
$$;


-- ============================================================
-- ⑥ 車両・愛車ガード上限
-- ============================================================
CREATE OR REPLACE FUNCTION public.enforce_vehicle_limit()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_count INT;
BEGIN
  IF NEW.is_active IS DISTINCT FROM TRUE THEN
    RETURN NEW;
  END IF;

  IF public.user_is_premium(NEW.user_id) THEN
    RETURN NEW;
  END IF;

  SELECT COUNT(*) INTO v_count
  FROM public.vehicles
  WHERE user_id = NEW.user_id
    AND is_active = TRUE
    AND (TG_OP = 'INSERT' OR vehicle_id IS DISTINCT FROM NEW.vehicle_id);

  IF v_count >= 2 THEN
    RAISE EXCEPTION 'vehicle_limit_exceeded';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_enforce_vehicle_limit ON public.vehicles;
CREATE TRIGGER trg_enforce_vehicle_limit
  BEFORE INSERT OR UPDATE OF is_active ON public.vehicles
  FOR EACH ROW
  EXECUTE FUNCTION public.enforce_vehicle_limit();

CREATE OR REPLACE FUNCTION public.enforce_privacy_zone_limit()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_count INT;
BEGIN
  IF public.user_is_premium(NEW.user_id) THEN
    RETURN NEW;
  END IF;

  SELECT COUNT(*) INTO v_count
  FROM public.privacy_zones
  WHERE user_id = NEW.user_id
    AND (TG_OP = 'INSERT' OR zone_id IS DISTINCT FROM NEW.zone_id);

  IF v_count >= 3 THEN
    RAISE EXCEPTION 'privacy_zone_limit_exceeded';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_enforce_privacy_zone_limit ON public.privacy_zones;
CREATE TRIGGER trg_enforce_privacy_zone_limit
  BEFORE INSERT ON public.privacy_zones
  FOR EACH ROW
  EXECUTE FUNCTION public.enforce_privacy_zone_limit();


-- ============================================================
-- ⑦ Storage 所有者パス制限
-- ------------------------------------------------------------
-- vehicle-photos: {user_id}/...
-- profile-photos: avatar_{user_id}_... または {user_id}/...
-- ============================================================
DO $storage_rls$
DECLARE
  v_uid_expr TEXT :=
    '(SELECT user_id::text FROM public.users WHERE auth_id = auth.uid())';
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = 'storage' AND table_name = 'objects'
  ) THEN
    DROP POLICY IF EXISTS "yaeh_storage_insert_auth" ON storage.objects;
    DROP POLICY IF EXISTS "yaeh_storage_update_auth" ON storage.objects;
    DROP POLICY IF EXISTS "yaeh_storage_delete_auth" ON storage.objects;
    DROP POLICY IF EXISTS "yaeh_storage_insert_own" ON storage.objects;
    DROP POLICY IF EXISTS "yaeh_storage_update_own" ON storage.objects;
    DROP POLICY IF EXISTS "yaeh_storage_delete_own" ON storage.objects;

    EXECUTE format($pol$
      CREATE POLICY "yaeh_storage_insert_own" ON storage.objects
        FOR INSERT TO authenticated
        WITH CHECK (
          (bucket_id = 'vehicle-photos'
            AND (storage.foldername(name))[1] = %1$s)
          OR
          (bucket_id = 'profile-photos'
            AND (
              (storage.foldername(name))[1] = %1$s
              OR name LIKE ('avatar_' || %1$s || '_%%')
            ))
        )
    $pol$, v_uid_expr);

    EXECUTE format($pol$
      CREATE POLICY "yaeh_storage_update_own" ON storage.objects
        FOR UPDATE TO authenticated
        USING (
          (bucket_id = 'vehicle-photos'
            AND (storage.foldername(name))[1] = %1$s)
          OR
          (bucket_id = 'profile-photos'
            AND (
              (storage.foldername(name))[1] = %1$s
              OR name LIKE ('avatar_' || %1$s || '_%%')
            ))
        )
    $pol$, v_uid_expr);

    EXECUTE format($pol$
      CREATE POLICY "yaeh_storage_delete_own" ON storage.objects
        FOR DELETE TO authenticated
        USING (
          (bucket_id = 'vehicle-photos'
            AND (storage.foldername(name))[1] = %1$s)
          OR
          (bucket_id = 'profile-photos'
            AND (
              (storage.foldername(name))[1] = %1$s
              OR name LIKE ('avatar_' || %1$s || '_%%')
            ))
        )
    $pol$, v_uid_expr);
  END IF;
END $storage_rls$;


-- ============================================================
-- ⑧ user_items / purchase_history + アイテムRPC
-- ============================================================
CREATE TABLE IF NOT EXISTS public.user_items (
  user_id      UUID NOT NULL REFERENCES public.users(user_id) ON DELETE CASCADE,
  item_type    TEXT NOT NULL,
  quantity     INT NOT NULL DEFAULT 0,
  active_until TIMESTAMPTZ,
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (user_id, item_type),
  CONSTRAINT user_items_type_check CHECK (
    item_type IN ('nitro', 'shibu', 'super_nitro', 'geki_shibu', 'gear_plus_24h')
  ),
  CONSTRAINT user_items_qty_nonneg CHECK (quantity >= 0)
);

CREATE TABLE IF NOT EXISTS public.purchase_history (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     UUID NOT NULL REFERENCES public.users(user_id) ON DELETE CASCADE,
  product_id  TEXT NOT NULL,
  amount_jpy  INT,
  store_txn_id TEXT,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_purchase_history_txn
  ON public.purchase_history(store_txn_id)
  WHERE store_txn_id IS NOT NULL;

ALTER TABLE public.user_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.purchase_history ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "user_items_select_own" ON public.user_items;
DROP POLICY IF EXISTS "user_items_all_own" ON public.user_items;
CREATE POLICY "user_items_select_own" ON public.user_items
  FOR SELECT USING (
    user_id IN (SELECT user_id FROM public.users WHERE auth_id = auth.uid())
  );
-- INSERT/UPDATE/DELETE は RPC (SECURITY DEFINER) のみ

DROP POLICY IF EXISTS "purchase_history_select_own" ON public.purchase_history;
DROP POLICY IF EXISTS "purchase_history_all_own" ON public.purchase_history;
CREATE POLICY "purchase_history_select_own" ON public.purchase_history
  FOR SELECT USING (
    user_id IN (SELECT user_id FROM public.users WHERE auth_id = auth.uid())
  );

-- 他ユーザーのブースト状態を一覧ソート用に読める（数量は返さない）
CREATE OR REPLACE FUNCTION public.get_active_boosts(p_user_ids UUID[])
RETURNS TABLE(user_id UUID, item_type TEXT, boost_rank INT, active_until TIMESTAMPTZ)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    ui.user_id,
    ui.item_type,
    CASE
      WHEN ui.item_type IN ('super_nitro', 'geki_shibu') THEN 2
      WHEN ui.item_type IN ('nitro', 'shibu') THEN 1
      ELSE 0
    END AS boost_rank,
    ui.active_until
  FROM public.user_items ui
  WHERE ui.user_id = ANY(p_user_ids)
    AND ui.active_until IS NOT NULL
    AND ui.active_until > NOW()
    AND ui.item_type IN ('nitro', 'shibu', 'super_nitro', 'geki_shibu');
$$;

REVOKE ALL ON FUNCTION public.get_active_boosts(UUID[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_active_boosts(UUID[]) TO authenticated;

-- 時限アイテム発動（1個消費）。gear_plus_24h は premium_override 付与
CREATE OR REPLACE FUNCTION public.activate_timed_item(p_item_type TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid UUID;
  v_qty INT;
  v_until TIMESTAMPTZ;
  v_duration INTERVAL;
BEGIN
  SELECT user_id INTO v_uid FROM public.users WHERE auth_id = auth.uid();
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'forbidden');
  END IF;

  IF p_item_type NOT IN ('nitro', 'super_nitro', 'gear_plus_24h') THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'invalid_type');
  END IF;

  v_duration := CASE
    WHEN p_item_type = 'gear_plus_24h' THEN INTERVAL '24 hours'
    ELSE INTERVAL '1 hour'
  END;
  v_until := NOW() + v_duration;

  PERFORM set_config('yaeh.allow_sensitive_update', '1', true);

  SELECT quantity INTO v_qty
  FROM public.user_items
  WHERE user_id = v_uid AND item_type = p_item_type
  FOR UPDATE;

  -- gear_plus_24h は購入即発動で quantity 0 のまま active だけ立つ場合あり
  IF p_item_type = 'gear_plus_24h' THEN
    IF COALESCE(v_qty, 0) > 0 THEN
      UPDATE public.user_items
      SET quantity = quantity - 1,
          active_until = v_until,
          updated_at = NOW()
      WHERE user_id = v_uid AND item_type = p_item_type;
    ELSE
      INSERT INTO public.user_items (user_id, item_type, quantity, active_until, updated_at)
      VALUES (v_uid, p_item_type, 0, v_until, NOW())
      ON CONFLICT (user_id, item_type) DO UPDATE SET
        active_until = EXCLUDED.active_until,
        updated_at = NOW();
    END IF;

    UPDATE public.users
    SET
      premium_override_plan = 'gear_plus',
      premium_override_expires_at = v_until,
      premium_override_source = COALESCE(premium_override_source, 'admin'),
      premium_override_reason = 'gear_plus_24h'
    WHERE user_id = v_uid;

    PERFORM public.sync_user_premium(v_uid);

    RETURN jsonb_build_object('success', TRUE, 'active_until', v_until);
  END IF;

  IF COALESCE(v_qty, 0) <= 0 THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'insufficient_quantity');
  END IF;

  UPDATE public.user_items
  SET quantity = quantity - 1,
      active_until = v_until,
      updated_at = NOW()
  WHERE user_id = v_uid AND item_type = p_item_type;

  RETURN jsonb_build_object('success', TRUE, 'active_until', v_until);
END;
$$;

REVOKE ALL ON FUNCTION public.activate_timed_item(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.activate_timed_item(TEXT) TO authenticated;

-- 渋！/激渋！消費 → 24時間ブースト
CREATE OR REPLACE FUNCTION public.consume_boost_item(p_item_type TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid UUID;
  v_qty INT;
  v_until TIMESTAMPTZ := NOW() + INTERVAL '24 hours';
BEGIN
  SELECT user_id INTO v_uid FROM public.users WHERE auth_id = auth.uid();
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'forbidden');
  END IF;

  IF p_item_type NOT IN ('shibu', 'geki_shibu') THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'invalid_type');
  END IF;

  SELECT quantity INTO v_qty
  FROM public.user_items
  WHERE user_id = v_uid AND item_type = p_item_type
  FOR UPDATE;

  IF COALESCE(v_qty, 0) <= 0 THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'insufficient_quantity');
  END IF;

  UPDATE public.user_items
  SET quantity = quantity - 1,
      active_until = v_until,
      updated_at = NOW()
  WHERE user_id = v_uid AND item_type = p_item_type;

  RETURN jsonb_build_object('success', TRUE, 'active_until', v_until);
END;
$$;

REVOKE ALL ON FUNCTION public.consume_boost_item(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.consume_boost_item(TEXT) TO authenticated;

-- Webhook / service_role 用: アイテム付与
CREATE OR REPLACE FUNCTION public.grant_user_items(
  p_user_id UUID,
  p_item_type TEXT,
  p_count INT,
  p_activate_immediately BOOLEAN DEFAULT FALSE
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_until TIMESTAMPTZ;
BEGIN
  IF p_count IS NULL OR p_count <= 0 THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'invalid_count');
  END IF;
  IF p_item_type NOT IN ('nitro', 'shibu', 'super_nitro', 'geki_shibu', 'gear_plus_24h') THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'invalid_type');
  END IF;

  PERFORM set_config('yaeh.allow_sensitive_update', '1', true);

  IF p_activate_immediately AND p_item_type = 'gear_plus_24h' THEN
    v_until := NOW() + INTERVAL '24 hours';
    INSERT INTO public.user_items (user_id, item_type, quantity, active_until, updated_at)
    VALUES (p_user_id, p_item_type, 0, v_until, NOW())
    ON CONFLICT (user_id, item_type) DO UPDATE SET
      active_until = GREATEST(COALESCE(public.user_items.active_until, NOW()), EXCLUDED.active_until),
      updated_at = NOW();

    UPDATE public.users
    SET
      premium_override_plan = 'gear_plus',
      premium_override_expires_at = v_until,
      premium_override_source = COALESCE(premium_override_source, 'admin'),
      premium_override_reason = 'gear_plus_24h'
    WHERE user_id = p_user_id;

    PERFORM public.sync_user_premium(p_user_id);
  ELSE
    INSERT INTO public.user_items (user_id, item_type, quantity, updated_at)
    VALUES (p_user_id, p_item_type, p_count, NOW())
    ON CONFLICT (user_id, item_type) DO UPDATE SET
      quantity = public.user_items.quantity + EXCLUDED.quantity,
      updated_at = NOW();
  END IF;

  RETURN jsonb_build_object('success', TRUE);
END;
$$;

REVOKE ALL ON FUNCTION public.grant_user_items(UUID, TEXT, INT, BOOLEAN) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.grant_user_items(UUID, TEXT, INT, BOOLEAN) TO service_role;

CREATE OR REPLACE FUNCTION public.record_purchase(
  p_user_id UUID,
  p_product_id TEXT,
  p_amount_jpy INT DEFAULT NULL,
  p_store_txn_id TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF p_store_txn_id IS NOT NULL AND p_store_txn_id <> '' THEN
    IF EXISTS (
      SELECT 1 FROM public.purchase_history WHERE store_txn_id = p_store_txn_id
    ) THEN
      RETURN jsonb_build_object('success', TRUE, 'duplicate', TRUE);
    END IF;
    INSERT INTO public.purchase_history (user_id, product_id, amount_jpy, store_txn_id)
    VALUES (p_user_id, p_product_id, p_amount_jpy, p_store_txn_id);
  ELSE
    INSERT INTO public.purchase_history (user_id, product_id, amount_jpy)
    VALUES (p_user_id, p_product_id, p_amount_jpy);
  END IF;
  RETURN jsonb_build_object('success', TRUE);
END;
$$;

REVOKE ALL ON FUNCTION public.record_purchase(UUID, TEXT, INT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.record_purchase(UUID, TEXT, INT, TEXT) TO service_role;
