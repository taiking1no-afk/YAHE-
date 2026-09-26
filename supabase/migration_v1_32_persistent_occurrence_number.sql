-- ============================================================
-- v1.32: 「初めてのすれ違い」表示のバグ修正
-- ------------------------------------------------------------
-- 背景:
--   occurrence_number（同一ペアで何回目のすれ違いか。1=初回）は
--   `SELECT COUNT(*) + 1 FROM encounters WHERE user_a_id=... AND user_b_id=...`
--   で計算していた。encounters は無料24h/有料7dで期限切れ削除される
--   仕様のため、以前すれ違った相手でも、その時のencounters行が
--   削除された後に再会すると COUNT(*) が 0 に戻ってしまい、
--   実際は再会（2回目以降）なのに「初めてのすれ違い」と誤表示していた。
--
-- 方針:
--   ペアごとの累計すれ違い回数を、encountersの行の生死とは独立に
--   保持する専用テーブル encounter_pair_counters を新設し、
--   そこから occurrence_number を採番する。
-- ============================================================

CREATE TABLE IF NOT EXISTS public.encounter_pair_counters (
  user_a_id    UUID NOT NULL REFERENCES public.users(user_id) ON DELETE CASCADE,
  user_b_id    UUID NOT NULL REFERENCES public.users(user_id) ON DELETE CASCADE,
  total_count  INT NOT NULL DEFAULT 0,
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (user_a_id, user_b_id),
  CONSTRAINT encounter_pair_counters_order CHECK (user_a_id < user_b_id)
);

ALTER TABLE public.encounter_pair_counters ENABLE ROW LEVEL SECURITY;
-- クライアントから直接読み書きさせない（SECURITY DEFINER 関数経由のみ）
REVOKE ALL ON public.encounter_pair_counters FROM PUBLIC, authenticated, anon;

-- 既存の encounters（まだ削除されていない分）から初期値を移行しておく。
-- 過去に既に削除された分の履歴は復元できないが、これ以降は正しく積み上がる。
INSERT INTO public.encounter_pair_counters (user_a_id, user_b_id, total_count)
SELECT user_a_id, user_b_id, COUNT(*)
FROM public.encounters
GROUP BY user_a_id, user_b_id
ON CONFLICT (user_a_id, user_b_id) DO UPDATE
  SET total_count = GREATEST(public.encounter_pair_counters.total_count, EXCLUDED.total_count);

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

  -- occurrence_number は encounters 行の生死とは独立な永続カウンタから採番する
  -- （encounters は期限切れで削除されるため、そこからCOUNTすると履歴が失われていた）
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
END;
$$;

-- v_my_user_id は呼び出し元(register_encounter / register_encounters_batch)側で
-- auth.uid() から検証済みの値のみが渡される想定のため、この関数自体は
-- authenticated へ直接GRANTしない（内部呼び出し専用のまま維持する）
REVOKE ALL ON FUNCTION public._register_encounter_one(uuid, uuid, boolean) FROM PUBLIC;
