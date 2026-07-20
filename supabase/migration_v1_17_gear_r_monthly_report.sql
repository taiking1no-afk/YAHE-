-- ============================================================
-- Migration v1.17 : Gear R 月次アクセス解析レポート + 自動配信基盤
-- Supabase SQL Editor で実行してください。
-- ------------------------------------------------------------
-- 前提: v1.1〜v1.16 推奨。v1.15 未適用でも本ファイル単体で動くよう
--       必要なカラム / user_effective_plan() を先頭で用意する。
-- ------------------------------------------------------------
-- 目的:
--   ① profile_views … プロフィール閲覧の記録（Gear R 解析用）
--   ② gear_r_monthly_reports … 月次レポートの保存・配信履歴
--   ③ 集計RPC + 全Gear R購入者分の一括生成RPC
--   ④ 月次アイテム付与（スーパーニトロ1 / 激渋！10）の自動実行
--   ⑤ Edge Function gear-r-monthly から呼び出し → プッシュ通知
--
--   何度実行しても安全（冪等）。
-- ============================================================


-- ============================================================
-- ⓪ 前提: プレミアム判定（v1.15 未適用環境向けブートストラップ）
-- ------------------------------------------------------------
-- user_effective_plan(uuid) が無いと RLS 作成時に失敗するため、
-- 先に users 拡張カラムと判定関数を用意する。
-- ============================================================
ALTER TABLE public.users
  ADD COLUMN IF NOT EXISTS plan TEXT NOT NULL DEFAULT 'free',
  ADD COLUMN IF NOT EXISTS trial_ends_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS premium_override_plan TEXT,
  ADD COLUMN IF NOT EXISTS premium_override_expires_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS premium_override_source TEXT,
  ADD COLUMN IF NOT EXISTS premium_override_reason TEXT,
  ADD COLUMN IF NOT EXISTS is_suspended BOOLEAN NOT NULL DEFAULT FALSE;

-- 旧DB互換: is_premium=TRUE だが plan=free の行を gear_plus に寄せる
UPDATE public.users
SET plan = 'gear_plus'
WHERE plan = 'free'
  AND is_premium = TRUE;

CREATE OR REPLACE FUNCTION public.user_effective_plan(p_user_id UUID)
RETURNS TEXT
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_plan             TEXT;
  v_override_plan    TEXT;
  v_override_active  BOOLEAN;
  v_trial_active     BOOLEAN;
BEGIN
  SELECT
    COALESCE(u.plan, 'free'),
    u.premium_override_plan,
    (u.premium_override_plan IS NOT NULL
      AND (u.premium_override_expires_at IS NULL OR u.premium_override_expires_at > NOW())),
    (u.trial_ends_at IS NOT NULL AND u.trial_ends_at > NOW())
  INTO v_plan, v_override_plan, v_override_active, v_trial_active
  FROM public.users u
  WHERE u.user_id = p_user_id;

  IF NOT FOUND THEN
    RETURN 'free';
  END IF;

  IF v_plan = 'gear_r'
     OR (v_override_active AND v_override_plan = 'gear_r') THEN
    RETURN 'gear_r';
  END IF;

  IF v_plan = 'gear_plus'
     OR (v_override_active AND v_override_plan = 'gear_plus')
     OR v_trial_active THEN
    RETURN 'gear_plus';
  END IF;

  RETURN 'free';
END;
$$;


-- ============================================================
-- ① プロフィール閲覧ログ
-- ============================================================
CREATE TABLE IF NOT EXISTS public.profile_views (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  viewed_user_id UUID NOT NULL REFERENCES public.users(user_id) ON DELETE CASCADE,
  viewer_user_id UUID NOT NULL REFERENCES public.users(user_id) ON DELETE CASCADE,
  viewed_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT profile_views_no_self CHECK (viewed_user_id <> viewer_user_id)
);

CREATE INDEX IF NOT EXISTS idx_profile_views_viewed_at
  ON public.profile_views(viewed_user_id, viewed_at DESC);
CREATE INDEX IF NOT EXISTS idx_profile_views_viewer
  ON public.profile_views(viewer_user_id, viewed_at DESC);

