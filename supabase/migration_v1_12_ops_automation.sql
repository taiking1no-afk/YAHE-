-- ============================================================
-- Migration v1.12 : 運営自動化（KPI集計 + 定期クリーンアップ）
-- Supabase SQL Editor で実行してください。前提: v1.1〜v1.11 実行済み。
-- ------------------------------------------------------------
-- 目的:
--   ① KPIをリアルタイムに見るビュー（運営ダッシュボード用）
--      - 全体サマリー / 日別推移 / 継続率(D1・D7・D30)
--   ② 毎日のKPIスナップショットを自動保存（cron）
--      → 過去にさかのぼった継続率・推移分析を可能にする
--   ③ 不要データの定期クリーンアップ（cron）
--      - 期限切れ encounters（v1.8で設定済みだが本ファイルで一元管理）
--      - 古い user_locations（24h以上更新がない＝走行していない残骸）
--   ④ KPI系はすべて service_role(管理者) のみ参照可（一般ユーザーには出さない）
--
--   何度実行しても安全（冪等）。IF NOT EXISTS / OR REPLACE を使用。
-- ============================================================


-- ============================================================
-- ① リアルタイムKPIビュー
-- ============================================================

-- 全体サマリー（現在値）
CREATE OR REPLACE VIEW public.kpi_overview AS
SELECT
  (SELECT COUNT(*) FROM public.users)                                   AS total_users,
  (SELECT COUNT(*) FROM public.users WHERE is_premium)                  AS premium_users,
  ROUND(
    100.0 * (SELECT COUNT(*) FROM public.users WHERE is_premium)
    / NULLIF((SELECT COUNT(*) FROM public.users), 0), 2)                AS premium_rate_pct,
  (SELECT COUNT(*) FROM public.users WHERE is_suspended)                AS suspended_users,
  (SELECT COUNT(*) FROM public.users
     WHERE created_at >= DATE_TRUNC('day', NOW() AT TIME ZONE 'Asia/Tokyo') AT TIME ZONE 'Asia/Tokyo'
  )                                                                     AS new_users_today,
  (SELECT COUNT(*) FROM public.encounters)                             AS total_encounters,
  (SELECT COUNT(*) FROM public.matches)                                AS total_matches,
  (SELECT COUNT(*) FROM public.reports WHERE status = 'pending')        AS pending_reports;

-- 日別推移（直近30日 / Asia/Tokyo基準）
CREATE OR REPLACE VIEW public.kpi_daily AS
WITH days AS (
  SELECT generate_series(
    (DATE_TRUNC('day', NOW() AT TIME ZONE 'Asia/Tokyo') - INTERVAL '29 days')::date,
    (DATE_TRUNC('day', NOW() AT TIME ZONE 'Asia/Tokyo'))::date,
    INTERVAL '1 day'
  )::date AS d
)
SELECT
  days.d AS day,
  (SELECT COUNT(*) FROM public.users u
     WHERE (u.created_at AT TIME ZONE 'Asia/Tokyo')::date = days.d)         AS new_users,
  (SELECT COUNT(*) FROM public.encounters e
     WHERE (e.time AT TIME ZONE 'Asia/Tokyo')::date = days.d)              AS encounters,
  (SELECT COUNT(*) FROM public.likes l
     WHERE (l.created_at AT TIME ZONE 'Asia/Tokyo')::date = days.d)         AS likes,
  (SELECT COUNT(*) FROM public.matches m
     WHERE (m.matched_at AT TIME ZONE 'Asia/Tokyo')::date = days.d)        AS matches,
  -- アクティブユーザー = その日にいいね送信 or すれ違い発生した人数（重複排除）
  (SELECT COUNT(DISTINCT uid) FROM (
      SELECT from_user_id AS uid FROM public.likes l
        WHERE (l.created_at AT TIME ZONE 'Asia/Tokyo')::date = days.d
      UNION
      SELECT user_a_id FROM public.encounters e
        WHERE (e.time AT TIME ZONE 'Asia/Tokyo')::date = days.d
      UNION
      SELECT user_b_id FROM public.encounters e
        WHERE (e.time AT TIME ZONE 'Asia/Tokyo')::date = days.d
   ) t)                                                                    AS active_users
