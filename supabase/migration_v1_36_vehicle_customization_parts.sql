-- ============================================================
-- Migration v1.36 : カスタム詳細フィールドの構造化
-- Supabase SQL Editor で実行してください。前提: v1.13（NGワード辞書）実行済み。
-- ------------------------------------------------------------
-- 目的:
--   車高調・ホイール・マフラー・エアロ・ECU・タイヤを構造化フィールド化し、
--   それぞれにオーナーの一言を付けられるようにする。既存の custom_content
--   （自由記述）は削除せず「その他のカスタム」として存続させる。
--
--   何度実行しても安全（冪等）。
-- ============================================================

CREATE TABLE IF NOT EXISTS public.vehicle_customization_parts (
  part_id        UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  vehicle_id     UUID NOT NULL REFERENCES public.vehicles(vehicle_id) ON DELETE CASCADE,
  category       TEXT NOT NULL CHECK (category IN (
                   'suspension', 'wheel', 'exhaust', 'aero', 'ecu', 'tire'
                 )),
  brand          TEXT,
  spec_detail    TEXT,
  owner_comment  TEXT,
  display_order  INT NOT NULL DEFAULT 0,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT vehicle_customization_parts_unique UNIQUE (vehicle_id, category)
);

CREATE INDEX IF NOT EXISTS idx_vehicle_customization_parts_vehicle
  ON public.vehicle_customization_parts(vehicle_id);

DROP TRIGGER IF EXISTS vehicle_customization_parts_updated_at ON public.vehicle_customization_parts;
CREATE TRIGGER vehicle_customization_parts_updated_at BEFORE UPDATE ON public.vehicle_customization_parts
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

ALTER TABLE public.vehicle_customization_parts ENABLE ROW LEVEL SECURITY;

-- vehicles と同じ可視性ルール: オーナーは全権限、他人は is_active な車両のみ閲覧可
DROP POLICY IF EXISTS "vehicle_customization_parts_all_own" ON public.vehicle_customization_parts;
CREATE POLICY "vehicle_customization_parts_all_own" ON public.vehicle_customization_parts
  FOR ALL USING (
    vehicle_id IN (
      SELECT vehicle_id FROM public.vehicles
      WHERE user_id IN (SELECT user_id FROM public.users WHERE auth_id = auth.uid())
    )
  );

DROP POLICY IF EXISTS "vehicle_customization_parts_select_others" ON public.vehicle_customization_parts;
CREATE POLICY "vehicle_customization_parts_select_others" ON public.vehicle_customization_parts
  FOR SELECT USING (
    vehicle_id IN (SELECT vehicle_id FROM public.vehicles WHERE is_active = TRUE)
  );

-- ============================================================
-- NGワード自動検知の拡張（owner_comment）
--   既存の ng_words 辞書を再利用。moderation_flags には車両オーナーの
--   user_id を紐付けて記録する（vehicle_customization_parts自体には
--   user_id列がないため、vehiclesをJOINして解決する）。
-- ============================================================
CREATE OR REPLACE FUNCTION public.scan_customization_ng_words()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_word        RECORD;
  v_owner_id    UUID;
  v_hit_critical BOOLEAN := FALSE;
  v_text         TEXT;
BEGIN
  IF NEW.owner_comment IS NULL OR NEW.owner_comment = '' THEN
    RETURN NEW;
  END IF;

  SELECT user_id INTO v_owner_id FROM public.vehicles WHERE vehicle_id = NEW.vehicle_id;
  IF v_owner_id IS NULL THEN
    RETURN NEW;
  END IF;

  v_text := lower(NEW.owner_comment);

  FOR v_word IN SELECT word, severity FROM public.ng_words LOOP
    IF position(lower(v_word.word) IN v_text) > 0 THEN
      INSERT INTO public.moderation_flags (user_id, reason, severity, field, snippet)
      VALUES (v_owner_id, 'ng_word:' || v_word.word, v_word.severity, 'customization_comment', v_word.word);
      IF v_word.severity = 'critical' THEN
        v_hit_critical := TRUE;
      END IF;
    END IF;
  END LOOP;

  IF v_hit_critical THEN
    UPDATE public.users SET is_suspended = TRUE WHERE user_id = v_owner_id;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_scan_customization_ng_words ON public.vehicle_customization_parts;
CREATE TRIGGER trg_scan_customization_ng_words
BEFORE INSERT OR UPDATE OF owner_comment ON public.vehicle_customization_parts
FOR EACH ROW
EXECUTE FUNCTION public.scan_customization_ng_words();
