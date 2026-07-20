-- ============================================================
-- migration_v1_20: 同一相手とのすれ違いを1日1回に変更
-- テストアカウントは encounter_test_mode + p_test_mode で5分窓
-- ============================================================

ALTER TABLE public.users
  ADD COLUMN IF NOT EXISTS encounter_test_mode boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.users.encounter_test_mode IS
  'true のユーザーはアプリのテストモードON時に1日制限を5分窓に緩和';

DROP FUNCTION IF EXISTS public.register_encounter(uuid);

CREATE OR REPLACE FUNCTION public.register_encounter(
  p_other_user_id uuid,
  p_test_mode boolean DEFAULT false
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_my_user_id      uuid;
  v_sorted_a        uuid;
  v_sorted_b        uuid;
  v_a_premium       boolean;
  v_b_premium       boolean;
  v_expires_at      timestamptz;
  v_occurrence      integer;
  v_dedupe_interval interval := interval '1 day';
  v_test_allowed    boolean;
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

REVOKE ALL ON FUNCTION public.register_encounter(uuid, boolean) FROM public;
GRANT EXECUTE ON FUNCTION public.register_encounter(uuid, boolean) TO authenticated;

-- 実機テスト前にテスターの encounter_test_mode を true にしてください:
-- UPDATE public.users SET encounter_test_mode = true
-- WHERE user_id IN ('your-user-id', 'tester-user-id');
