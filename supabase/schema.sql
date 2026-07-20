-- ============================================================
-- SURF (すれ違いマッチングアプリ) Database Schema
-- Supabase / PostgreSQL
-- ============================================================

-- Enable UUID extension
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- ============================================================
-- USERS テーブル
-- ============================================================
CREATE TABLE IF NOT EXISTS public.users (
  user_id       UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  auth_id       UUID NOT NULL UNIQUE REFERENCES auth.users(id) ON DELETE CASCADE,
  nickname      TEXT NOT NULL,
  area          TEXT,                         -- 居住エリア（任意）
  comment       TEXT,                         -- 一言コメント（任意）
  sns_links     JSONB DEFAULT '[]'::JSONB,    -- [{platform, url, label}]
  is_premium    BOOLEAN NOT NULL DEFAULT FALSE,
  anonymous_mode BOOLEAN NOT NULL DEFAULT FALSE,
  quiet_start   TIME DEFAULT '23:00:00',      -- 深夜通知オフ開始
  quiet_end     TIME DEFAULT '06:00:00',      -- 深夜通知オフ終了
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ============================================================
-- VEHICLES テーブル
-- ============================================================
CREATE TABLE IF NOT EXISTS public.vehicles (
  vehicle_id  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id     UUID NOT NULL REFERENCES public.users(user_id) ON DELETE CASCADE,
  maker       TEXT NOT NULL,
  model       TEXT NOT NULL,
  year        INT,
  tags        TEXT[] DEFAULT '{}',             -- 改造系統タグ
  photos      TEXT[] DEFAULT '{}',             -- Supabase Storage URL（モザイク処理済み）
  is_active   BOOLEAN NOT NULL DEFAULT TRUE,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ============================================================
-- ENCOUNTERS テーブル（すれ違い記録）
-- 位置情報は一切保存しない
-- ============================================================
CREATE TABLE IF NOT EXISTS public.encounters (
  encounter_id  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_a_id     UUID NOT NULL REFERENCES public.users(user_id) ON DELETE CASCADE,
  user_b_id     UUID NOT NULL REFERENCES public.users(user_id) ON DELETE CASCADE,
  time          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  expires_at    TIMESTAMPTZ NOT NULL,          -- 無料:+24h / 有料:+7d
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT encounters_no_self CHECK (user_a_id <> user_b_id),
  CONSTRAINT encounters_order CHECK (user_a_id < user_b_id)  -- 重複防止
);

CREATE INDEX IF NOT EXISTS idx_encounters_user_a ON public.encounters(user_a_id);
CREATE INDEX IF NOT EXISTS idx_encounters_user_b ON public.encounters(user_b_id);
CREATE INDEX IF NOT EXISTS idx_encounters_expires ON public.encounters(expires_at);

-- ============================================================
-- LIKES テーブル
-- ============================================================
CREATE TABLE IF NOT EXISTS public.likes (
  like_id       UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  from_user_id  UUID NOT NULL REFERENCES public.users(user_id) ON DELETE CASCADE,
  to_user_id    UUID NOT NULL REFERENCES public.users(user_id) ON DELETE CASCADE,
  encounter_id  UUID NOT NULL REFERENCES public.encounters(encounter_id) ON DELETE CASCADE,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT likes_no_self CHECK (from_user_id <> to_user_id),
  CONSTRAINT likes_unique UNIQUE (from_user_id, to_user_id, encounter_id)
);

CREATE INDEX IF NOT EXISTS idx_likes_from_user ON public.likes(from_user_id);
CREATE INDEX IF NOT EXISTS idx_likes_to_user ON public.likes(to_user_id);

-- ============================================================
-- MATCHES テーブル（相互いいね・永久保持）
-- ============================================================
CREATE TABLE IF NOT EXISTS public.matches (
  match_id    UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_a_id   UUID NOT NULL REFERENCES public.users(user_id) ON DELETE CASCADE,
  user_b_id   UUID NOT NULL REFERENCES public.users(user_id) ON DELETE CASCADE,
  matched_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT matches_no_self CHECK (user_a_id <> user_b_id),
  CONSTRAINT matches_unique UNIQUE (user_a_id, user_b_id),
  CONSTRAINT matches_order CHECK (user_a_id < user_b_id)
);

CREATE INDEX IF NOT EXISTS idx_matches_user_a ON public.matches(user_a_id);
CREATE INDEX IF NOT EXISTS idx_matches_user_b ON public.matches(user_b_id);

-- ============================================================
-- PRIVACY_ZONES テーブル（愛車ガード）
-- ============================================================
CREATE TABLE IF NOT EXISTS public.privacy_zones (
  zone_id    UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id    UUID NOT NULL REFERENCES public.users(user_id) ON DELETE CASCADE,
  lat        DOUBLE PRECISION NOT NULL,
  lng        DOUBLE PRECISION NOT NULL,
  radius_m   INT NOT NULL DEFAULT 1000,
  label      TEXT DEFAULT 'その他',           -- 自宅・職場・その他
  is_active  BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_privacy_zones_user ON public.privacy_zones(user_id);

-- ============================================================
-- BLOCKS テーブル
-- ============================================================
CREATE TABLE IF NOT EXISTS public.blocks (
  block_id    UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  blocker_id  UUID NOT NULL REFERENCES public.users(user_id) ON DELETE CASCADE,
  blocked_id  UUID NOT NULL REFERENCES public.users(user_id) ON DELETE CASCADE,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT blocks_no_self CHECK (blocker_id <> blocked_id),
  CONSTRAINT blocks_unique UNIQUE (blocker_id, blocked_id)
);

CREATE INDEX IF NOT EXISTS idx_blocks_blocker ON public.blocks(blocker_id);
CREATE INDEX IF NOT EXISTS idx_blocks_blocked ON public.blocks(blocked_id);

-- ============================================================
-- REPORTS テーブル
-- ============================================================
CREATE TABLE IF NOT EXISTS public.reports (
  report_id   UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  reporter_id UUID NOT NULL REFERENCES public.users(user_id) ON DELETE CASCADE,
  target_id   UUID NOT NULL REFERENCES public.users(user_id) ON DELETE CASCADE,
  category    TEXT NOT NULL CHECK (category IN ('inappropriate_photo', 'impersonation', 'spam', 'other')),
  detail      TEXT,
  status      TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'reviewed', 'resolved')),
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ============================================================
-- LIKE_DAILY_COUNTS ビュー（1日10回制限）
-- ============================================================
CREATE OR REPLACE VIEW public.today_like_counts AS
SELECT
  from_user_id,
  COUNT(*) AS like_count
FROM public.likes
WHERE created_at >= DATE_TRUNC('day', NOW() AT TIME ZONE 'Asia/Tokyo') AT TIME ZONE 'Asia/Tokyo'
  AND created_at <  DATE_TRUNC('day', NOW() AT TIME ZONE 'Asia/Tokyo') AT TIME ZONE 'Asia/Tokyo' + INTERVAL '1 day'
GROUP BY from_user_id;

-- ============================================================
-- 期限切れencounters自動削除（pg_cron推奨、または定期バッチ）
-- ============================================================
-- SELECT cron.schedule('delete-expired-encounters', '0 * * * *',
--   $$DELETE FROM public.encounters WHERE expires_at < NOW()$$);

-- ============================================================
-- Row Level Security (RLS)
-- ============================================================
ALTER TABLE public.users ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.vehicles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.encounters ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.likes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.matches ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.privacy_zones ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.blocks ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.reports ENABLE ROW LEVEL SECURITY;

-- users: 自分のレコードのみ更新可。閲覧はマッチング後のみ（Functionで制御）
CREATE POLICY "users_select_own" ON public.users FOR SELECT USING (auth.uid() = auth_id);
-- 他ユーザーの基本プロフィールも閲覧可
CREATE POLICY "users_select_public" ON public.users FOR SELECT USING (true);
CREATE POLICY "users_update_own" ON public.users FOR UPDATE USING (auth.uid() = auth_id);
CREATE POLICY "users_insert_own" ON public.users FOR INSERT WITH CHECK (auth.uid() = auth_id);

-- vehicles: 自分のものは全操作可。他者のものは閲覧のみ
CREATE POLICY "vehicles_all_own" ON public.vehicles FOR ALL USING (
  user_id IN (SELECT user_id FROM public.users WHERE auth_id = auth.uid())
);
CREATE POLICY "vehicles_select_others" ON public.vehicles FOR SELECT USING (is_active = TRUE);

-- encounters: 自分が関係するもののみ閲覧可
CREATE POLICY "encounters_select_own" ON public.encounters FOR SELECT USING (
  user_a_id IN (SELECT user_id FROM public.users WHERE auth_id = auth.uid()) OR
  user_b_id IN (SELECT user_id FROM public.users WHERE auth_id = auth.uid())
);

-- encounters: 自分が参加者であれば登録可
CREATE POLICY "encounters_insert_own" ON public.encounters FOR INSERT WITH CHECK (
  user_a_id IN (SELECT user_id FROM public.users WHERE auth_id = auth.uid()) OR
  user_b_id IN (SELECT user_id FROM public.users WHERE auth_id = auth.uid())
);

-- likes: 自分の送信したものは全操作可。受信は閲覧のみ
CREATE POLICY "likes_insert_own" ON public.likes FOR INSERT WITH CHECK (
  from_user_id IN (SELECT user_id FROM public.users WHERE auth_id = auth.uid())
);
CREATE POLICY "likes_select_own" ON public.likes FOR SELECT USING (
  from_user_id IN (SELECT user_id FROM public.users WHERE auth_id = auth.uid()) OR
  to_user_id IN (SELECT user_id FROM public.users WHERE auth_id = auth.uid())
);

-- matches: 自分が関係するもののみ閲覧可
CREATE POLICY "matches_select_own" ON public.matches FOR SELECT USING (
  user_a_id IN (SELECT user_id FROM public.users WHERE auth_id = auth.uid()) OR
  user_b_id IN (SELECT user_id FROM public.users WHERE auth_id = auth.uid())
);

-- privacy_zones: 自分のもののみ
CREATE POLICY "privacy_zones_own" ON public.privacy_zones FOR ALL USING (
  user_id IN (SELECT user_id FROM public.users WHERE auth_id = auth.uid())
);

-- blocks: 自分のもののみ
CREATE POLICY "blocks_own" ON public.blocks FOR ALL USING (
  blocker_id IN (SELECT user_id FROM public.users WHERE auth_id = auth.uid())
);

-- reports: 自分が送ったものは全操作可
CREATE POLICY "reports_insert_own" ON public.reports FOR INSERT WITH CHECK (
  reporter_id IN (SELECT user_id FROM public.users WHERE auth_id = auth.uid())
);
CREATE POLICY "reports_select_own" ON public.reports FOR SELECT USING (
  reporter_id IN (SELECT user_id FROM public.users WHERE auth_id = auth.uid())
);

-- ============================================================
-- Trigger: updated_at 自動更新
-- ============================================================
CREATE OR REPLACE FUNCTION public.update_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER users_updated_at BEFORE UPDATE ON public.users
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

CREATE TRIGGER vehicles_updated_at BEFORE UPDATE ON public.vehicles
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

-- ============================================================
-- Function: いいね送信 + マッチング判定（アトミック処理）
-- ============================================================
CREATE OR REPLACE FUNCTION public.send_like(
  p_from_user_id UUID,
  p_to_user_id   UUID,
  p_encounter_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_is_matched   BOOLEAN := FALSE;
  v_match_id     UUID;
  v_like_count   INT;
  v_is_premium   BOOLEAN;
  v_user_a       UUID;
  v_user_b       UUID;
BEGIN
  -- プレミアム判定
  SELECT is_premium INTO v_is_premium FROM public.users WHERE user_id = p_from_user_id;

  -- 無料プランの1日制限チェック
  IF NOT v_is_premium THEN
    SELECT like_count INTO v_like_count
    FROM public.today_like_counts
    WHERE from_user_id = p_from_user_id;

    IF COALESCE(v_like_count, 0) >= 10 THEN
      RETURN jsonb_build_object('success', FALSE, 'error', 'daily_limit_exceeded');
    END IF;
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
    -- matches テーブルへ挿入（user_a < user_b の順序を保証）
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