ALTER TABLE public.profile_views ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "profile_views_insert_own" ON public.profile_views;
CREATE POLICY "profile_views_insert_own" ON public.profile_views
  FOR INSERT WITH CHECK (
    viewer_user_id IN (SELECT user_id FROM public.users WHERE auth_id = auth.uid())
  );

-- Gear R 本人のみ自分への閲覧数を参照可
DROP POLICY IF EXISTS "profile_views_select_own" ON public.profile_views;
CREATE POLICY "profile_views_select_own" ON public.profile_views
  FOR SELECT USING (
    viewed_user_id IN (SELECT user_id FROM public.users WHERE auth_id = auth.uid())
    AND public.user_effective_plan(viewed_user_id) = 'gear_r'
  );


-- ============================================================
-- ② 月次レポート保存テーブル
-- ============================================================
CREATE TABLE IF NOT EXISTS public.gear_r_monthly_reports (
  report_id       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         UUID NOT NULL REFERENCES public.users(user_id) ON DELETE CASCADE,
  report_year     INT  NOT NULL CHECK (report_year >= 2024),
  report_month    INT  NOT NULL CHECK (report_month BETWEEN 1 AND 12),
  encounters      INT  NOT NULL DEFAULT 0,
  profile_views   INT  NOT NULL DEFAULT 0,
  likes_received  INT  NOT NULL DEFAULT 0,
  likes_sent      INT  NOT NULL DEFAULT 0,
  matches         INT  NOT NULL DEFAULT 0,
  summary_json    JSONB NOT NULL DEFAULT '{}'::jsonb,
  generated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  push_sent_at    TIMESTAMPTZ,
  UNIQUE (user_id, report_year, report_month)
);

CREATE INDEX IF NOT EXISTS idx_gear_r_reports_user
  ON public.gear_r_monthly_reports(user_id, report_year DESC, report_month DESC);

ALTER TABLE public.gear_r_monthly_reports ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "gear_r_reports_select_own" ON public.gear_r_monthly_reports;
CREATE POLICY "gear_r_reports_select_own" ON public.gear_r_monthly_reports
  FOR SELECT USING (
    user_id IN (SELECT user_id FROM public.users WHERE auth_id = auth.uid())
    AND public.user_effective_plan(user_id) = 'gear_r'
  );


-- ============================================================
-- ③ プロフィール閲覧記録 RPC（アプリから呼ぶ）
-- ------------------------------------------------------------
-- 同一閲覧者→被閲覧者は JST 日付ごとに1回だけカウント（重複防止）
-- ============================================================
CREATE OR REPLACE FUNCTION public.record_profile_view(p_viewed_user_id UUID)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_viewer UUID;
  v_today  DATE := (NOW() AT TIME ZONE 'Asia/Tokyo')::date;
BEGIN
  SELECT user_id INTO v_viewer FROM public.users WHERE auth_id = auth.uid();
  IF v_viewer IS NULL OR v_viewer = p_viewed_user_id THEN
    RETURN;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.users WHERE user_id = p_viewed_user_id) THEN
    RETURN;
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.blocks b
    WHERE (b.blocker_id = v_viewer AND b.blocked_id = p_viewed_user_id)
       OR (b.blocker_id = p_viewed_user_id AND b.blocked_id = v_viewer)
  ) THEN
    RETURN;
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.profile_views pv
    WHERE pv.viewed_user_id = p_viewed_user_id
      AND pv.viewer_user_id = v_viewer
      AND (pv.viewed_at AT TIME ZONE 'Asia/Tokyo')::date = v_today
  ) THEN
    RETURN;
  END IF;

  INSERT INTO public.profile_views (viewed_user_id, viewer_user_id)
  VALUES (p_viewed_user_id, v_viewer);
END;
$$;

REVOKE ALL ON FUNCTION public.record_profile_view(UUID) FROM public;
GRANT EXECUTE ON FUNCTION public.record_profile_view(UUID) TO authenticated;


