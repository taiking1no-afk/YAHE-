-- ============================================================
-- Migration v1.29 : SNSリンク開封記録 + Gear R 月次レポート集計
-- 前提: v1.17 / v1.28 適用済み。冪等。
-- ------------------------------------------------------------
-- ① sns_link_clicks … 他ユーザーのSNSリンク開封ログ
-- ② record_sns_link_click RPC
-- ③ gear_r_monthly_reports に link_clicks 列
-- ④ compute / generate に開封数・タップ率を追加
-- ============================================================


-- ============================================================
-- ① 開封ログ
-- ============================================================
CREATE TABLE IF NOT EXISTS public.sns_link_clicks (
  click_id       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_user_id  UUID NOT NULL REFERENCES public.users(user_id) ON DELETE CASCADE,
  clicker_user_id UUID NOT NULL REFERENCES public.users(user_id) ON DELETE CASCADE,
  platform       TEXT,
  url_host       TEXT,
  clicked_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT sns_link_clicks_no_self CHECK (owner_user_id <> clicker_user_id)
);

CREATE INDEX IF NOT EXISTS idx_sns_link_clicks_owner_at
  ON public.sns_link_clicks(owner_user_id, clicked_at DESC);
CREATE INDEX IF NOT EXISTS idx_sns_link_clicks_clicker
  ON public.sns_link_clicks(clicker_user_id, clicked_at DESC);

ALTER TABLE public.sns_link_clicks ENABLE ROW LEVEL SECURITY;

-- 直 INSERT 禁止（RPC 経由）
DROP POLICY IF EXISTS "sns_link_clicks_select_owner" ON public.sns_link_clicks;
CREATE POLICY "sns_link_clicks_select_owner" ON public.sns_link_clicks
  FOR SELECT USING (
    owner_user_id IN (SELECT user_id FROM public.users WHERE auth_id = auth.uid())
    AND public.user_effective_plan(owner_user_id) = 'gear_r'
  );


-- ============================================================
-- ② 開封記録 RPC
-- ------------------------------------------------------------
-- 開示済み（マッチ or 鍵なしでいいね済み）の相手リンクのみ記録
-- ============================================================
CREATE OR REPLACE FUNCTION public.record_sns_link_click(
  p_owner_user_id UUID,
  p_platform      TEXT DEFAULT NULL,
  p_url           TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_clicker UUID;
  v_host    TEXT;
  v_allowed BOOLEAN := FALSE;
BEGIN
  SELECT user_id INTO v_clicker FROM public.users WHERE auth_id = auth.uid();
  IF v_clicker IS NULL OR v_clicker = p_owner_user_id THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'forbidden');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.users WHERE user_id = p_owner_user_id) THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'owner_not_found');
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.blocks b
    WHERE (b.blocker_id = v_clicker AND b.blocked_id = p_owner_user_id)
       OR (b.blocker_id = p_owner_user_id AND b.blocked_id = v_clicker)
  ) THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'blocked');
  END IF;

  -- マッチ済みなら開示済み
  IF EXISTS (
    SELECT 1 FROM public.matches m
    WHERE (m.user_a_id = LEAST(v_clicker, p_owner_user_id)
       AND m.user_b_id = GREATEST(v_clicker, p_owner_user_id))
  ) THEN
    v_allowed := TRUE;
  END IF;

  -- 鍵なしオーナーへ、閲覧者がいいね済みなら開示済み
  IF NOT v_allowed AND EXISTS (
    SELECT 1
    FROM public.users owner
    JOIN public.likes l
      ON l.from_user_id = v_clicker
     AND l.to_user_id = p_owner_user_id
    WHERE owner.user_id = p_owner_user_id
      AND COALESCE(owner.is_private, TRUE) = FALSE
  ) THEN
    v_allowed := TRUE;
  END IF;

  IF NOT v_allowed THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'not_disclosed');
  END IF;

  v_host := NULL;
  IF p_url IS NOT NULL AND btrim(p_url) <> '' THEN
    BEGIN
      v_host := lower(substring(p_url from '://([^/]+)'));
      IF v_host IS NULL THEN
        v_host := lower(substring(p_url from '^([^/]+)'));
      END IF;
      IF v_host LIKE 'www.%' THEN
        v_host := substring(v_host from 5);
      END IF;
    EXCEPTION WHEN OTHERS THEN
      v_host := NULL;
    END;
  END IF;

  INSERT INTO public.sns_link_clicks (owner_user_id, clicker_user_id, platform, url_host)
  VALUES (
    p_owner_user_id,
    v_clicker,
    NULLIF(btrim(COALESCE(p_platform, '')), ''),
    v_host
  );

  RETURN jsonb_build_object('success', TRUE);
END;
$$;