FROM days
ORDER BY days.d;


-- ============================================================
-- ② KPIスナップショット（毎日保存）
-- ------------------------------------------------------------
-- リアルタイムビューは「今の値」しか出せない。
-- 毎日1回ここに保存しておくことで、後から継続率・推移を正確に出せる。
-- ============================================================
CREATE TABLE IF NOT EXISTS public.kpi_snapshots (
  snapshot_date    DATE PRIMARY KEY,
  total_users      INT NOT NULL DEFAULT 0,
  new_users        INT NOT NULL DEFAULT 0,
  active_users     INT NOT NULL DEFAULT 0,
  encounters       INT NOT NULL DEFAULT 0,
  likes            INT NOT NULL DEFAULT 0,
  matches          INT NOT NULL DEFAULT 0,
  premium_users    INT NOT NULL DEFAULT 0,
  suspended_users  INT NOT NULL DEFAULT 0,
  pending_reports  INT NOT NULL DEFAULT 0,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE public.kpi_snapshots ENABLE ROW LEVEL SECURITY;
-- 一般ユーザーには一切見せない（ポリシー未作成＝authenticated/anonは参照不可）

-- 当日のKPIを計算してスナップショットに UPSERT する関数
CREATE OR REPLACE FUNCTION public.capture_kpi_snapshot()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_today DATE := (DATE_TRUNC('day', NOW() AT TIME ZONE 'Asia/Tokyo'))::date;
BEGIN
  INSERT INTO public.kpi_snapshots AS k (
    snapshot_date, total_users, new_users, active_users,
    encounters, likes, matches, premium_users, suspended_users, pending_reports
  )
  SELECT
    v_today,
    (SELECT COUNT(*) FROM public.users),
    d.new_users, d.active_users, d.encounters, d.likes, d.matches,
    (SELECT COUNT(*) FROM public.users WHERE is_premium),
    (SELECT COUNT(*) FROM public.users WHERE is_suspended),
    (SELECT COUNT(*) FROM public.reports WHERE status = 'pending')
  FROM public.kpi_daily d
  WHERE d.day = v_today
  ON CONFLICT (snapshot_date) DO UPDATE SET
    total_users     = EXCLUDED.total_users,
    new_users       = EXCLUDED.new_users,
    active_users    = EXCLUDED.active_users,
    encounters      = EXCLUDED.encounters,
    likes           = EXCLUDED.likes,
    matches         = EXCLUDED.matches,
    premium_users   = EXCLUDED.premium_users,
    suspended_users = EXCLUDED.suspended_users,
    pending_reports = EXCLUDED.pending_reports,
    created_at      = NOW();
END;
$$;


-- ============================================================
-- ③ 継続率（リテンション）ビュー
-- ------------------------------------------------------------
-- 登録日コホートごとに、登録から N 日後にアクティブだった割合。
-- アクティブ判定 = その日に likes 送信 or encounters 参加。
-- ============================================================
CREATE OR REPLACE VIEW public.kpi_retention AS
WITH cohort AS (
  SELECT
    user_id,
    (created_at AT TIME ZONE 'Asia/Tokyo')::date AS signup_day
  FROM public.users
),
activity AS (
  SELECT from_user_id AS user_id, (created_at AT TIME ZONE 'Asia/Tokyo')::date AS act_day
    FROM public.likes
  UNION
  SELECT user_a_id, (time AT TIME ZONE 'Asia/Tokyo')::date FROM public.encounters
  UNION
  SELECT user_b_id, (time AT TIME ZONE 'Asia/Tokyo')::date FROM public.encounters
)
SELECT
  c.signup_day,
  COUNT(DISTINCT c.user_id) AS cohort_size,
  ROUND(100.0 * COUNT(DISTINCT a1.user_id) / NULLIF(COUNT(DISTINCT c.user_id), 0), 1) AS d1_pct,
  ROUND(100.0 * COUNT(DISTINCT a7.user_id) / NULLIF(COUNT(DISTINCT c.user_id), 0), 1) AS d7_pct,
  ROUND(100.0 * COUNT(DISTINCT a30.user_id) / NULLIF(COUNT(DISTINCT c.user_id), 0), 1) AS d30_pct
FROM cohort c
LEFT JOIN activity a1  ON a1.user_id  = c.user_id AND a1.act_day  = c.signup_day + 1
LEFT JOIN activity a7  ON a7.user_id  = c.user_id AND a7.act_day  = c.signup_day + 7
LEFT JOIN activity a30 ON a30.user_id = c.user_id AND a30.act_day = c.signup_day + 30
GROUP BY c.signup_day
ORDER BY c.signup_day DESC;


-- ============================================================
-- ④ KPI系の権限を管理者(service_role)のみに限定
-- ============================================================
REVOKE ALL ON public.kpi_overview   FROM anon, authenticated;
REVOKE ALL ON public.kpi_daily      FROM anon, authenticated;
REVOKE ALL ON public.kpi_retention  FROM anon, authenticated;
REVOKE ALL ON public.kpi_snapshots  FROM anon, authenticated;
GRANT  SELECT ON public.kpi_overview, public.kpi_daily, public.kpi_retention, public.kpi_snapshots TO service_role;
REVOKE ALL ON FUNCTION public.capture_kpi_snapshot() FROM public;
GRANT  EXECUTE ON FUNCTION public.capture_kpi_snapshot() TO service_role;


-- ============================================================
-- ⑤ 定期バッチ（pg_cron）
-- ------------------------------------------------------------
-- pg_cron が無い環境ではスキップされる。その場合は Supabase の
-- 「Scheduled Functions / Cron」UI で同等のSQLを登録してください。
-- 時刻は UTC 指定（Supabaseのcronは原則UTC）。
-- ============================================================
DO $cron_setup$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'pg_cron') THEN
    CREATE EXTENSION IF NOT EXISTS pg_cron;

    -- a) 期限切れ encounters の削除（毎時0分）
    IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'delete-expired-encounters') THEN
      PERFORM cron.unschedule('delete-expired-encounters');
    END IF;
    PERFORM cron.schedule(
      'delete-expired-encounters', '0 * * * *',
      $job$DELETE FROM public.encounters WHERE expires_at < now()$job$
    );

    -- b) 古い位置情報の削除（毎時5分 / 24時間更新がない残骸を掃除）
    IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'cleanup-stale-locations') THEN
      PERFORM cron.unschedule('cleanup-stale-locations');
    END IF;
    PERFORM cron.schedule(
      'cleanup-stale-locations', '5 * * * *',
      $job$DELETE FROM public.user_locations WHERE updated_at < now() - INTERVAL '24 hours'$job$
    );

    -- c) KPIスナップショット保存（毎日 14:55 UTC = 23:55 JST）
    IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'capture-kpi-snapshot') THEN
      PERFORM cron.unschedule('capture-kpi-snapshot');
    END IF;
    PERFORM cron.schedule(
      'capture-kpi-snapshot', '55 14 * * *',
      $job$SELECT public.capture_kpi_snapshot()$job$
    );
  END IF;
END $cron_setup$;


-- ============================================================
-- 動作確認用クエリ（手動実行）
-- ============================================================
-- SELECT * FROM public.kpi_overview;
-- SELECT * FROM public.kpi_daily;
-- SELECT * FROM public.kpi_retention LIMIT 30;
-- SELECT public.capture_kpi_snapshot();  -- 今日の分を手動で記録
-- SELECT jobname, schedule FROM cron.job ORDER BY jobname;