-- ============================================================
-- ④ 1ユーザー・1ヶ月分の集計
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

  RETURN jsonb_build_object(
    'encounters',     v_enc,
    'profile_views',  v_views,
    'likes_received', v_likes_in,
    'likes_sent',     v_likes_out,
    'matches',        v_matches,
    'period_start',   v_start,
    'period_end',     v_end - INTERVAL '1 second'
  );
END;
$$;


-- ============================================================
-- ⑤ 全 Gear R 購入者の月次レポートを一括生成
-- ------------------------------------------------------------
-- 対象: 実行時点で effective_plan = 'gear_r' のユーザー
-- 戻り値: 生成/更新されたレポート（push_sent_at IS NULL = 未通知）
-- ============================================================
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
      summary_json, generated_at
    )
    VALUES (
      r.user_id, p_year, p_month,
      (v_stats->>'encounters')::int,
      (v_stats->>'profile_views')::int,
      (v_stats->>'likes_received')::int,
      (v_stats->>'likes_sent')::int,
      (v_stats->>'matches')::int,
      v_stats,
      NOW()
    )
    ON CONFLICT (user_id, report_year, report_month) DO UPDATE SET
      encounters     = EXCLUDED.encounters,
      profile_views  = EXCLUDED.profile_views,
      likes_received = EXCLUDED.likes_received,
      likes_sent     = EXCLUDED.likes_sent,
      matches        = EXCLUDED.matches,
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
      gr.push_sent_at
    FROM public.gear_r_monthly_reports gr
    WHERE gr.user_id = r.user_id
      AND gr.report_year = p_year
      AND gr.report_month = p_month;
  END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION public.mark_gear_r_report_pushed(p_report_id UUID)
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  UPDATE public.gear_r_monthly_reports
  SET push_sent_at = NOW()
  WHERE report_id = p_report_id;
$$;


-- ============================================================
-- ⑥ Gear R 月次アイテム付与（毎月1日）
-- ------------------------------------------------------------
-- スーパーニトロ +1 / 激渋！ +10（既存所持数に加算）
-- ============================================================
CREATE OR REPLACE FUNCTION public.grant_gear_r_monthly_items()
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


-- ============================================================
-- ⑦ 権限（service_role のみ一括操作）
-- ============================================================
REVOKE ALL ON FUNCTION public.compute_gear_r_analytics(UUID, INT, INT) FROM public;
REVOKE ALL ON FUNCTION public.generate_gear_r_monthly_reports(INT, INT) FROM public;
REVOKE ALL ON FUNCTION public.mark_gear_r_report_pushed(UUID) FROM public;
REVOKE ALL ON FUNCTION public.grant_gear_r_monthly_items() FROM public;

GRANT EXECUTE ON FUNCTION public.compute_gear_r_analytics(UUID, INT, INT) TO service_role;
GRANT EXECUTE ON FUNCTION public.generate_gear_r_monthly_reports(INT, INT) TO service_role;
GRANT EXECUTE ON FUNCTION public.mark_gear_r_report_pushed(UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.grant_gear_r_monthly_items() TO service_role;


-- ============================================================
-- ⑧ cron（pg_cron がある場合）
-- ------------------------------------------------------------
-- 毎月1日 10:00 JST = 01:00 UTC
-- Edge Function gear-r-monthly を pg_net で呼ぶか、
-- 外部 cron から POST してください（運営ルーティン.md 参照）。
-- ここでは DB 側の月次アイテム付与のみ cron 登録。
-- ============================================================
DO $cron_setup$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'pg_cron') THEN
    CREATE EXTENSION IF NOT EXISTS pg_cron;

    IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'grant-gear-r-monthly-items') THEN
      PERFORM cron.unschedule('grant-gear-r-monthly-items');
    END IF;
    PERFORM cron.schedule(
      'grant-gear-r-monthly-items',
      '0 1 1 * *',
      $job$SELECT public.grant_gear_r_monthly_items()$job$
    );
  END IF;
END $cron_setup$;


-- ============================================================
-- 動作確認（手動 / service_role）
-- ============================================================
-- SELECT * FROM public.generate_gear_r_monthly_reports(2026, 5);
-- SELECT * FROM public.grant_gear_r_monthly_items();
-- SELECT public.compute_gear_r_analytics('<user_id>'::uuid, 2026, 5);
