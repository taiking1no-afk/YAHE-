-- ============================================================
-- Migration v1.14 : LP 事前登録（preregistrations）
-- Supabase SQL Editor で実行してください。
-- ------------------------------------------------------------
-- 目的:
--   ① 事前登録メールを Supabase に保存（件数上限なし）
--   ② LP からは RPC 経由のみ（メール一覧は anon から読めない）
--   ③ 登録数カウンター用 RPC（件数のみ公開）
--
--   何度実行しても安全（冪等）。
-- ============================================================

CREATE TABLE IF NOT EXISTS public.preregistrations (
  id         UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  email      TEXT NOT NULL,
  source     TEXT NOT NULL DEFAULT 'register.html',
  referrer   TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT preregistrations_email_unique UNIQUE (email),
  CONSTRAINT preregistrations_email_format CHECK (
    email ~ '^[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}$'
  )
);

CREATE INDEX IF NOT EXISTS idx_preregistrations_created_at
  ON public.preregistrations (created_at DESC);

COMMENT ON TABLE public.preregistrations IS
  'LP事前登録メール。LP(anon)はRPC経由のINSERTのみ。一覧はservice_roleで閲覧。';

ALTER TABLE public.preregistrations ENABLE ROW LEVEL SECURITY;

-- anon / authenticated からの直接アクセスは拒否（RPC の SECURITY DEFINER でのみ書き込み）
REVOKE ALL ON TABLE public.preregistrations FROM anon, authenticated;

-- ------------------------------------------------------------
-- 登録 RPC（LP から呼ぶ）
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.submit_preregistration(
  p_email    TEXT,
  p_source   TEXT DEFAULT 'register.html',
  p_referrer TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_email TEXT;
  v_id    UUID;
BEGIN
  v_email := LOWER(BTRIM(p_email));

  IF v_email IS NULL OR v_email = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'email_required');
  END IF;

  IF v_email !~ '^[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}$' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_email');
  END IF;

  INSERT INTO public.preregistrations (email, source, referrer)
  VALUES (v_email, COALESCE(NULLIF(BTRIM(p_source), ''), 'register.html'), p_referrer)
  ON CONFLICT (email) DO NOTHING
  RETURNING id INTO v_id;

  IF v_id IS NULL THEN
    RETURN jsonb_build_object('ok', true, 'duplicate', true);
  END IF;

  RETURN jsonb_build_object('ok', true);
END;
$$;

-- ------------------------------------------------------------
-- 件数 RPC（LP カウンター用・件数のみ返す）
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_preregistration_count()
RETURNS BIGINT
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
STABLE
AS $$
  SELECT COUNT(*)::bigint FROM public.preregistrations;
$$;

REVOKE ALL ON FUNCTION public.submit_preregistration(TEXT, TEXT, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_preregistration_count() FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.submit_preregistration(TEXT, TEXT, TEXT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_preregistration_count() TO anon, authenticated;
