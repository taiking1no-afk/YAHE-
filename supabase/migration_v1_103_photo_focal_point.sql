-- ============================================================
-- Migration v1.103 : プロフィール画像・愛車画像の表示位置（焦点）を
--                    本人が設定できるようにする
-- Supabase SQL Editor で実行してください。
-- ------------------------------------------------------------
-- 背景:
--   一覧/サムネイル表示では BoxFit.cover で中央固定トリミングされており、
--   被写体が中央からずれていると重要な部分が見切れていた。
--   本人が「どの位置を中心に表示するか」を選べるようにするため、
--   正規化座標（0.0〜1.0、デフォルト0.5=中央）で焦点を保存する。
--
--   何度実行しても安全（冪等）。
-- ============================================================

ALTER TABLE public.users
  ADD COLUMN IF NOT EXISTS avatar_focal_x DOUBLE PRECISION NOT NULL DEFAULT 0.5,
  ADD COLUMN IF NOT EXISTS avatar_focal_y DOUBLE PRECISION NOT NULL DEFAULT 0.5;

ALTER TABLE public.vehicles
  ADD COLUMN IF NOT EXISTS photo_focal_x DOUBLE PRECISION NOT NULL DEFAULT 0.5,
  ADD COLUMN IF NOT EXISTS photo_focal_y DOUBLE PRECISION NOT NULL DEFAULT 0.5;

-- 範囲チェック（0.0〜1.0の外側は無効な値として拒否する）
ALTER TABLE public.users DROP CONSTRAINT IF EXISTS users_avatar_focal_range;
ALTER TABLE public.users ADD CONSTRAINT users_avatar_focal_range
  CHECK (avatar_focal_x BETWEEN 0 AND 1 AND avatar_focal_y BETWEEN 0 AND 1);

ALTER TABLE public.vehicles DROP CONSTRAINT IF EXISTS vehicles_photo_focal_range;
ALTER TABLE public.vehicles ADD CONSTRAINT vehicles_photo_focal_range
  CHECK (photo_focal_x BETWEEN 0 AND 1 AND photo_focal_y BETWEEN 0 AND 1);

-- ============================================================
-- 動作確認用クエリ（手動実行）
-- ============================================================
-- SELECT column_name FROM information_schema.columns WHERE table_name='users' AND column_name LIKE 'avatar_focal%';
-- SELECT column_name FROM information_schema.columns WHERE table_name='vehicles' AND column_name LIKE 'photo_focal%';
