-- ============================================================
-- 表示されないときの診断（SQL Editor で実行）
-- 対象ユーザー:
--   2a7fb5ea-e7a2-4dae-abb3-4f28ed7d7a37
--   dd952b60-91b2-4b81-9c92-3f784d736c2c
-- ============================================================

-- 1) ユーザーは存在するか / 匿名モードか
SELECT user_id, nickname, anonymous_mode, is_suspended, passing_target, plan
FROM public.users
WHERE user_id IN (
  '2a7fb5ea-e7a2-4dae-abb3-4f28ed7d7a37',
  'dd952b60-91b2-4b81-9c92-3f784d736c2c'
);

-- 2) 有効車両（0 だとアプリに出ない）
SELECT user_id, vehicle_id, maker, model, vehicle_type, is_active
FROM public.vehicles
WHERE user_id IN (
  '2a7fb5ea-e7a2-4dae-abb3-4f28ed7d7a37',
  'dd952b60-91b2-4b81-9c92-3f784d736c2c'
)
ORDER BY user_id, created_at;

-- 3) すれ違い行はあるか / 期限切れでないか
SELECT encounter_id, user_a_id, user_b_id, time, expires_at,
       (expires_at > now()) AS not_expired,
       (time > now() - interval '24 hours') AS within_free_24h
FROM public.encounters
WHERE (user_a_id = '2a7fb5ea-e7a2-4dae-abb3-4f28ed7d7a37'
   AND user_b_id = 'dd952b60-91b2-4b81-9c92-3f784d736c2c')
   OR (user_a_id = 'dd952b60-91b2-4b81-9c92-3f784d736c2c'
   AND user_b_id = '2a7fb5ea-e7a2-4dae-abb3-4f28ed7d7a37')
ORDER BY time DESC;

-- 4) 無ければここで挿入（両方に車両がある前提）
DO $$
DECLARE
  v_a uuid := LEAST(
    '2a7fb5ea-e7a2-4dae-abb3-4f28ed7d7a37'::uuid,
    'dd952b60-91b2-4b81-9c92-3f784d736c2c'::uuid
  );
  v_b uuid := GREATEST(
    '2a7fb5ea-e7a2-4dae-abb3-4f28ed7d7a37'::uuid,
    'dd952b60-91b2-4b81-9c92-3f784d736c2c'::uuid
  );
  v_occ int;
  i int;
  va int;
  vb int;
  v_expires_at timestamptz;
BEGIN
  SELECT COUNT(*) INTO va FROM public.vehicles
  WHERE user_id = '2a7fb5ea-e7a2-4dae-abb3-4f28ed7d7a37' AND is_active;
  SELECT COUNT(*) INTO vb FROM public.vehicles
  WHERE user_id = 'dd952b60-91b2-4b81-9c92-3f784d736c2c' AND is_active;

  IF va = 0 OR vb = 0 THEN
    RAISE EXCEPTION '車両不足: A=% 台 / B=% 台。両方で愛車を1台以上登録してから再実行', va, vb;
  END IF;

  -- 古いテスト行を消して作り直す（見やすくするため）
  DELETE FROM public.encounters
  WHERE user_a_id = v_a AND user_b_id = v_b;

  -- 本番と同じ: どちらかが premium なら7日、両方無料なら24時間
  v_expires_at := CASE
    WHEN public.user_is_premium(v_a) OR public.user_is_premium(v_b)
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
      now() - ((30 * i) * interval '1 minute'), -- 直近（無料24hフィルタも通る）
      v_expires_at,
      v_occ
    );
  END LOOP;

  RAISE NOTICE 'reseeded 3 encounters (vehicles A=% B=%)', va, vb;
END $$;

-- 5) 最終確認
SELECT encounter_id, time, expires_at FROM public.encounters
WHERE user_a_id = LEAST(
        '2a7fb5ea-e7a2-4dae-abb3-4f28ed7d7a37'::uuid,
        'dd952b60-91b2-4b81-9c92-3f784d736c2c'::uuid)
  AND user_b_id = GREATEST(
        '2a7fb5ea-e7a2-4dae-abb3-4f28ed7d7a37'::uuid,
        'dd952b60-91b2-4b81-9c92-3f784d736c2c'::uuid)
ORDER BY time DESC;
