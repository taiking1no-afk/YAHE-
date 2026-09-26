-- ============================================================
-- Migration v1.37 : 「気になるカスタム」機能
-- Supabase SQL Editor で実行してください。前提: v1.34（app_notifications）・
-- v1.36（vehicle_customization_parts）実行済み。
-- ------------------------------------------------------------
-- 目的:
--   マッチ済みの相手の車について、気になるカスタムカテゴリを選んで
--   知らせられるようにする。send_like と同じ「呼び出し元が本当に
--   マッチ済みか検証してから処理する」パターンに従う。
--
--   何度実行しても安全（冪等）。
-- ============================================================

CREATE TABLE IF NOT EXISTS public.custom_interest (
  interest_id  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  from_user_id UUID NOT NULL REFERENCES public.users(user_id) ON DELETE CASCADE,
  to_user_id   UUID NOT NULL REFERENCES public.users(user_id) ON DELETE CASCADE,
  vehicle_id   UUID NOT NULL REFERENCES public.vehicles(vehicle_id) ON DELETE CASCADE,
  category     TEXT NOT NULL CHECK (category IN (
                 'suspension', 'wheel', 'exhaust', 'aero', 'ecu', 'tire'
               )),
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT custom_interest_no_self CHECK (from_user_id <> to_user_id),
  CONSTRAINT custom_interest_unique UNIQUE (from_user_id, vehicle_id, category)
);

CREATE INDEX IF NOT EXISTS idx_custom_interest_to_user ON public.custom_interest(to_user_id);

ALTER TABLE public.custom_interest ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "custom_interest_select_participant" ON public.custom_interest;
CREATE POLICY "custom_interest_select_participant" ON public.custom_interest
  FOR SELECT USING (
    from_user_id IN (SELECT user_id FROM public.users WHERE auth_id = auth.uid())
    OR to_user_id IN (SELECT user_id FROM public.users WHERE auth_id = auth.uid())
  );

-- クライアントからの直接INSERTは禁止（RPC経由のみ）
REVOKE INSERT, UPDATE, DELETE ON public.custom_interest FROM authenticated, anon;

-- ============================================================
-- 送信RPC（送信者と車両オーナーが matches の当事者であることを検証）
-- ============================================================
CREATE OR REPLACE FUNCTION public.send_custom_interest(
  p_vehicle_id UUID,
  p_categories TEXT[]
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_id UUID;
  v_owner_id  UUID;
  v_m1        UUID;
  v_m2        UUID;
  v_category  TEXT;
  v_inserted  INT := 0;
BEGIN
  SELECT user_id INTO v_caller_id FROM public.users WHERE auth_id = auth.uid();
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'unauthorized';
  END IF;

  SELECT user_id INTO v_owner_id FROM public.vehicles WHERE vehicle_id = p_vehicle_id;
  IF v_owner_id IS NULL THEN
    RAISE EXCEPTION 'vehicle not found';
  END IF;

  IF v_owner_id = v_caller_id THEN
    RAISE EXCEPTION 'cannot send interest to own vehicle';
  END IF;

  v_m1 := LEAST(v_caller_id, v_owner_id);
  v_m2 := GREATEST(v_caller_id, v_owner_id);

  IF NOT EXISTS (
    SELECT 1 FROM public.matches WHERE user_a_id = v_m1 AND user_b_id = v_m2
  ) THEN
    RAISE EXCEPTION 'not matched';
  END IF;

  FOREACH v_category IN ARRAY p_categories LOOP
    IF v_category NOT IN ('suspension', 'wheel', 'exhaust', 'aero', 'ecu', 'tire') THEN
      CONTINUE;
    END IF;

    INSERT INTO public.custom_interest (from_user_id, to_user_id, vehicle_id, category)
    VALUES (v_caller_id, v_owner_id, p_vehicle_id, v_category)
    ON CONFLICT (from_user_id, vehicle_id, category) DO NOTHING;

    IF FOUND THEN
      v_inserted := v_inserted + 1;
    END IF;
  END LOOP;

  IF v_inserted > 0 THEN
    PERFORM public.create_app_notification(
      v_owner_id,
      'custom_interest',
      jsonb_build_object('vehicle_id', p_vehicle_id, 'categories', p_categories),
      v_caller_id
    );
  END IF;

  RETURN jsonb_build_object('success', TRUE, 'inserted', v_inserted);
END;
$$;

REVOKE ALL ON FUNCTION public.send_custom_interest(UUID, TEXT[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.send_custom_interest(UUID, TEXT[]) TO authenticated;
