-- ============================================================
-- user_locations テーブル
-- GPS 近傍すれ違い検知用（100km/h 高速すれ違いテスト対応）
--
-- 設計ポリシー:
--   - user_id が PRIMARY KEY のため "最新位置のみ" を保持（履歴は残さない）
--   - クライアントは UPSERT で上書き更新
--   - サービス停止時にクライアントが行を DELETE（プライバシー保護）
--   - updated_at が 10 秒以上古い行は "アクティブ走行中でない" とみなして近傍クエリで除外
-- ============================================================

CREATE TABLE IF NOT EXISTS public.user_locations (
  user_id    UUID NOT NULL PRIMARY KEY REFERENCES public.users(user_id) ON DELETE CASCADE,
  lat        DOUBLE PRECISION NOT NULL,
  lng        DOUBLE PRECISION NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE public.user_locations ENABLE ROW LEVEL SECURITY;

-- 認証済みユーザーなら全員の最新位置を読める（近傍クエリに必要）
CREATE POLICY "locations_select_authenticated" ON public.user_locations
  FOR SELECT USING (auth.role() = 'authenticated');

-- 自分の行のみ INSERT
CREATE POLICY "locations_insert_own" ON public.user_locations
  FOR INSERT WITH CHECK (auth.uid() = user_id);

-- 自分の行のみ UPDATE
CREATE POLICY "locations_update_own" ON public.user_locations
  FOR UPDATE USING (auth.uid() = user_id);

-- 自分の行のみ DELETE（サービス停止時に位置情報を削除）
CREATE POLICY "locations_delete_own" ON public.user_locations
  FOR DELETE USING (auth.uid() = user_id);
