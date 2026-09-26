-- ============================================================
-- Migration v1.42 : 関係レベル制度（親密度）
-- Supabase SQL Editor で実行してください。前提: v1.32（encounter_pair_counters）
-- 実行済み。
-- ------------------------------------------------------------
-- 目的:
--   ペア単位の永続カウンタ(encounter_pair_counters)を拡張し、すれ違い回数
--   ＋一緒にドライブ(ツーリング)/イベントに参加した回数を合算してレベルを
--   算出する。「一緒にいた時間」は実測せず回数ベースのみで判定する（合意事項）。
--
--   何度実行しても安全（冪等）。
-- ============================================================

ALTER TABLE public.encounter_pair_counters
  ADD COLUMN IF NOT EXISTS drive_together_count INT NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS event_together_count INT NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS level INT NOT NULL DEFAULT 1;

-- ============================================================
-- レベル算出（閾値はここで一元管理。後で調整しやすいようスキーマ変更なしで
-- 済むよう関数に切り出す。初期値は仮の単純な階段式）
-- ============================================================
CREATE OR REPLACE FUNCTION public.compute_level(
  p_total_count INT,
  p_drive_count INT,
  p_event_count INT
)
RETURNS INT
LANGUAGE sql
IMMUTABLE
AS $$
  -- スコア = すれ違い回数 + ドライブ回数x3 + イベント回数x3
  -- （一緒に何かに参加した方が単純なすれ違いより関係性への寄与が大きいとみなす）
  -- レベル1: 0〜4, レベル2: 5〜9, ... 5点ごとに+1、上限なし
  SELECT GREATEST(1, 1 + FLOOR((p_total_count + p_drive_count * 3 + p_event_count * 3) / 5.0)::INT);
$$;

CREATE OR REPLACE FUNCTION public._sync_pair_level()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.level := public.compute_level(NEW.total_count, NEW.drive_together_count, NEW.event_together_count);
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_sync_pair_level ON public.encounter_pair_counters;
CREATE TRIGGER trg_sync_pair_level
BEFORE INSERT OR UPDATE OF total_count, drive_together_count, event_together_count
ON public.encounter_pair_counters
FOR EACH ROW
EXECUTE FUNCTION public._sync_pair_level();

-- 既存行のレベルを再計算
UPDATE public.encounter_pair_counters
SET total_count = total_count;

-- ============================================================
-- 「一緒に参加した回数」を+1する（掲示板のjoin_board_post RPCから呼ばれる）
-- ============================================================
CREATE OR REPLACE FUNCTION public.increment_together_count(
  p_user_a UUID,
  p_user_b UUID,
  p_post_id UUID
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_a UUID := LEAST(p_user_a, p_user_b);
  v_b UUID := GREATEST(p_user_a, p_user_b);
  v_post_type TEXT;
  v_milestone TEXT;
BEGIN
  SELECT post_type INTO v_post_type FROM public.board_posts WHERE post_id = p_post_id;
  IF v_post_type IS NULL THEN
    RETURN;
  END IF;

  INSERT INTO public.encounter_pair_counters (user_a_id, user_b_id, drive_together_count, event_together_count)
  VALUES (
    v_a, v_b,
    CASE WHEN v_post_type = 'touring' THEN 1 ELSE 0 END,
    CASE WHEN v_post_type = 'event' THEN 1 ELSE 0 END
  )
  ON CONFLICT (user_a_id, user_b_id) DO UPDATE SET
    drive_together_count = public.encounter_pair_counters.drive_together_count
      + (CASE WHEN v_post_type = 'touring' THEN 1 ELSE 0 END),
    event_together_count = public.encounter_pair_counters.event_together_count
      + (CASE WHEN v_post_type = 'event' THEN 1 ELSE 0 END),
    updated_at = NOW();

  v_milestone := CASE WHEN v_post_type = 'touring' THEN 'touring_together' ELSE 'event_together' END;

  -- アルバムへの記録（v1.43未適用環境でも安全に無視する）
  BEGIN
    INSERT INTO public.pair_album_entries (user_a_id, user_b_id, milestone_type, occurred_at, related_id)
    VALUES (v_a, v_b, v_milestone, NOW(), p_post_id);
  EXCEPTION WHEN undefined_table THEN
    NULL;
  END;
END;
$$;

REVOKE ALL ON FUNCTION public.increment_together_count(UUID, UUID, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.increment_together_count(UUID, UUID, UUID) TO service_role, authenticated;

-- ============================================================
-- 読み取りRPC（このテーブルはクライアントから直接読めないため新設）
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_pair_relationship(p_other_user_id UUID)
RETURNS TABLE(
  total_count INT,
  drive_together_count INT,
  event_together_count INT,
  level INT
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_id UUID;
  v_a UUID;
  v_b UUID;
BEGIN
  SELECT user_id INTO v_caller_id FROM public.users WHERE auth_id = auth.uid();
  IF v_caller_id IS NULL THEN
    RETURN;
  END IF;

  v_a := LEAST(v_caller_id, p_other_user_id);
  v_b := GREATEST(v_caller_id, p_other_user_id);

  RETURN QUERY
  SELECT epc.total_count, epc.drive_together_count, epc.event_together_count, epc.level
  FROM public.encounter_pair_counters epc
  WHERE epc.user_a_id = v_a AND epc.user_b_id = v_b;
END;
$$;

REVOKE ALL ON FUNCTION public.get_pair_relationship(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_pair_relationship(UUID) TO authenticated;
