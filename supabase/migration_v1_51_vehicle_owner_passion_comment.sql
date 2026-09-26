-- ============================================================
-- Migration v1.51 : 「オーナーの一言」をパーツ単位から車単位に変更
-- Supabase SQL Editor で実行してください。前提: v1.13（ng_words）, v1.36（カスタムパーツ）実行済み。
-- ------------------------------------------------------------
-- 背景:
--   「オーナーの一言」は各カスタムパーツ（車高調・ホイール等）ごとの
--   コメントとして実装されていたが、本来は「この車のここが好き」という
--   車1台に対する一言であるべき、という指摘を受けて修正する。
--   vehicle_customization_parts.owner_comment は廃止しない（データは残す）が、
--   以後クライアントからは書き込まなくなる。代わりに vehicles テーブルに
--   車単位のコメント列を追加する。
--
--   何度実行しても安全（冪等）。
-- ============================================================

ALTER TABLE public.vehicles ADD COLUMN IF NOT EXISTS owner_passion_comment TEXT;

-- NGワード検知（既存のscan_customization_ng_wordsと同じ辞書・方針。他人に見える自由記述のため）
CREATE OR REPLACE FUNCTION public.scan_vehicle_owner_passion_ng_words()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_word         RECORD;
  v_hit_critical BOOLEAN := FALSE;
  v_text         TEXT;
BEGIN
  IF NEW.owner_passion_comment IS NULL OR NEW.owner_passion_comment = '' THEN
    RETURN NEW;
  END IF;

  v_text := lower(NEW.owner_passion_comment);

  FOR v_word IN SELECT word, severity FROM public.ng_words LOOP
    IF position(lower(v_word.word) IN v_text) > 0 THEN
      INSERT INTO public.moderation_flags (user_id, reason, severity, field, snippet)
      VALUES (NEW.user_id, 'ng_word:' || v_word.word, v_word.severity, 'vehicle_owner_passion_comment', v_word.word);
      IF v_word.severity = 'critical' THEN
        v_hit_critical := TRUE;
      END IF;
    END IF;
  END LOOP;

  IF v_hit_critical THEN
    UPDATE public.users SET is_suspended = TRUE WHERE user_id = NEW.user_id;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_scan_vehicle_owner_passion_ng_words ON public.vehicles;
CREATE TRIGGER trg_scan_vehicle_owner_passion_ng_words
BEFORE INSERT OR UPDATE OF owner_passion_comment ON public.vehicles
FOR EACH ROW
EXECUTE FUNCTION public.scan_vehicle_owner_passion_ng_words();
