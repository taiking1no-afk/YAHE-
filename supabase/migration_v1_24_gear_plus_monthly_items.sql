-- ============================================================
-- Migration v1.24 : Gear+ 月次アイテム付与
-- Supabase SQL Editor で実行してください。前提: v1.1〜v1.23 実行済み。
-- ------------------------------------------------------------
-- Gear+ プラン表示（プランカード・比較表）には「ニトロ 毎月1個 / 渋！ 毎月10個」と
-- 記載されているが、Gear R（migration_v1_17）と異なり付与を行う関数が存在しなかった。
-- grant_gear_r_monthly_items() と同じ形で Gear+ 専用の付与関数を追加する。
-- 対象は user_effective_plan = 'gear_plus' のユーザーのみ（gear_r は独自の
-- super_nitro / geki_shibu を受け取るため対象外）。
-- 何度実行しても安全（冪等）。
-- ============================================================

-- ニトロ +1 / 渋！ +10（既存所持数に加算）
CREATE OR REPLACE FUNCTION public.grant_gear_plus_monthly_items()
RETURNS TABLE(user_id UUID, nickname TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  r RECORD;
BEGIN
  FOR r IN
    SELECT u.user_id, u.nickname
    FROM public.users u
    WHERE public.user_effective_plan(u.user_id) = 'gear_plus'
      AND COALESCE(u.is_suspended, FALSE) = FALSE
  LOOP
    INSERT INTO public.user_items (user_id, item_type, quantity, updated_at)
    VALUES (r.user_id, 'nitro', 1, NOW())
    ON CONFLICT (user_id, item_type)
    DO UPDATE SET
      quantity   = public.user_items.quantity + 1,
      updated_at = NOW();

    INSERT INTO public.user_items (user_id, item_type, quantity, updated_at)
    VALUES (r.user_id, 'shibu', 10, NOW())
    ON CONFLICT (user_id, item_type)
    DO UPDATE SET
      quantity   = public.user_items.quantity + 10,
      updated_at = NOW();

    user_id  := r.user_id;
    nickname := r.nickname;
    RETURN NEXT;
  END LOOP;
END;
$$;


-- ============================================================
-- 権限（service_role のみ一括操作）
-- ============================================================
REVOKE ALL ON FUNCTION public.grant_gear_plus_monthly_items() FROM public;
GRANT EXECUTE ON FUNCTION public.grant_gear_plus_monthly_items() TO service_role;


-- ============================================================
-- cron（pg_cron がある場合）
-- ------------------------------------------------------------
-- 毎月1日 10:00 JST = 01:00 UTC。grant-gear-r-monthly-items と同時刻。
-- ============================================================
DO $cron_setup$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'pg_cron') THEN
    CREATE EXTENSION IF NOT EXISTS pg_cron;

    IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'grant-gear-plus-monthly-items') THEN
      PERFORM cron.unschedule('grant-gear-plus-monthly-items');
    END IF;
    PERFORM cron.schedule(
      'grant-gear-plus-monthly-items',
      '0 1 1 * *',
      $job$SELECT public.grant_gear_plus_monthly_items()$job$
    );
  END IF;
END $cron_setup$;


-- ============================================================
-- 動作確認（手動 / service_role）
-- ============================================================
-- SELECT * FROM public.grant_gear_plus_monthly_items();
