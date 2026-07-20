-- ============================================================
-- Migration v1.19 : Gear R 認証バッジラベル
-- Supabase SQL Editor で実行してください。前提: v1.1〜v1.18 実行済み。
-- ------------------------------------------------------------
-- Gear R ユーザーがプロフィールに表示する認証ラベルを自由設定できるようにする。
-- 何度実行しても安全（冪等）。
-- ============================================================

ALTER TABLE public.users
  ADD COLUMN IF NOT EXISTS verified_label TEXT;

COMMENT ON COLUMN public.users.verified_label IS
  'Gear R 認証バッジの表示ラベル（例: インフルエンサー）。空/null で非表示。';
