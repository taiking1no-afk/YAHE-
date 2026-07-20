-- ============================================================
-- migration v1.11 : 年齢確認 / 規約同意の記録 / 通報モデレーション / レート制限強化
-- ------------------------------------------------------------
-- 目的:
--   1) 年齢確認（生年月日）と18歳未満の利用ブロックの土台
--   2) 利用規約・プライバシーポリシー同意の証跡（日時・バージョン）を保存
--   3) 通報が一定数たまったユーザーを自動で「停止(suspended)」にし、
--      検索・すれ違いから自動的に外す（App Store UGC 要件: 迅速な対処）
--   4) send_like のなりすまし防止と上限の厳格化
--
--   何度実行しても安全（冪等）になるよう IF NOT EXISTS / OR REPLACE を使用。
-- ============================================================

-- ============================================================
-- ① 年齢確認・規約同意のカラム
-- ============================================================
ALTER TABLE public.users
  ADD COLUMN IF NOT EXISTS birth_date      DATE,
  ADD COLUMN IF NOT EXISTS terms_agreed_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS terms_version   TEXT,
  ADD COLUMN IF NOT EXISTS is_suspended    BOOLEAN NOT NULL DEFAULT FALSE;

-- ============================================================
-- ② 通報の自動モデレーション
-- ------------------------------------------------------------
-- 同一ユーザー(target_id)が「異なる通報者」から閾値以上 通報されたら、
-- 自動的に is_suspended = TRUE にする。運営は後から解除/恒久対応が可能。
-- ============================================================
CREATE OR REPLACE FUNCTION public.auto_suspend_on_reports()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_distinct_reporters INT;
  v_threshold          INT := 3; -- 異なる通報者がこの人数に達したら自動停止
BEGIN
  SELECT COUNT(DISTINCT reporter_id)
    INTO v_distinct_reporters
  FROM public.reports
  WHERE target_id = NEW.target_id;

  IF v_distinct_reporters >= v_threshold THEN
    UPDATE public.users
       SET is_suspended = TRUE
     WHERE user_id = NEW.target_id
       AND is_suspended = FALSE;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_auto_suspend_on_reports ON public.reports;
CREATE TRIGGER trg_auto_suspend_on_reports
AFTER INSERT ON public.reports
FOR EACH ROW
EXECUTE FUNCTION public.auto_suspend_on_reports();

-- ============================================================
-- ③ 検索(nearby_user_ids)から停止ユーザーを除外
-- ------------------------------------------------------------
-- 停止されたユーザーは新たなすれ違いを発生させない。
-- （自分が停止されている場合も他人に出ないよう、相手・自分の双方で除外）
-- ============================================================
CREATE OR REPLACE FUNCTION public.nearby_user_ids(
  p_lat             double precision,
  p_lng             double precision,
  p_radius_m        double precision DEFAULT 200,
  p_max_age_seconds integer          DEFAULT 10
)
RETURNS TABLE(user_id uuid)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT ul.user_id
  FROM public.user_locations ul
  JOIN public.users tu ON tu.user_id = ul.user_id
  WHERE ul.user_id <> (SELECT u.user_id FROM public.users u WHERE u.auth_id = auth.uid())
    AND tu.is_suspended = FALSE
    -- 自分が停止されている場合は誰にも当たらない
    AND NOT EXISTS (
      SELECT 1 FROM public.users me
      WHERE me.auth_id = auth.uid() AND me.is_suspended = TRUE
    )
    AND ul.updated_at > now() - make_interval(secs => p_max_age_seconds)
    AND 6371000 * 2 * asin(
          sqrt(
            power(sin(radians(ul.lat - p_lat) / 2), 2)
            + cos(radians(p_lat)) * cos(radians(ul.lat))
              * power(sin(radians(ul.lng - p_lng) / 2), 2)
          )
        ) <= p_radius_m;
$$;

REVOKE ALL  ON FUNCTION public.nearby_user_ids(double precision, double precision, double precision, integer) FROM public;
GRANT EXECUTE ON FUNCTION public.nearby_user_ids(double precision, double precision, double precision, integer) TO authenticated;

-- ============================================================
-- ④ send_like のなりすまし防止＋上限の厳格化
-- ------------------------------------------------------------
-- 旧: p_from_user_id を呼び出し側が自由に渡せたため、他人になりすまして
--     いいねを送れる余地があった。auth.uid() と一致するか検証する。
--     無料は10/日、有料も乱用防止の絶対上限(200/日)を設ける。
--     停止ユーザーは送信不可。
-- ============================================================
CREATE OR REPLACE FUNCTION public.send_like(
  p_from_user_id UUID,
  p_to_user_id   UUID,
  p_encounter_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_is_matched   BOOLEAN := FALSE;
  v_match_id     UUID;
  v_like_count   INT;
  v_is_premium   BOOLEAN;
  v_is_suspended BOOLEAN;
  v_caller       UUID;
  v_user_a       UUID;
  v_user_b       UUID;
BEGIN
  -- 呼び出し元(JWT)のユーザーIDを取得し、from と一致するか検証（なりすまし防止）
  SELECT user_id INTO v_caller FROM public.users WHERE auth_id = auth.uid();
  IF v_caller IS NULL OR v_caller <> p_from_user_id THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'forbidden');
  END IF;

  -- プレミアム/停止判定
  SELECT is_premium, is_suspended INTO v_is_premium, v_is_suspended
  FROM public.users WHERE user_id = p_from_user_id;

  IF COALESCE(v_is_suspended, FALSE) THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'suspended');
  END IF;

  -- 1日あたりの上限（無料10 / 有料200）
  SELECT like_count INTO v_like_count
  FROM public.today_like_counts
  WHERE from_user_id = p_from_user_id;

  IF NOT v_is_premium AND COALESCE(v_like_count, 0) >= 10 THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'daily_limit_exceeded');
  END IF;
  IF COALESCE(v_like_count, 0) >= 200 THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'daily_limit_exceeded');
  END IF;

  -- いいね挿入（重複はスキップ）
  INSERT INTO public.likes (from_user_id, to_user_id, encounter_id)
  VALUES (p_from_user_id, p_to_user_id, p_encounter_id)
  ON CONFLICT (from_user_id, to_user_id, encounter_id) DO NOTHING;

  -- 相互いいねチェック
  IF EXISTS (
    SELECT 1 FROM public.likes
    WHERE from_user_id = p_to_user_id
      AND to_user_id = p_from_user_id
      AND encounter_id = p_encounter_id
  ) THEN
    v_user_a := LEAST(p_from_user_id, p_to_user_id);
    v_user_b := GREATEST(p_from_user_id, p_to_user_id);

    INSERT INTO public.matches (user_a_id, user_b_id)
    VALUES (v_user_a, v_user_b)
    ON CONFLICT (user_a_id, user_b_id) DO NOTHING
    RETURNING match_id INTO v_match_id;

    v_is_matched := TRUE;
  END IF;

  RETURN jsonb_build_object(
    'success',    TRUE,
    'is_matched', v_is_matched,
    'match_id',   v_match_id
  );
END;
$$;
