-- ============================================================
-- v1.16 すれ違い対象（車 / バイク / 両方）
-- ------------------------------------------------------------
-- users.passing_target: ユーザーがすれ違いたい相手の種別
-- 愛車登録（vehicles.vehicle_type）: 自分がどの種別として検知されるか
-- register_encounter / nearby_user_ids で相互互換性をチェック
-- ============================================================

ALTER TABLE public.users
  ADD COLUMN IF NOT EXISTS passing_target TEXT NOT NULL DEFAULT 'both'
  CHECK (passing_target IN ('car', 'bike', 'both'));

COMMENT ON COLUMN public.users.passing_target IS
  'すれ違いたい相手: car=車のりのみ, bike=バイカーのみ, both=どちらも';

-- ユーザーのアクティブな愛車種別を取得
CREATE OR REPLACE FUNCTION public.user_vehicle_types(p_user_id uuid)
RETURNS text[]
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE(
    array_agg(DISTINCT v.vehicle_type ORDER BY v.vehicle_type),
    ARRAY[]::text[]
  )
  FROM public.vehicles v
  WHERE v.user_id = p_user_id
    AND v.is_active = TRUE;
$$;

REVOKE ALL ON FUNCTION public.user_vehicle_types(uuid) FROM public;
GRANT EXECUTE ON FUNCTION public.user_vehicle_types(uuid) TO authenticated;

-- 希望（passing_target）が相手の種別（vehicle_types）を包含するか
CREATE OR REPLACE FUNCTION public._passing_target_matches(
  p_target text,
  p_identity_types text[]
)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN p_target = 'both' THEN TRUE
    WHEN p_target = 'car'  THEN 'car'  = ANY(p_identity_types)
    WHEN p_target = 'bike' THEN 'bike' = ANY(p_identity_types)
    ELSE TRUE
  END;
$$;

-- 2ユーザー間ですれ違い可能か（双方向チェック）
CREATE OR REPLACE FUNCTION public.users_can_pass(
  p_user_a uuid,
  p_user_b uuid
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_types_a text[];
  v_types_b text[];
  v_target_a text;
  v_target_b text;
BEGIN
  v_types_a := public.user_vehicle_types(p_user_a);
  v_types_b := public.user_vehicle_types(p_user_b);

  IF COALESCE(array_length(v_types_a, 1), 0) = 0
     OR COALESCE(array_length(v_types_b, 1), 0) = 0 THEN
    RETURN FALSE;
  END IF;

  SELECT COALESCE(u.passing_target, 'both') INTO v_target_a
  FROM public.users u WHERE u.user_id = p_user_a;

  SELECT COALESCE(u.passing_target, 'both') INTO v_target_b
  FROM public.users u WHERE u.user_id = p_user_b;

  IF NOT public._passing_target_matches(v_target_a, v_types_b) THEN
    RETURN FALSE;
  END IF;

  IF NOT public._passing_target_matches(v_target_b, v_types_a) THEN
    RETURN FALSE;
  END IF;

  RETURN TRUE;
END;
$$;

REVOKE ALL ON FUNCTION public.users_can_pass(uuid, uuid) FROM public;
GRANT EXECUTE ON FUNCTION public.users_can_pass(uuid, uuid) TO authenticated;

-- nearby_user_ids: すれ違い対象が合うユーザーのみ返す
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
  JOIN public.users tu ON tu.user_id = ul.user_id
  WHERE ul.user_id <> (
          SELECT u.user_id FROM public.users u WHERE u.auth_id = auth.uid()
        )
    AND tu.is_suspended = FALSE
    AND NOT EXISTS (
      SELECT 1 FROM public.users me
      WHERE me.auth_id = auth.uid() AND me.is_suspended = TRUE
    )
    AND ul.updated_at > now() - make_interval(secs => p_max_age_seconds)
    AND 6371000 * 2 * asin(
          sqrt(
            power(sin(radians(ul.lat - p_lat) / 2), 2)
            + cos(radians(p_lat)) * cos(radians(ul.lat))
              * power(sin(radians(ul.lng - p_lng) / 2), 2)
          )
        ) <= p_radius_m
    AND public.users_can_pass(
          (SELECT u.user_id FROM public.users u WHERE u.auth_id = auth.uid()),
          ul.user_id
        );
$$;

REVOKE ALL  ON FUNCTION public.nearby_user_ids(double precision, double precision, double precision, integer) FROM public;
GRANT EXECUTE ON FUNCTION public.nearby_user_ids(double precision, double precision, double precision, integer) TO authenticated;

-- register_encounter: すれ違い対象チェックを追加
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
  SELECT user_id INTO v_my_user_id
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

  -- 愛車種別・すれ違い対象の相互互換性
  IF NOT public.users_can_pass(v_my_user_id, p_other_user_id) THEN
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

  v_a_premium := public.user_is_premium(v_my_user_id);
  v_b_premium := public.user_is_premium(p_other_user_id);

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
    user_a_id, user_b_id, time, expires_at, occurrence_number
  ) VALUES (
    v_sorted_a, v_sorted_b, now(), v_expires_at, v_occurrence
  );
END;
$$;

REVOKE ALL ON FUNCTION public.register_encounter(uuid) FROM public;
GRANT EXECUTE ON FUNCTION public.register_encounter(uuid) TO authenticated;