REVOKE ALL ON FUNCTION public.record_sns_link_click(UUID, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.record_sns_link_click(UUID, TEXT, TEXT) TO authenticated;


-- ============================================================
-- ③ レポートテーブル列追加
-- ============================================================
ALTER TABLE public.gear_r_monthly_reports
  ADD COLUMN IF NOT EXISTS link_clicks INT NOT NULL DEFAULT 0;


-- ============================================================
-- ④ 集計 RPC 更新
-- ============================================================
CREATE OR REPLACE FUNCTION public.compute_gear_r_analytics(
  p_user_id UUID,
  p_year    INT,
  p_month   INT
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_start TIMESTAMPTZ;
  v_end   TIMESTAMPTZ;
  v_enc   INT;
  v_views INT;
  v_likes_in  INT;
  v_likes_out INT;
  v_matches   INT;
  v_link_clicks INT;
  v_tap_rate NUMERIC;
BEGIN
  v_start := make_timestamptz(p_year, p_month, 1, 0, 0, 0, 'Asia/Tokyo');
  v_end   := v_start + INTERVAL '1 month';

  SELECT COUNT(*) INTO v_enc
  FROM public.encounters e
  WHERE (e.user_a_id = p_user_id OR e.user_b_id = p_user_id)
    AND e.time >= v_start AND e.time < v_end;

  SELECT COUNT(*) INTO v_views
  FROM public.profile_views pv
  WHERE pv.viewed_user_id = p_user_id
    AND pv.viewed_at >= v_start AND pv.viewed_at < v_end;

  SELECT COUNT(*) INTO v_likes_in
  FROM public.likes l
  WHERE l.to_user_id = p_user_id
    AND l.created_at >= v_start AND l.created_at < v_end;

  SELECT COUNT(*) INTO v_likes_out
  FROM public.likes l
  WHERE l.from_user_id = p_user_id
    AND l.created_at >= v_start AND l.created_at < v_end;

  SELECT COUNT(*) INTO v_matches
  FROM public.matches m
  WHERE (m.user_a_id = p_user_id OR m.user_b_id = p_user_id)
    AND m.matched_at >= v_start AND m.matched_at < v_end;

  SELECT COUNT(*) INTO v_link_clicks
  FROM public.sns_link_clicks c
  WHERE c.owner_user_id = p_user_id
    AND c.clicked_at >= v_start AND c.clicked_at < v_end;

  -- タップ率 = SNS開封 / プロフィール閲覧（閲覧0なら null）
  IF v_views > 0 THEN
    v_tap_rate := ROUND((v_link_clicks::numeric / v_views::numeric) * 100, 1);
  ELSE
    v_tap_rate := NULL;
  END IF;

  RETURN jsonb_build_object(
    'encounters',      v_enc,
    'profile_views',   v_views,
    'likes_received',  v_likes_in,
    'likes_sent',      v_likes_out,
    'matches',         v_matches,
    'link_clicks',     v_link_clicks,
    'link_tap_rate',   v_tap_rate,
    'period_start',    v_start,
    'period_end',      v_end - INTERVAL '1 second'
  );
END;
$$;


-- RETURNS TABLE に列追加するため、既存定義を先に落とす
DROP FUNCTION IF EXISTS public.generate_gear_r_monthly_reports(INT, INT);

CREATE OR REPLACE FUNCTION public.generate_gear_r_monthly_reports(
  p_year  INT,
  p_month INT
)
RETURNS TABLE (
  report_id      UUID,
  user_id        UUID,
  nickname       TEXT,
  encounters     INT,
  profile_views  INT,
  likes_received INT,
  likes_sent     INT,
  matches        INT,
  link_clicks    INT,
  push_sent_at   TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  r       RECORD;
  v_stats JSONB;
BEGIN
  FOR r IN
    SELECT u.user_id, u.nickname
    FROM public.users u
    WHERE public.user_effective_plan(u.user_id) = 'gear_r'
      AND COALESCE(u.is_suspended, FALSE) = FALSE
  LOOP
    v_stats := public.compute_gear_r_analytics(r.user_id, p_year, p_month);

    INSERT INTO public.gear_r_monthly_reports AS gr (
      user_id, report_year, report_month,
      encounters, profile_views, likes_received, likes_sent, matches,
      link_clicks, summary_json, generated_at
    )
    VALUES (
      r.user_id, p_year, p_month,
      (v_stats->>'encounters')::int,
      (v_stats->>'profile_views')::int,
      (v_stats->>'likes_received')::int,
      (v_stats->>'likes_sent')::int,
      (v_stats->>'matches')::int,
      (v_stats->>'link_clicks')::int,
      v_stats,
      NOW()
    )
    ON CONFLICT (user_id, report_year, report_month) DO UPDATE SET
      encounters     = EXCLUDED.encounters,
      profile_views  = EXCLUDED.profile_views,
      likes_received = EXCLUDED.likes_received,
      likes_sent     = EXCLUDED.likes_sent,
      matches        = EXCLUDED.matches,
      link_clicks    = EXCLUDED.link_clicks,
      summary_json   = EXCLUDED.summary_json,
      generated_at   = NOW();

    RETURN QUERY
    SELECT
      gr.report_id,
      gr.user_id,
      r.nickname,
      gr.encounters,
      gr.profile_views,
      gr.likes_received,
      gr.likes_sent,
      gr.matches,
      gr.link_clicks,
      gr.push_sent_at
    FROM public.gear_r_monthly_reports gr
    WHERE gr.user_id = r.user_id
      AND gr.report_year = p_year
      AND gr.report_month = p_month;
  END LOOP;
END;
$$;

REVOKE ALL ON FUNCTION public.generate_gear_r_monthly_reports(INT, INT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.generate_gear_r_monthly_reports(INT, INT) TO service_role;

REVOKE ALL ON FUNCTION public.compute_gear_r_analytics(UUID, INT, INT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.compute_gear_r_analytics(UUID, INT, INT) TO service_role;
GRANT EXECUTE ON FUNCTION public.compute_gear_r_analytics(UUID, INT, INT) TO authenticated;
