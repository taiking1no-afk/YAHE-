-- ============================================================
-- Migration v1.28 : 本番運用前ハードニング
-- 前提: v1.27 適用済み。冪等。
-- ------------------------------------------------------------
-- ① activate_timed_item: gear_plus_24h は quantity>0 のときのみ発動
-- ② fulfill_consumable_purchase: txn 冪等で付与（二重付与防止）
-- ③ send_like: 期限切れ encounter でもいいね可 / 相互は相手ユーザー単位でマッチ
-- ④ likes: (from,to) 一意化 + マッチ後の取消禁止
-- ⑤ debug_seed_encounters を authenticated から剥奪
-- ⑥ user_locations SELECT 再確認（v1.26 退行の恒久ガード）
-- ============================================================


-- ============================================================
-- ⑥ user_locations SELECT（再適用・安全）
-- ============================================================
DROP POLICY IF EXISTS "locations_select_authenticated" ON public.user_locations;
DROP POLICY IF EXISTS "locations_select_own" ON public.user_locations;

CREATE POLICY "locations_select_own" ON public.user_locations
  FOR SELECT USING (
    user_id IN (SELECT user_id FROM public.users WHERE auth_id = auth.uid())
  );


-- ============================================================
-- ④ likes: 同一相手への重複いいねを排除し (from,to) 一意に
-- ============================================================
-- 古い重複は1件を残す（ctid で安定削除）
DELETE FROM public.likes a
USING public.likes b
WHERE a.from_user_id = b.from_user_id
  AND a.to_user_id = b.to_user_id
  AND a.ctid < b.ctid;

ALTER TABLE public.likes DROP CONSTRAINT IF EXISTS likes_unique;
DROP INDEX IF EXISTS likes_unique;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'likes_unique_pair'
      AND conrelid = 'public.likes'::regclass
  ) THEN
    ALTER TABLE public.likes
      ADD CONSTRAINT likes_unique_pair UNIQUE (from_user_id, to_user_id);
  END IF;
END $$;

DROP POLICY IF EXISTS "likes_delete_own" ON public.likes;
CREATE POLICY "likes_delete_own" ON public.likes FOR DELETE USING (
  from_user_id IN (SELECT user_id FROM public.users WHERE auth_id = auth.uid())
  AND NOT EXISTS (
    SELECT 1 FROM public.matches m
    WHERE (m.user_a_id = LEAST(likes.from_user_id, likes.to_user_id)
       AND m.user_b_id = GREATEST(likes.from_user_id, likes.to_user_id))
  )
);


-- ============================================================
-- ③ send_like: 別日 encounter でもマッチ / 期限切れでもいいね返し可
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
  v_rowcount     INT := 0;
BEGIN
  SELECT user_id INTO v_caller FROM public.users WHERE auth_id = auth.uid();
  IF v_caller IS NULL OR v_caller <> p_from_user_id THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'forbidden');
  END IF;

  IF p_from_user_id = p_to_user_id THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'invalid_target');
  END IF;

  SELECT user_a_id, user_b_id
  INTO v_enc_a, v_enc_b
  FROM public.encounters
  WHERE encounter_id = p_encounter_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'encounter_not_found');
  END IF;

  -- 期限切れでも「いいねされた」からの返し・別日マッチを許可する
  -- （ホームの表示期限は encounters.expires_at / クライアントフィルタで別管理）
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
  ON CONFLICT (from_user_id, to_user_id) DO NOTHING;

  GET DIAGNOSTICS v_rowcount = ROW_COUNT;

  -- 相手ユーザー単位で相互いいねを判定（encounter_id / すれ違い日は問わない）
  IF EXISTS (
    SELECT 1 FROM public.likes
    WHERE from_user_id = p_to_user_id
      AND to_user_id = p_from_user_id
  ) OR EXISTS (
    SELECT 1 FROM public.matches
    WHERE user_a_id = LEAST(p_from_user_id, p_to_user_id)
      AND user_b_id = GREATEST(p_from_user_id, p_to_user_id)
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
    'already_liked', (v_rowcount = 0)
  );
END;
$$;

