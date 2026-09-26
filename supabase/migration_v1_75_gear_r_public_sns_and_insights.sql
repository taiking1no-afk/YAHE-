-- ============================================================
-- Migration v1.75 : Gear R限定の公開SNSリンク + リアルタイム「インサイトアクティビティ」
-- Supabase SQL Editor で実行してください。前提: v1.17, v1.29, v1.68 実行済み。
-- ------------------------------------------------------------
-- ① Gear R購入者のみ、プロフィールに公開SNSリンクを1つ設定できるようにする。
--    従来の user_sns_links（マッチ後にチャットで個別に送るための非公開リンク）
--    とは別物。誰からでも常時閲覧可能（ブロック関係のみ除外）。
--    Gear Rでなくなったら自動的に非表示になる（読み取り時にも判定するため
--    後始末用のバッチが不要）。
--
-- ② 月次バッチ（gear_r_monthly_reports、外部cronが必要で実運用されていなかった）
--    をやめ、都度その場で集計する「インサイトアクティビティ」に置き換える。
--    新規: board_post_views（募集の閲覧数を記録する仕組みが元々存在しなかった）。
--    集計RPC get_gear_r_insights(p_days) が、プロフィール閲覧数・もらった
--    いいね数・送ったいいね数・マッチ数・SNSリンク開封数・開封からマッチに
--    至った人数・日別推移（グラフ用）・自分が主催した募集ごとの内訳
--    （参加者数・気になる数・閲覧数・参加者からのマッチ数）をまとめて返す。
--
--   何度実行しても安全（冪等）。
-- ============================================================

