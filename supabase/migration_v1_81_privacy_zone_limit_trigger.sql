-- ============================================================
-- Migration v1.82 : 愛車ガード(プライバシーゾーン)の上限をサーバー側でも強制
-- Supabase SQL Editor で実行してください。
-- ------------------------------------------------------------
-- 背景: 無料プランの上限3ヶ所チェックがクライアント側のみで、しかも
--   キャッシュされたRiverpod providerの値（invalidate直後は一時的にnull=0
--   扱い）を見ていたため、地図を連打すると上限を超えて登録できてしまって
--   いた。createZone自体もクライアントからの直接insertでサーバー側の
--   チェックが一切無かったため、BEFORE INSERTトリガーで確実に強制する。
--
--   何度実行しても安全（冪等）。
-- ============================================================

CREATE OR REPLACE FUNCTION public._enforce_privacy_zone_limit()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_plan TEXT;
  v_count INT;
  v_limit CONSTANT INT := 3;
BEGIN
  v_plan := public.user_effective_plan(NEW.user_id);
  IF v_plan IN ('gear_plus', 'gear_r') THEN
    RETURN NEW; -- 有料プランは無制限
  END IF;

  SELECT count(*) INTO v_count FROM public.privacy_zones WHERE user_id = NEW.user_id;
  IF v_count >= v_limit THEN
    RAISE EXCEPTION 'privacy_zone_limit_reached';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_enforce_privacy_zone_limit ON public.privacy_zones;
CREATE TRIGGER trg_enforce_privacy_zone_limit
  BEFORE INSERT ON public.privacy_zones
  FOR EACH ROW
  EXECUTE FUNCTION public._enforce_privacy_zone_limit();