REVOKE ALL ON FUNCTION public.send_like(UUID, UUID, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.send_like(UUID, UUID, UUID) TO authenticated;


-- ============================================================
-- ① activate_timed_item: gear_plus_24h の無制限延長を禁止
-- ============================================================
CREATE OR REPLACE FUNCTION public.activate_timed_item(p_item_type TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid UUID;
  v_qty INT;
  v_duration INTERVAL;
  v_until TIMESTAMPTZ;
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

  -- 全タイプ共通: 所持数がなければ発動不可（qty=0 での無制限延長を防ぐ）
  IF COALESCE(v_qty, 0) <= 0 THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'insufficient_quantity');
  END IF;

  UPDATE public.user_items
  SET quantity = quantity - 1,
      active_until = CASE
        WHEN p_item_type = 'gear_plus_24h'
          AND active_until IS NOT NULL
          AND active_until > NOW()
        THEN active_until + v_duration
        ELSE v_until
      END,
      updated_at = NOW()
  WHERE user_id = v_uid AND item_type = p_item_type
  RETURNING active_until INTO v_until;

  IF p_item_type = 'gear_plus_24h' THEN
    UPDATE public.users
    SET
      premium_override_plan = 'gear_plus',
      premium_override_expires_at = v_until,
      premium_override_source = COALESCE(premium_override_source, 'purchase'),
      premium_override_reason = 'gear_plus_24h'
    WHERE user_id = v_uid;

    PERFORM public.sync_user_premium(v_uid);
  END IF;

  RETURN jsonb_build_object('success', TRUE, 'active_until', v_until);
END;
$$;

REVOKE ALL ON FUNCTION public.activate_timed_item(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.activate_timed_item(TEXT) TO authenticated;


-- ============================================================
-- ② 消耗型の原子的付与（Webhook / sync 共用）
--    purchase_history を先に INSERT（unique）→ 成功時のみ grant
-- ============================================================
CREATE OR REPLACE FUNCTION public.fulfill_consumable_purchase(
  p_user_id UUID,
  p_product_id TEXT,
  p_store_txn_id TEXT,
  p_amount_jpy INT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_item_type TEXT;
  v_count INT;
  v_activate BOOLEAN;
BEGIN
  IF p_user_id IS NULL OR p_store_txn_id IS NULL OR btrim(p_store_txn_id) = '' THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'invalid_args');
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.purchase_history WHERE store_txn_id = p_store_txn_id
  ) THEN
    RETURN jsonb_build_object('success', TRUE, 'duplicate', TRUE);
  END IF;

  CASE p_product_id
    WHEN 'yahe_nitro_1h' THEN
      v_item_type := 'nitro'; v_count := 1; v_activate := FALSE;
    WHEN 'yahe_shibu_10' THEN
      v_item_type := 'shibu'; v_count := 10; v_activate := FALSE;
    WHEN 'yahe_super_nitro_1h' THEN
      v_item_type := 'super_nitro'; v_count := 1; v_activate := FALSE;
    WHEN 'yahe_geki_shibu_10' THEN
      v_item_type := 'geki_shibu'; v_count := 10; v_activate := FALSE;
    WHEN 'yahe_gear_plus_24h' THEN
      v_item_type := 'gear_plus_24h'; v_count := 1; v_activate := TRUE;
    ELSE
      RETURN jsonb_build_object('success', FALSE, 'error', 'unknown_product');
  END CASE;

  BEGIN
    INSERT INTO public.purchase_history (user_id, product_id, amount_jpy, store_txn_id)
    VALUES (p_user_id, p_product_id, p_amount_jpy, p_store_txn_id);
  EXCEPTION
    WHEN unique_violation THEN
      RETURN jsonb_build_object('success', TRUE, 'duplicate', TRUE);
  END;

  PERFORM public.grant_user_items(p_user_id, v_item_type, v_count, v_activate);

  RETURN jsonb_build_object(
    'success', TRUE,
    'duplicate', FALSE,
    'item_type', v_item_type,
    'count', v_count
  );
END;
$$;

REVOKE ALL ON FUNCTION public.fulfill_consumable_purchase(UUID, TEXT, TEXT, INT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.fulfill_consumable_purchase(UUID, TEXT, TEXT, INT) FROM authenticated;
REVOKE ALL ON FUNCTION public.fulfill_consumable_purchase(UUID, TEXT, TEXT, INT) FROM anon;
GRANT EXECUTE ON FUNCTION public.fulfill_consumable_purchase(UUID, TEXT, TEXT, INT) TO service_role;


-- ============================================================
-- ⑤ debug_seed_encounters を本番クライアントから呼べなくする
-- ============================================================
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'debug_seed_encounters'
  ) THEN
    EXECUTE 'REVOKE ALL ON FUNCTION public.debug_seed_encounters(uuid, integer) FROM PUBLIC';
    EXECUTE 'REVOKE ALL ON FUNCTION public.debug_seed_encounters(uuid, integer) FROM authenticated';
    EXECUTE 'REVOKE ALL ON FUNCTION public.debug_seed_encounters(uuid, integer) FROM anon';
    -- 運営が SQL Editor / service_role でのみ使えるようにする
    EXECUTE 'GRANT EXECUTE ON FUNCTION public.debug_seed_encounters(uuid, integer) TO service_role';
  END IF;
END $$;

-- 課金 RPC が authenticated に戻っていないことの再確認
REVOKE ALL ON FUNCTION public.sync_subscription_plan(UUID, TEXT, TIMESTAMPTZ, BOOLEAN) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.sync_subscription_plan(UUID, TEXT, TIMESTAMPTZ, BOOLEAN) FROM authenticated;
REVOKE ALL ON FUNCTION public.sync_subscription_plan(UUID, TEXT, TIMESTAMPTZ, BOOLEAN) FROM anon;
GRANT EXECUTE ON FUNCTION public.sync_subscription_plan(UUID, TEXT, TIMESTAMPTZ, BOOLEAN) TO service_role;

REVOKE ALL ON FUNCTION public.grant_gear_plus(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.grant_gear_plus(UUID) FROM authenticated;
REVOKE ALL ON FUNCTION public.grant_gear_plus(UUID) FROM anon;
GRANT EXECUTE ON FUNCTION public.grant_gear_plus(UUID) TO service_role;
