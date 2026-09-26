-- ============================================================
-- Migration v1.84 : 月次アイテム付与3関数の「column reference "user_id"
-- is ambiguous」エラーを修正（致命的：これまで一度も成功したことがない）
-- Supabase SQL Editor で実行してください。
-- ------------------------------------------------------------
-- 背景: grant_gear_plus_monthly_items() / grant_gear_r_monthly_items() /
--   grant_pit_in_monthly_items() はいずれも
--   `RETURNS TABLE(user_id UUID, nickname TEXT)` で user_id を暗黙のOUT
--   パラメータ（=関数内で使えるplpgsql変数）として持つ。関数本体の
--   `INSERT INTO user_items (...) ON CONFLICT (user_id, item_type) ...`
--   のuser_idが、テーブル列なのかOUTパラメータなのかPostgresが一意に
--   決定できず、`column reference "user_id" is ambiguous` (42702) で
--   必ず例外になっていた。
--
--   実害: pg_cronで毎月1日 01:00 UTC に自動実行される
--   grant-gear-plus-monthly-items / grant-gear-r-monthly-items /
--   grant-pit-in-monthly-items の3ジョブが、実行のたび例外で失敗して
--   いた（pg_cronは失敗しても誰にも通知しないため誰も気づけなかった）。
--   Gear+ / Gear R 加入者への毎月のニトロ・渋！等の付与が、この機能の
--   導入以来一度も成功していなかった可能性が高い。
--
--   修正: `#variable_conflict use_column` プラグマを関数冒頭に追加し、
--   名前が衝突した場合はOUTパラメータではなく常にテーブル列を優先する
--   ようにする（戻り値の列名・シグネチャ・呼び出し側への影響は無い）。
--
--   何度実行しても安全（冪等）。
-- ============================================================

CREATE OR REPLACE FUNCTION public.grant_gear_plus_monthly_items()
RETURNS TABLE(user_id UUID, nickname TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
#variable_conflict use_column
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

CREATE OR REPLACE FUNCTION public.grant_gear_r_monthly_items()
RETURNS TABLE(user_id UUID, nickname TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
#variable_conflict use_column
DECLARE
  r RECORD;
BEGIN
  FOR r IN
    SELECT u.user_id, u.nickname
    FROM public.users u
    WHERE public.user_effective_plan(u.user_id) = 'gear_r'
      AND COALESCE(u.is_suspended, FALSE) = FALSE
  LOOP
    INSERT INTO public.user_items (user_id, item_type, quantity, updated_at)
    VALUES (r.user_id, 'super_nitro', 1, NOW())
    ON CONFLICT (user_id, item_type)
    DO UPDATE SET
      quantity   = public.user_items.quantity + 1,
      updated_at = NOW();

    INSERT INTO public.user_items (user_id, item_type, quantity, updated_at)
    VALUES (r.user_id, 'geki_shibu', 10, NOW())
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

CREATE OR REPLACE FUNCTION public.grant_pit_in_monthly_items()
RETURNS TABLE(user_id UUID, nickname TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
#variable_conflict use_column
DECLARE
  r RECORD;
BEGIN
  FOR r IN
    SELECT u.user_id, u.nickname
    FROM public.users u
    WHERE u.plan = 'pit_in'
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

REVOKE ALL ON FUNCTION public.grant_gear_plus_monthly_items() FROM public;
GRANT EXECUTE ON FUNCTION public.grant_gear_plus_monthly_items() TO service_role;
REVOKE ALL ON FUNCTION public.grant_gear_r_monthly_items() FROM public;
GRANT EXECUTE ON FUNCTION public.grant_gear_r_monthly_items() TO service_role;
REVOKE ALL ON FUNCTION public.grant_pit_in_monthly_items() FROM public;
GRANT EXECUTE ON FUNCTION public.grant_pit_in_monthly_items() TO service_role;
