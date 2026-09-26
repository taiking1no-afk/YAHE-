-- ============================================================
-- Migration v1.88 : register_encounters_batch が実際に登録した相手だけを返すようにする
-- Supabase SQL Editor で実行してください。前提: v1.21（register_encounters_batch）まで適用済み。
-- ------------------------------------------------------------
-- 目的:
--   register_encounters_batch / _register_encounter_one は RETURNS void のため、
--   ブロック済み・愛車未登録（users_can_pass）・重複防止期間内などの理由で
--   実際には1件も登録していなくても例外を投げずに正常終了していた。
--   クライアント（ble_encounter_service.dart）はこれを区別できず、
--   RPCが例外を投げなかった＝成功とみなして無条件にプッシュ通知を送っていたため、
--   「すれ違い通知は来るが一覧には出てこない（DBには何も登録されていない）」
--   という不整合が起きていた。
--
--   実際に新規登録できた相手のuser_idだけを返すように変更し、
--   クライアント側はその相手にだけ通知を送るようにする。
--
--   何度実行しても安全（冪等）。
-- ============================================================

DROP FUNCTION IF EXISTS public._register_encounter_one(uuid, uuid, boolean);

CREATE OR REPLACE FUNCTION public._register_encounter_one(v_my_user_id uuid, p_other_user_id uuid, p_test_mode boolean)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
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
    RETURN false;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.users WHERE user_id = p_other_user_id) THEN
    RETURN false;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.blocks b
    WHERE (b.blocker_id = v_my_user_id AND b.blocked_id = p_other_user_id)
       OR (b.blocker_id = p_other_user_id AND b.blocked_id = v_my_user_id)
  ) THEN
    RETURN false;
  END IF;

  IF NOT public.users_can_pass(v_my_user_id, p_other_user_id) THEN
    RETURN false;
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
    RETURN false;
  END IF;

  v_a_premium := public.user_is_premium(v_my_user_id);
  v_b_premium := public.user_is_premium(p_other_user_id);

  v_expires_at := CASE
    WHEN v_a_premium OR v_b_premium THEN now() + interval '7 days'
    ELSE now() + interval '24 hours'
  END;

  INSERT INTO public.encounter_pair_counters (user_a_id, user_b_id, total_count, updated_at)
  VALUES (v_sorted_a, v_sorted_b, 1, now())
  ON CONFLICT (user_a_id, user_b_id) DO UPDATE
    SET total_count = public.encounter_pair_counters.total_count + 1,
        updated_at = now()
  RETURNING total_count INTO v_occurrence;

  INSERT INTO public.encounters (
    user_a_id, user_b_id, time, expires_at, occurrence_number
  ) VALUES (
    v_sorted_a, v_sorted_b, now(), v_expires_at, v_occurrence
  );

  -- 初めてのすれ違いをアルバムに記録
  IF v_occurrence = 1 THEN
    INSERT INTO public.pair_album_entries (user_a_id, user_b_id, milestone_type, occurred_at)
    VALUES (v_sorted_a, v_sorted_b, 'first_encounter', now());
  END IF;

  RETURN true;
END;
$function$;

REVOKE ALL ON FUNCTION public._register_encounter_one(uuid, uuid, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public._register_encounter_one(uuid, uuid, boolean) TO authenticated;


DROP FUNCTION IF EXISTS public.register_encounters_batch(uuid[], boolean);

CREATE OR REPLACE FUNCTION public.register_encounters_batch(p_other_user_ids uuid[], p_test_mode boolean DEFAULT false)
RETURNS uuid[]
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_my_user_id uuid;
  v_other_id   uuid;
  v_registered uuid[] := ARRAY[]::uuid[];
BEGIN
  SELECT user_id INTO v_my_user_id
  FROM public.users
  WHERE auth_id = auth.uid();

  IF v_my_user_id IS NULL THEN
    RAISE EXCEPTION 'not authenticated';
  END IF;

  IF p_other_user_ids IS NULL OR array_length(p_other_user_ids, 1) IS NULL THEN
    RETURN v_registered;
  END IF;

  -- 1回のバッチで処理する人数に上限を設け、異常に大きい配列による
  -- 負荷やDoS的な乱用を防ぐ（実際の密集シーンでも十分な余裕を持たせた値）
  IF array_length(p_other_user_ids, 1) > 200 THEN
    RAISE EXCEPTION 'too many user ids in one batch (max 200)';
  END IF;

  FOREACH v_other_id IN ARRAY p_other_user_ids LOOP
    IF public._register_encounter_one(v_my_user_id, v_other_id, p_test_mode) THEN
      v_registered := array_append(v_registered, v_other_id);
    END IF;
  END LOOP;

  RETURN v_registered;
END;
$function$;

REVOKE ALL ON FUNCTION public.register_encounters_batch(uuid[], boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.register_encounters_batch(uuid[], boolean) TO authenticated;
