-- ============================================================
-- migration_v1_21: すれ違い一括登録RPC
-- 集会など同一時刻に多数のユーザーを検知するケースで、1人ずつRPCを
-- 呼ぶことによるサーバー負荷の急増を防ぐため、複数人分をまとめて
-- 1回のRPC呼び出しで登録できる register_encounters_batch を追加する。
--
-- register_encounter の本体ロジックは _register_encounter_one に切り出し、
-- 単発版・バッチ版の両方から呼ぶ（ロジックの重複・乖離を防ぐため）。
-- ============================================================

-- ── 共通ロジック（直接は呼ばせない内部ヘルパー） ──────────────
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

-- ヘルパーは register_encounter / register_encounters_batch からのみ呼ばれる想定。
-- authenticated ロールへの直接 EXECUTE 権限は与えない。
REVOKE ALL ON FUNCTION public._register_encounter_one(uuid, uuid, boolean) FROM public;

-- ── 単発版：ヘルパーを呼ぶだけに簡略化（挙動は従来と同一） ──────────
CREATE OR REPLACE FUNCTION public.register_encounter(
  p_other_user_id uuid,
  p_test_mode     boolean DEFAULT false
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_my_user_id uuid;
BEGIN
  SELECT user_id INTO v_my_user_id
  FROM public.users
  WHERE auth_id = auth.uid();

  IF v_my_user_id IS NULL THEN
    RAISE EXCEPTION 'not authenticated';
  END IF;

  PERFORM public._register_encounter_one(v_my_user_id, p_other_user_id, p_test_mode);
END;
$$;

REVOKE ALL ON FUNCTION public.register_encounter(uuid, boolean) FROM public;
GRANT EXECUTE ON FUNCTION public.register_encounter(uuid, boolean) TO authenticated;

-- ── バッチ版：複数の相手を1回のRPC呼び出しでまとめて登録 ──────────
CREATE OR REPLACE FUNCTION public.register_encounters_batch(
  p_other_user_ids uuid[],
  p_test_mode      boolean DEFAULT false
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_my_user_id uuid;
  v_other_id   uuid;
BEGIN
  SELECT user_id INTO v_my_user_id
  FROM public.users
  WHERE auth_id = auth.uid();

  IF v_my_user_id IS NULL THEN
    RAISE EXCEPTION 'not authenticated';
  END IF;

  IF p_other_user_ids IS NULL OR array_length(p_other_user_ids, 1) IS NULL THEN
    RETURN;
  END IF;

  -- 1回のバッチで処理する人数に上限を設け、異常に大きい配列による
  -- 負荷やDoS的な乱用を防ぐ（実際の密集シーンでも十分な余裕を持たせた値）
  IF array_length(p_other_user_ids, 1) > 200 THEN
    RAISE EXCEPTION 'too many user ids in one batch (max 200)';
  END IF;

  FOREACH v_other_id IN ARRAY p_other_user_ids LOOP
    PERFORM public._register_encounter_one(v_my_user_id, v_other_id, p_test_mode);
  END LOOP;
END;
$$;

REVOKE ALL ON FUNCTION public.register_encounters_batch(uuid[], boolean) FROM public;
GRANT EXECUTE ON FUNCTION public.register_encounters_batch(uuid[], boolean) TO authenticated;
