-- ============================================================
-- Migration v1.99 : データ主体の請求（開示・訂正・利用停止・削除）対応
-- Supabase SQL Editor で実行してください。
-- ------------------------------------------------------------
-- 背景:
--   個人情報保護委員会のガイドラインは、本人からの開示・訂正・利用停止・
--   削除請求への対応手続を明示することを求めている。これまでアプリには
--   全アカウント削除（delete-account）以外に請求を受け付ける経路が無かった。
--
--   スコープ: 個人開発の運用能力を踏まえ、まず「請求を構造化して受け付け、
--   記録する」MVPとする。実際の開示/訂正/制限の実行は運営が手動で対応する
--   （フルセルフサービスの自動開示・エクスポート機能までは今回のスコープ外）。
--
--   何度実行しても安全（冪等）。
-- ============================================================

CREATE TABLE IF NOT EXISTS public.data_subject_requests (
  request_id   UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id      UUID NOT NULL REFERENCES public.users(user_id) ON DELETE CASCADE,
  request_type TEXT NOT NULL CHECK (request_type IN ('disclosure', 'correction', 'restriction', 'deletion')),
  detail       TEXT,
  status       TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'in_progress', 'completed', 'rejected')),
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  resolved_at  TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_data_subject_requests_user ON public.data_subject_requests(user_id, created_at DESC);

ALTER TABLE public.data_subject_requests ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "dsar_insert_own" ON public.data_subject_requests;
CREATE POLICY "dsar_insert_own" ON public.data_subject_requests FOR INSERT WITH CHECK (
  user_id IN (SELECT user_id FROM public.users WHERE auth_id = auth.uid())
);

DROP POLICY IF EXISTS "dsar_select_own" ON public.data_subject_requests;
CREATE POLICY "dsar_select_own" ON public.data_subject_requests FOR SELECT USING (
  user_id IN (SELECT user_id FROM public.users WHERE auth_id = auth.uid())
);

-- status更新はservice_role（運営）のみ
REVOKE UPDATE, DELETE ON public.data_subject_requests FROM authenticated, anon;
GRANT SELECT, UPDATE ON public.data_subject_requests TO service_role;

-- ============================================================
-- 動作確認用クエリ（手動実行）
-- ============================================================
-- SELECT * FROM public.data_subject_requests ORDER BY created_at DESC LIMIT 20;
