-- ============================================================
-- Migration v1.101 : privacy_zones（自宅・職場）をすれ違い検知に反映
-- Supabase SQL Editor で実行してください。前提: v1.16, v1.88実行済み。
-- ------------------------------------------------------------
-- 背景:
--   privacy_zones テーブルは自宅・職場座標を保持しRLSで他人から閲覧
--   不可能だったが（データ漏洩は無い）、nearby_user_ids() /
--   register_encounter() / _register_encounter_one() のどこからも
--   参照されておらず、実際のすれ違い検知抑制には機能していなかった
--   （保存されているだけの不活性データだった）。
--
--   「自分が現在、自分の登録したプライバシーゾーン（自宅/職場）の中に
--   いる間は、すれ違いを新規登録しない」という形で、ペアごとではなく
--   自分自身の判断で機能するようにする（相手のゾーンは互いに見えない
--   設計を維持したまま実現できるシンプルな方式）。
--
--   何度実行しても安全（冪等）。
-- ============================================================

-- ① 「今、自分の有効なプライバシーゾーン内にいるか」を判定するヘルパー
CREATE OR REPLACE FUNCTION public._is_within_own_privacy_zone(p_user_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.user_locations ul
    JOIN public.privacy_zones pz ON pz.user_id = ul.user_id AND pz.is_active = TRUE
    WHERE ul.user_id = p_user_id
      AND 6371000 * 2 * asin(
            sqrt(
              power(sin(radians(ul.lat - pz.lat) / 2), 2)
              + cos(radians(pz.lat)) * cos(radians(ul.lat))
                * power(sin(radians(ul.lng - pz.lng) / 2), 2)
            )
          ) <= pz.radius_m
  );
$$;

REVOKE ALL ON FUNCTION public._is_within_own_privacy_zone(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public._is_within_own_privacy_zone(uuid) TO authenticated;

-- ② register_encounter（GPS単発版）にプライバシーゾーン判定を追加
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

  -- 自宅・職場等のプライバシーゾーン内にいる間はすれ違いを登録しない
  IF public._is_within_own_privacy_zone(v_my_user_id)
     OR public._is_within_own_privacy_zone(p_other_user_id) THEN
    RETURN;
  END IF;

  IF NOT public.users_can_pass(v_my_user_id, p_other_user_id) THEN
    RETURN;
  END IF;

  v_sorted_a := LEAST(v_my_user_id, p_other_user_id);
  v_sorted_b := GREATEST(v_my_user_id, p_other_user_id);

  IF EXISTS (
    SELECT 1 FROM public.encounters
    WHERE user_a_id = v_sorted_a AND user_b_id = v_sorted_b
      AND time > now() - interval '1 day'
  ) THEN
    RETURN;
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

  INSERT INTO public.encounters (user_a_id, user_b_id, time, expires_at, occurrence_number)
  VALUES (v_sorted_a, v_sorted_b, now(), v_expires_at, v_occurrence);

  IF v_occurrence = 1 THEN
    INSERT INTO public.pair_album_entries (user_a_id, user_b_id, milestone_type, occurred_at)
    VALUES (v_sorted_a, v_sorted_b, 'first_encounter', now());
  END IF;
END;
$$;

-- ③ _register_encounter_one（BLEバッチ版、register_encounters_batchの内部関数）
--    にも同様の判定を追加
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

  -- 自宅・職場等のプライバシーゾーン内にいる間はすれ違いを登録しない
  IF public._is_within_own_privacy_zone(v_my_user_id)
     OR public._is_within_own_privacy_zone(p_other_user_id) THEN
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

  IF v_occurrence = 1 THEN
    INSERT INTO public.pair_album_entries (user_a_id, user_b_id, milestone_type, occurred_at)
    VALUES (v_sorted_a, v_sorted_b, 'first_encounter', now());
  END IF;

  RETURN true;
END;
$function$;

-- ④ 旧シグネチャの register_encounter(uuid) は v1.21 で
--    register_encounter(uuid, boolean)（_register_encounter_one に委譲する
--    薄いラッパー）に置き換えられて以降、呼び出し元が存在しない残骸
--    （実際にFlutter側が呼ぶのは register_encounter(uuid, boolean) のみ）。
--    ②で直接ボディを更新してしまったが、正しい適用対象は
--    _register_encounter_one（③、こちらに委譲される）であり、
--    このオーバーロードを残すとロジックが二重管理になるため削除する。
DROP FUNCTION IF EXISTS public.register_encounter(uuid);

-- ============================================================
-- 動作確認用クエリ（手動実行）
-- ============================================================
-- SELECT pg_get_function_identity_arguments(oid) FROM pg_proc WHERE proname = 'register_encounter';
-- 期待値: 'p_other_user_id uuid, p_test_mode boolean' の1件のみ
-- SELECT prosrc ILIKE '%_is_within_own_privacy_zone%' FROM pg_proc WHERE proname = '_register_encounter_one';
-- 期待値: true
