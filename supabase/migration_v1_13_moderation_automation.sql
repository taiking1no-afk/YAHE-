-- ============================================================
-- Migration v1.13 : 安全性運営の自動化（NGワード検知 + モデレーションキュー）
-- Supabase SQL Editor で実行してください。前提: v1.11 / v1.12 実行済み。
-- ------------------------------------------------------------
-- 目的:
--   ① NGワード辞書（ng_words）と自動検知
--      - users.nickname / users.comment にNGワードが含まれたら
--        自動でフラグを立てる（moderation_flags へ記録）
--      - severity='critical' は即 is_suspended=TRUE（自動非表示）
--      - severity='warn'    はキューに積むだけ（運営が後で判断）
--   ② モデレーションキュー（moderation_queue）ビュー
--      - 通報の自動集計（target別の通報数・通報者数・カテゴリ）
--      - NGワードフラグ
--      を1つの「対応すべきリスト」に統合（運営=service_roleのみ閲覧）
--   ③ 運営オペRPC（管理者用）: 停止 / 停止解除 / 通報のクローズ
--
--   何度実行しても安全（冪等）。
-- ============================================================


-- ============================================================
-- ① NGワード辞書
-- ============================================================
CREATE TABLE IF NOT EXISTS public.ng_words (
  word       TEXT PRIMARY KEY,
  severity   TEXT NOT NULL DEFAULT 'warn' CHECK (severity IN ('warn', 'critical')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE public.ng_words ENABLE ROW LEVEL SECURITY;
-- 一般ユーザーには見せない（辞書を見せると回避されるため）

-- 初期辞書（運用しながら追記してください）
-- critical = 即停止 / warn = 要確認キュー行き
INSERT INTO public.ng_words (word, severity) VALUES
  ('死ね',       'critical'),
  ('殺す',       'critical'),
  ('しね',       'critical'),
  ('援交',       'critical'),
  ('出会い系',   'warn'),
  ('稼げる',     'warn'),
  ('副業',       'warn'),
  ('投資',       'warn'),
  ('line交換',   'warn'),
  ('whatsapp',   'warn'),
  ('テレグラム', 'warn')
ON CONFLICT (word) DO NOTHING;


-- ============================================================
-- ② モデレーションフラグ（自動検知の記録）
-- ============================================================
CREATE TABLE IF NOT EXISTS public.moderation_flags (
  flag_id    UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id    UUID NOT NULL REFERENCES public.users(user_id) ON DELETE CASCADE,
  reason     TEXT NOT NULL,                 -- 例: 'ng_word:援交'
  severity   TEXT NOT NULL DEFAULT 'warn' CHECK (severity IN ('warn', 'critical')),
  field      TEXT,                          -- 'nickname' / 'comment' など
  snippet    TEXT,                          -- 検知した文字列の一部
  status     TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'resolved', 'ignored')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_moderation_flags_status ON public.moderation_flags(status);
CREATE INDEX IF NOT EXISTS idx_moderation_flags_user   ON public.moderation_flags(user_id);

ALTER TABLE public.moderation_flags ENABLE ROW LEVEL SECURITY;
-- 一般ユーザーには見せない（service_role / SQL Editor 専用）


-- ============================================================
-- ③ NGワード自動検知トリガ
-- ------------------------------------------------------------
-- nickname / comment にNGワードが含まれていたら moderation_flags に記録。
-- critical を踏んだら即 is_suspended=TRUE（検索・すれ違いから自動除外）。
-- ※ 大文字小文字を無視して部分一致判定。
-- ============================================================
CREATE OR REPLACE FUNCTION public.scan_profile_ng_words()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_word        RECORD;
  v_hit_critical BOOLEAN := FALSE;
  v_text         TEXT;
BEGIN
  v_text := lower(COALESCE(NEW.nickname, '') || ' ' || COALESCE(NEW.comment, ''));

  FOR v_word IN SELECT word, severity FROM public.ng_words LOOP
    IF position(lower(v_word.word) IN v_text) > 0 THEN
      INSERT INTO public.moderation_flags (user_id, reason, severity, field, snippet)
      VALUES (
        NEW.user_id,
        'ng_word:' || v_word.word,
        v_word.severity,
        CASE WHEN position(lower(v_word.word) IN lower(COALESCE(NEW.nickname, ''))) > 0
             THEN 'nickname' ELSE 'comment' END,
        v_word.word
      );
      IF v_word.severity = 'critical' THEN
        v_hit_critical := TRUE;
      END IF;
    END IF;
  END LOOP;

  IF v_hit_critical THEN
    NEW.is_suspended := TRUE;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_scan_profile_ng_words ON public.users;
CREATE TRIGGER trg_scan_profile_ng_words
BEFORE INSERT OR UPDATE OF nickname, comment ON public.users
FOR EACH ROW
EXECUTE FUNCTION public.scan_profile_ng_words();


-- ============================================================
-- ④ モデレーションキュー（運営の「対応すべきリスト」）
-- ------------------------------------------------------------
-- 通報集計 + NGワードフラグを1つの優先度付きリストに統合。
-- priority_score が高いほど早く対応すべき。
-- ============================================================
CREATE OR REPLACE VIEW public.moderation_queue AS
WITH report_agg AS (
  SELECT
    target_id AS user_id,
    COUNT(*)                          AS report_count,
    COUNT(DISTINCT reporter_id)       AS distinct_reporters,
    MAX(created_at)                   AS last_reported_at,
    string_agg(DISTINCT category, ',') AS categories
  FROM public.reports
  WHERE status = 'pending'
  GROUP BY target_id
),
flag_agg AS (
  SELECT
    user_id,
    COUNT(*)                                            AS flag_count,
    COUNT(*) FILTER (WHERE severity = 'critical')       AS critical_flags,
    string_agg(DISTINCT reason, ',')                    AS flag_reasons,
    MAX(created_at)                                     AS last_flagged_at
  FROM public.moderation_flags
  WHERE status = 'open'
  GROUP BY user_id
),
targets AS (
  SELECT user_id FROM report_agg
  UNION
  SELECT user_id FROM flag_agg
)
SELECT
  u.user_id,
  u.nickname,
  u.is_suspended,
  u.created_at AS user_created_at,
  COALESCE(r.report_count, 0)        AS report_count,
  COALESCE(r.distinct_reporters, 0)  AS distinct_reporters,
  r.categories,
  COALESCE(f.flag_count, 0)          AS flag_count,
  COALESCE(f.critical_flags, 0)      AS critical_flags,
  f.flag_reasons,
  GREATEST(COALESCE(r.last_reported_at, '-infinity'::timestamptz),
           COALESCE(f.last_flagged_at, '-infinity'::timestamptz)) AS last_event_at,
  -- 優先度: 通報者数×10 + critical×20 + 通報数×3 + フラグ数
  (COALESCE(r.distinct_reporters, 0) * 10
   + COALESCE(f.critical_flags, 0) * 20
   + COALESCE(r.report_count, 0) * 3
   + COALESCE(f.flag_count, 0))      AS priority_score
FROM targets t
JOIN public.users u ON u.user_id = t.user_id
LEFT JOIN report_agg r ON r.user_id = t.user_id
LEFT JOIN flag_agg   f ON f.user_id = t.user_id
ORDER BY priority_score DESC, last_event_at DESC;


-- ============================================================
-- ⑤ 運営オペRPC（管理者=service_role 専用）
-- ------------------------------------------------------------
-- KING / 運営が SQL Editor や Edge Function 経由で安全に実行するための関数。
-- 一般ユーザー(authenticated)には GRANT しない。
-- ============================================================

-- ユーザーを停止（手動BAN）
CREATE OR REPLACE FUNCTION public.admin_suspend_user(p_user_id UUID, p_reason TEXT DEFAULT NULL)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE public.users SET is_suspended = TRUE WHERE user_id = p_user_id;
  -- 関連する未処理フラグ・通報をクローズ
  UPDATE public.moderation_flags SET status = 'resolved' WHERE user_id = p_user_id AND status = 'open';
  UPDATE public.reports SET status = 'resolved' WHERE target_id = p_user_id AND status = 'pending';
END;
$$;

-- 停止解除（誤検知の救済）
CREATE OR REPLACE FUNCTION public.admin_unsuspend_user(p_user_id UUID)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE public.users SET is_suspended = FALSE WHERE user_id = p_user_id;
  UPDATE public.moderation_flags SET status = 'ignored' WHERE user_id = p_user_id AND status = 'open';
  UPDATE public.reports SET status = 'reviewed' WHERE target_id = p_user_id AND status = 'pending';
END;
$$;

-- 「問題なし」としてキューから外す（停止はしない）
CREATE OR REPLACE FUNCTION public.admin_dismiss_user(p_user_id UUID)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE public.moderation_flags SET status = 'ignored' WHERE user_id = p_user_id AND status = 'open';
  UPDATE public.reports SET status = 'reviewed' WHERE target_id = p_user_id AND status = 'pending';
END;
$$;


-- ============================================================
-- ⑥ 権限設定（すべて管理者のみ）
-- ============================================================
REVOKE ALL ON public.ng_words         FROM anon, authenticated;
REVOKE ALL ON public.moderation_flags FROM anon, authenticated;
REVOKE ALL ON public.moderation_queue FROM anon, authenticated;
GRANT  SELECT, INSERT, UPDATE, DELETE ON public.ng_words, public.moderation_flags TO service_role;
GRANT  SELECT ON public.moderation_queue TO service_role;

REVOKE ALL ON FUNCTION public.admin_suspend_user(UUID, TEXT) FROM public;
REVOKE ALL ON FUNCTION public.admin_unsuspend_user(UUID)     FROM public;
REVOKE ALL ON FUNCTION public.admin_dismiss_user(UUID)       FROM public;
GRANT  EXECUTE ON FUNCTION public.admin_suspend_user(UUID, TEXT) TO service_role;
GRANT  EXECUTE ON FUNCTION public.admin_unsuspend_user(UUID)     TO service_role;
GRANT  EXECUTE ON FUNCTION public.admin_dismiss_user(UUID)       TO service_role;


-- ============================================================
-- 動作確認用クエリ（手動実行）
-- ============================================================
-- SELECT * FROM public.moderation_queue;                 -- 対応すべきリスト
-- SELECT public.admin_suspend_user('<user_id>', '通報多数'); -- 停止
-- SELECT public.admin_unsuspend_user('<user_id>');         -- 解除
-- SELECT public.admin_dismiss_user('<user_id>');           -- 問題なしで除外
-- INSERT INTO public.ng_words(word, severity) VALUES ('新しいNG語', 'warn');
