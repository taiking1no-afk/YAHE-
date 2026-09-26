-- ============================================================
-- Migration v1.100 : pgTAP拡張の有効化（自動RLSテスト用）
-- Supabase SQL Editor で実行してください。
-- ------------------------------------------------------------
-- supabase/tests/rls_priority_tables.sql のpgTAPテストを実行するために
-- 必要。テスト自体はBEGIN/ROLLBACKで囲まれており、本番データには
-- 一切影響しない（フィクスチャ行はロールバックで消える）。
--
--   何度実行しても安全（冪等）。
-- ============================================================
CREATE SCHEMA IF NOT EXISTS extensions;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
