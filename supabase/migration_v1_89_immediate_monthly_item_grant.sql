-- 月次アイテム付与（ニトロ・渋！等）を、加入直後にも即時付与できるようにする。
-- 従来は毎月1日のcronのみで一括付与しており、月の途中で加入したユーザーは
-- 最大1ヶ月近く待つ必要があった。ユーザー単位で「今月分を付与済みか」を
-- item_grant_month (YYYY-MM) に記録し、購入直後の同期処理と月次cronの
-- 両方から安全に（二重付与せず）呼び出せるようにする。

ALTER TABLE public.users
  ADD COLUMN IF NOT EXISTS item_grant_month text NULL;

-- gear_plus 月次付与: 今月分未付与のユーザーのみ対象にする
DROP FUNCTION IF EXISTS public.grant_gear_plus_monthly_items();
CREATE OR REPLACE FUNCTION public.grant_gear_plus_monthly_items()
 RETURNS TABLE(user_id uuid, nickname text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
#variable_conflict use_column
DECLARE
  r RECORD;
  v_month text := to_char(NOW(), 'YYYY-MM');
BEGIN
  FOR r IN
    SELECT u.user_id, u.nickname
    FROM public.users u
    WHERE public.user_effective_plan(u.user_id) = 'gear_plus'
      AND COALESCE(u.is_suspended, FALSE) = FALSE
      AND u.item_grant_month IS DISTINCT FROM v_month
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

    UPDATE public.users SET item_grant_month = v_month WHERE public.users.user_id = r.user_id;

    user_id  := r.user_id;
    nickname := r.nickname;
    RETURN NEXT;
  END LOOP;
END;
$function$;

REVOKE ALL ON FUNCTION public.grant_gear_plus_monthly_items() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.grant_gear_plus_monthly_items() TO service_role;

-- pit_in 月次付与: 同様に今月分未付与のみ対象
DROP FUNCTION IF EXISTS public.grant_pit_in_monthly_items();
CREATE OR REPLACE FUNCTION public.grant_pit_in_monthly_items()
 RETURNS TABLE(user_id uuid, nickname text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
#variable_conflict use_column
DECLARE
  r RECORD;
  v_month text := to_char(NOW(), 'YYYY-MM');
BEGIN
  FOR r IN
    SELECT u.user_id, u.nickname
    FROM public.users u
    WHERE u.plan = 'pit_in'
      AND COALESCE(u.is_suspended, FALSE) = FALSE
      AND u.item_grant_month IS DISTINCT FROM v_month
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

    UPDATE public.users SET item_grant_month = v_month WHERE public.users.user_id = r.user_id;

    user_id  := r.user_id;
    nickname := r.nickname;
    RETURN NEXT;
  END LOOP;
END;
$function$;

REVOKE ALL ON FUNCTION public.grant_pit_in_monthly_items() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.grant_pit_in_monthly_items() TO service_role;

-- gear_r 月次付与: 同様に今月分未付与のみ対象
DROP FUNCTION IF EXISTS public.grant_gear_r_monthly_items();
CREATE OR REPLACE FUNCTION public.grant_gear_r_monthly_items()
 RETURNS TABLE(user_id uuid, nickname text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
#variable_conflict use_column
DECLARE
  r RECORD;
  v_month text := to_char(NOW(), 'YYYY-MM');
BEGIN
  FOR r IN
    SELECT u.user_id, u.nickname
    FROM public.users u
    WHERE public.user_effective_plan(u.user_id) = 'gear_r'
      AND COALESCE(u.is_suspended, FALSE) = FALSE
      AND u.item_grant_month IS DISTINCT FROM v_month
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

    UPDATE public.users SET item_grant_month = v_month WHERE public.users.user_id = r.user_id;

    user_id  := r.user_id;
    nickname := r.nickname;
    RETURN NEXT;
  END LOOP;
END;
$function$;

REVOKE ALL ON FUNCTION public.grant_gear_r_monthly_items() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.grant_gear_r_monthly_items() TO service_role;

-- 購入直後の同期からも安全に呼べる、単一ユーザー向けの即時付与関数。
-- 今月まだ付与されていない場合のみ付与し、月次cronとの二重付与を防ぐ。
CREATE OR REPLACE FUNCTION public.grant_monthly_items_for_user(p_user_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_plan text;
  v_month text := to_char(NOW(), 'YYYY-MM');
  v_already text;
BEGIN
  SELECT public.user_effective_plan(p_user_id) INTO v_plan;
  IF v_plan NOT IN ('gear_plus', 'gear_r', 'pit_in') THEN
    RETURN;
  END IF;

  SELECT item_grant_month INTO v_already FROM public.users WHERE user_id = p_user_id;
  IF v_already IS NOT DISTINCT FROM v_month THEN
    RETURN;
  END IF;

  IF v_plan = 'gear_r' THEN
    INSERT INTO public.user_items (user_id, item_type, quantity, updated_at)
    VALUES (p_user_id, 'super_nitro', 1, NOW())
    ON CONFLICT (user_id, item_type)
    DO UPDATE SET quantity = public.user_items.quantity + 1, updated_at = NOW();

    INSERT INTO public.user_items (user_id, item_type, quantity, updated_at)
    VALUES (p_user_id, 'geki_shibu', 10, NOW())
    ON CONFLICT (user_id, item_type)
    DO UPDATE SET quantity = public.user_items.quantity + 10, updated_at = NOW();
  ELSE
    -- gear_plus / pit_in は同じ特典（ニトロ1個・渋10個）
    INSERT INTO public.user_items (user_id, item_type, quantity, updated_at)
    VALUES (p_user_id, 'nitro', 1, NOW())
    ON CONFLICT (user_id, item_type)
    DO UPDATE SET quantity = public.user_items.quantity + 1, updated_at = NOW();

    INSERT INTO public.user_items (user_id, item_type, quantity, updated_at)
    VALUES (p_user_id, 'shibu', 10, NOW())
    ON CONFLICT (user_id, item_type)
    DO UPDATE SET quantity = public.user_items.quantity + 10, updated_at = NOW();
  END IF;

  UPDATE public.users SET item_grant_month = v_month WHERE user_id = p_user_id;
END;
$function$;

REVOKE ALL ON FUNCTION public.grant_monthly_items_for_user(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.grant_monthly_items_for_user(uuid) TO service_role;
