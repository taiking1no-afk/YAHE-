-- ============================================================
-- Migration v1.43 : 2人のアルバム
-- Supabase SQL Editor で実行してください。前提: v1.32・v1.42 実行済み。
-- ------------------------------------------------------------
-- 目的:
--   ペア単位の思い出タイムライン（初めてのすれ違い・一緒にツーリング/
--   イベント参加）。カウンタ増加と同じ処理内でトランザクショナルに記録する
--   （別途バッチ処理は不要）。
--
--   何度実行しても安全（冪等）。
-- ============================================================

CREATE TABLE IF NOT EXISTS public.pair_album_entries (
  entry_id       UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_a_id      UUID NOT NULL REFERENCES public.users(user_id) ON DELETE CASCADE,
  user_b_id      UUID NOT NULL REFERENCES public.users(user_id) ON DELETE CASCADE,
  milestone_type TEXT NOT NULL CHECK (milestone_type IN ('first_encounter', 'touring_together', 'event_together')),
  occurred_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  related_id     UUID,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT pair_album_entries_order CHECK (user_a_id < user_b_id)
);

CREATE INDEX IF NOT EXISTS idx_pair_album_entries_pair ON public.pair_album_entries(user_a_id, user_b_id, occurred_at);

ALTER TABLE public.pair_album_entries ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "pair_album_entries_select" ON public.pair_album_entries;
CREATE POLICY "pair_album_entries_select" ON public.pair_album_entries FOR SELECT USING (
  user_a_id IN (SELECT user_id FROM public.users WHERE auth_id = auth.uid())
  OR user_b_id IN (SELECT user_id FROM public.users WHERE auth_id = auth.uid())
);

-- クライアントからの直接INSERTは禁止（内部関数からのみ）
REVOKE INSERT, UPDATE, DELETE ON public.pair_album_entries FROM authenticated, anon;

-- ============================================================
-- _register_encounter_one を再定義し、初めてのすれ違い(occurrence=1)を
-- アルバムに記録する（v1.32の内容 + 末尾の1ブロックのみ追加）
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
END;
$$;

REVOKE ALL ON FUNCTION public._register_encounter_one(uuid, uuid, boolean) FROM PUBLIC;
