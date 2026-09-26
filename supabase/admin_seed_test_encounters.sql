-- ============================================================
-- ログイン中ユーザー向けテストすれ違い挿入
-- ------------------------------------------------------------
-- ログイン中: c5ff24ea-cceb-4465-8d6d-a81f97120b0d
-- 相手1:     2a7fb5ea-e7a2-4dae-abb3-4f28ed7d7a37
-- 相手2:     dd952b60-91b2-4b81-9c92-3f784d736c2c
--
-- ※ 自分の ID が含まれていない encounter はアプリに出ません
-- ============================================================

DO $$
DECLARE
  v_me uuid := 'c5ff24ea-cceb-4465-8d6d-a81f97120b0d'::uuid;
  v_p1 uuid := '2a7fb5ea-e7a2-4dae-abb3-4f28ed7d7a37'::uuid;
  v_p2 uuid := 'dd952b60-91b2-4b81-9c92-3f784d736c2c'::uuid;
  partners uuid[] := ARRAY[v_p1, v_p2];
  partner uuid;
  v_a uuid;
  v_b uuid;
  v_occ int;
  i int;
  v_me_vehicles int;
  v_partner_vehicles int;
  v_expires_at timestamptz;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.users WHERE user_id = v_me) THEN
    RAISE EXCEPTION 'ログインユーザーが存在しません: %', v_me;
  END IF;

  SELECT COUNT(*) INTO v_me_vehicles
  FROM public.vehicles WHERE user_id = v_me AND is_active = true;
  IF v_me_vehicles = 0 THEN
    RAISE EXCEPTION 'ログインユーザーに有効な愛車がありません。アプリで車両を登録してください';
  END IF;

  FOREACH partner IN ARRAY partners LOOP
    IF NOT EXISTS (SELECT 1 FROM public.users WHERE user_id = partner) THEN
      RAISE EXCEPTION '相手ユーザーが存在しません: %', partner;
    END IF;

    SELECT COUNT(*) INTO v_partner_vehicles
    FROM public.vehicles WHERE user_id = partner AND is_active = true;
    IF v_partner_vehicles = 0 THEN
      RAISE EXCEPTION '相手 % に有効な愛車がありません（アプリ側で非表示になります）', partner;
    END IF;

    v_a := LEAST(v_me, partner);
    v_b := GREATEST(v_me, partner);

    DELETE FROM public.encounters
    WHERE user_a_id = v_a AND user_b_id = v_b;

    -- 本番と同じ: どちらかが premium なら7日、両方無料なら24時間
    v_expires_at := CASE
      WHEN public.user_is_premium(v_me) OR public.user_is_premium(partner)
        THEN now() + interval '7 days'
      ELSE now() + interval '24 hours'
    END;

    FOR i IN 0..2 LOOP
      SELECT COUNT(*) + 1 INTO v_occ
      FROM public.encounters WHERE user_a_id = v_a AND user_b_id = v_b;

      INSERT INTO public.encounters (
        user_a_id, user_b_id, time, expires_at, occurrence_number
      ) VALUES (
        v_a, v_b,
        now() - ((20 * i) * interval '1 minute'),
        v_expires_at,
        v_occ
      );
    END LOOP;
  END LOOP;

  RAISE NOTICE 'seeded encounters for me=% with p1 and p2', v_me;
END $$;

-- 確認: ログインユーザーが当事者の行だけ
SELECT e.encounter_id, e.user_a_id, e.user_b_id, e.time, e.expires_at,
       CASE
         WHEN e.user_a_id = 'c5ff24ea-cceb-4465-8d6d-a81f97120b0d'::uuid
           THEN e.user_b_id ELSE e.user_a_id
       END AS other_user_id
FROM public.encounters e
WHERE e.user_a_id = 'c5ff24ea-cceb-4465-8d6d-a81f97120b0d'::uuid
   OR e.user_b_id = 'c5ff24ea-cceb-4465-8d6d-a81f97120b0d'::uuid
ORDER BY e.time DESC;

-- 車両確認
SELECT u.user_id, u.nickname, COUNT(v.vehicle_id) AS active_vehicles
FROM public.users u
LEFT JOIN public.vehicles v ON v.user_id = u.user_id AND v.is_active = true
WHERE u.user_id IN (
  'c5ff24ea-cceb-4465-8d6d-a81f97120b0d',
  '2a7fb5ea-e7a2-4dae-abb3-4f28ed7d7a37',
  'dd952b60-91b2-4b81-9c92-3f784d736c2c'
)
GROUP BY u.user_id, u.nickname;