-- ① 公開SNSリンク ---------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.public_sns_links (
  user_id    UUID PRIMARY KEY REFERENCES public.users(user_id) ON DELETE CASCADE,
  platform   TEXT NOT NULL,
  url        TEXT NOT NULL,
  label      TEXT,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE public.public_sns_links ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "public_sns_links_select" ON public.public_sns_links;
CREATE POLICY "public_sns_links_select" ON public.public_sns_links FOR SELECT USING (
  -- Gear Rでなくなったら自動的に見えなくなる
  public.user_effective_plan(public_sns_links.user_id) = 'gear_r'
  AND NOT EXISTS (
    SELECT 1 FROM public.blocks b
    JOIN public.users me ON me.auth_id = auth.uid()
    WHERE b.blocker_id = me.user_id AND b.blocked_id = public_sns_links.user_id
  )
);

-- クライアントからの直接書き込みは禁止（Gear R判定をサーバー側で必ず通すため）
REVOKE INSERT, UPDATE, DELETE ON public.public_sns_links FROM authenticated, anon;

CREATE OR REPLACE FUNCTION public.set_public_sns_link(p_platform TEXT, p_url TEXT, p_label TEXT DEFAULT NULL)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_me UUID;
BEGIN
  SELECT user_id INTO v_me FROM public.users WHERE auth_id = auth.uid();
  IF v_me IS NULL THEN
    RAISE EXCEPTION 'unauthorized';
  END IF;
  IF public.user_effective_plan(v_me) <> 'gear_r' THEN
    RAISE EXCEPTION 'gear_r_required';
  END IF;

  IF p_url IS NULL OR trim(p_url) = '' THEN
    DELETE FROM public.public_sns_links WHERE user_id = v_me;
    RETURN;
  END IF;

  INSERT INTO public.public_sns_links (user_id, platform, url, label, updated_at)
  VALUES (v_me, p_platform, trim(p_url), NULLIF(trim(COALESCE(p_label, '')), ''), NOW())
  ON CONFLICT (user_id) DO UPDATE
    SET platform = EXCLUDED.platform, url = EXCLUDED.url, label = EXCLUDED.label, updated_at = NOW();
END;
$function$;

REVOKE ALL ON FUNCTION public.set_public_sns_link(TEXT, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.set_public_sns_link(TEXT, TEXT, TEXT) TO authenticated;


-- ② 募集(掲示板投稿)の閲覧数トラッキング -----------------------------------

CREATE TABLE IF NOT EXISTS public.board_post_views (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  post_id    UUID NOT NULL REFERENCES public.board_posts(post_id) ON DELETE CASCADE,
  viewer_id  UUID NOT NULL REFERENCES public.users(user_id) ON DELETE CASCADE,
  viewed_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_board_post_views_post ON public.board_post_views(post_id, viewed_at DESC);

ALTER TABLE public.board_post_views ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "board_post_views_select_organizer" ON public.board_post_views;
CREATE POLICY "board_post_views_select_organizer" ON public.board_post_views FOR SELECT USING (
  post_id IN (
    SELECT post_id FROM public.board_posts
    WHERE organizer_id IN (SELECT user_id FROM public.users WHERE auth_id = auth.uid())
  )
);

REVOKE INSERT, UPDATE, DELETE ON public.board_post_views FROM authenticated, anon;

CREATE OR REPLACE FUNCTION public.record_board_post_view(p_post_id UUID)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_me UUID;
  v_organizer_id UUID;
BEGIN
  SELECT user_id INTO v_me FROM public.users WHERE auth_id = auth.uid();
  IF v_me IS NULL THEN
    RETURN;
  END IF;

  SELECT organizer_id INTO v_organizer_id FROM public.board_posts WHERE post_id = p_post_id;
  IF v_organizer_id IS NULL OR v_organizer_id = v_me THEN
    RETURN; -- 投稿が無い、または主催者本人の閲覧はカウントしない
  END IF;

  -- 同一ユーザー・同一投稿は1日1回だけ記録する
  IF EXISTS (
    SELECT 1 FROM public.board_post_views
    WHERE post_id = p_post_id AND viewer_id = v_me
      AND viewed_at >= date_trunc('day', NOW())
  ) THEN
    RETURN;
  END IF;

  INSERT INTO public.board_post_views (post_id, viewer_id) VALUES (p_post_id, v_me);
END;
$function$;

REVOKE ALL ON FUNCTION public.record_board_post_view(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.record_board_post_view(UUID) TO authenticated;


-- ③ リアルタイム集計RPC ----------------------------------------------------

CREATE OR REPLACE FUNCTION public.get_gear_r_insights(p_days INT DEFAULT 30)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_me UUID;
  v_since TIMESTAMPTZ;
  v_profile_views INT;
  v_likes_received INT;
  v_likes_sent INT;
  v_matches INT;
  v_link_clicks INT;
  v_link_click_to_match INT;
  v_daily JSONB;
  v_posts JSONB;
BEGIN
  SELECT user_id INTO v_me FROM public.users WHERE auth_id = auth.uid();
  IF v_me IS NULL THEN
    RAISE EXCEPTION 'unauthorized';
  END IF;
  IF public.user_effective_plan(v_me) <> 'gear_r' THEN
    RAISE EXCEPTION 'gear_r_required';
  END IF;

  v_since := NOW() - (GREATEST(p_days, 1) || ' days')::interval;

  SELECT count(*) INTO v_profile_views
  FROM public.profile_views WHERE viewed_user_id = v_me AND viewed_at >= v_since;

  SELECT count(*) INTO v_likes_received
  FROM public.likes WHERE to_user_id = v_me AND created_at >= v_since;

  SELECT count(*) INTO v_likes_sent
  FROM public.likes WHERE from_user_id = v_me AND created_at >= v_since;

  SELECT count(*) INTO v_matches
  FROM public.matches WHERE (user_a_id = v_me OR user_b_id = v_me) AND matched_at >= v_since;

  SELECT count(*) INTO v_link_clicks
  FROM public.sns_link_clicks WHERE owner_user_id = v_me AND clicked_at >= v_since;

  -- 公開SNSリンクを開いた人のうち、そのままマッチに至った人数
  SELECT count(DISTINCT c.clicker_user_id) INTO v_link_click_to_match
  FROM public.sns_link_clicks c
  WHERE c.owner_user_id = v_me AND c.clicked_at >= v_since
    AND EXISTS (
      SELECT 1 FROM public.matches m
      WHERE (m.user_a_id = v_me AND m.user_b_id = c.clicker_user_id)
         OR (m.user_b_id = v_me AND m.user_a_id = c.clicker_user_id)
    );

  -- グラフ用の日別推移
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'date', d.day,
    'profile_views', d.pv,
    'link_clicks', d.lc
  ) ORDER BY d.day), '[]'::jsonb)
  INTO v_daily
  FROM (
    SELECT
      gs.day::date AS day,
      (SELECT count(*) FROM public.profile_views pv
        WHERE pv.viewed_user_id = v_me AND pv.viewed_at::date = gs.day) AS pv,
      (SELECT count(*) FROM public.sns_link_clicks sc
        WHERE sc.owner_user_id = v_me AND sc.clicked_at::date = gs.day) AS lc
    FROM generate_series(v_since::date, NOW()::date, '1 day') AS gs(day)
  ) d;

  -- 自分が主催した募集ごとの内訳
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'post_id', p.post_id,
    'title', p.title,
    'scheduled_at', p.scheduled_at,
    'joined_count', p.joined_count,
    'interested_count', p.interested_count,
    'view_count', p.view_count,
    'matched_participants', p.matched_participants
  ) ORDER BY p.created_at DESC), '[]'::jsonb)
  INTO v_posts
  FROM (
    SELECT
      bp.post_id,
      bp.title,
      bp.scheduled_at,
      bp.created_at,
      (SELECT count(*) FROM public.board_participations x
        WHERE x.post_id = bp.post_id AND x.status = 'joined') AS joined_count,
      (SELECT count(*) FROM public.board_participations x
        WHERE x.post_id = bp.post_id AND x.status = 'interested') AS interested_count,
      (SELECT count(*) FROM public.board_post_views v WHERE v.post_id = bp.post_id) AS view_count,
      (SELECT count(DISTINCT x.user_id) FROM public.board_participations x
        WHERE x.post_id = bp.post_id AND x.status IN ('joined', 'interested')
          AND EXISTS (
            SELECT 1 FROM public.matches m
            WHERE (m.user_a_id = v_me AND m.user_b_id = x.user_id)
               OR (m.user_b_id = v_me AND m.user_a_id = x.user_id)
          )) AS matched_participants
    FROM public.board_posts bp
    WHERE bp.organizer_id = v_me
    ORDER BY bp.created_at DESC
    LIMIT 30
  ) p;

  RETURN jsonb_build_object(
    'period_days', p_days,
    'profile_views', v_profile_views,
    'likes_received', v_likes_received,
    'likes_sent', v_likes_sent,
    'matches', v_matches,
    'link_clicks', v_link_clicks,
    'link_click_to_match', v_link_click_to_match,
    'daily', v_daily,
    'posts', v_posts
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.get_gear_r_insights(INT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_gear_r_insights(INT) TO authenticated;


-- ============================================================
-- 動作確認用クエリ（手動実行）
-- ============================================================
-- SELECT has_function_privilege('authenticated', 'public.get_gear_r_insights(int)', 'execute') AS can_exec;
-- SELECT has_function_privilege('authenticated', 'public.set_public_sns_link(text,text,text)', 'execute') AS can_exec;
-- SELECT has_function_privilege('authenticated', 'public.record_board_post_view(uuid)', 'execute') AS can_exec;
