-- ============================================================
-- Migration v1.96 : データ保持期間の自動化・管理者操作の監査ログ・
--                    DM閲覧の最小化
-- Supabase SQL Editor で実行してください。前提: v1.13, v1.91実行済み。
-- ------------------------------------------------------------
-- 背景:
--   1) 通報・FCMトークンの保持期間ポリシーを自動cronで実施する
--      （現在位置・DM・退会時削除は既存実装で既に要件を満たしているため
--        ここでは対象外。通報の保持は「1年、ただし未解決(pending)は除く」）。
--   2) admin_suspend_user等の運営RPCは誰が実行したか一切記録が残らない。
--      呼び出し側が識別子を渡し、admin_audit_logに記録する形に変更する。
--      ※ service_roleには元々auth.uid()が無く、真の認証済み実行者を
--        自動識別することはできない。p_admin_identifierは手動入力の
--        自己申告であり、技術的な強制力はない（運用ルールとして機能する）。
--   3) 通報対象メッセージのみを閲覧できる専用RPCを新設し、これを
--      「DM内容を見る唯一の正規ルート」として運用する。
--      ※ service_role（Supabase Studio等）自体はPostgresの構造上RLSを
--        バイパスできるため、これは技術的な強制ではなく運用手順の話である。
--
--   何度実行しても安全（冪等）。
-- ============================================================

-- ① 管理者操作の監査ログ
CREATE TABLE IF NOT EXISTS public.admin_audit_log (
  audit_id         UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  admin_identifier TEXT NOT NULL,
  action           TEXT NOT NULL,
  target_user_id   UUID,
  target_report_id UUID,
  detail           JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE public.admin_audit_log ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.admin_audit_log FROM anon, authenticated;
GRANT SELECT, INSERT ON public.admin_audit_log TO service_role;

-- ② 既存の運営RPCに p_admin_identifier を追加し、実行のたびに監査ログへ記録する
DROP FUNCTION IF EXISTS public.admin_suspend_user(UUID, TEXT);
CREATE OR REPLACE FUNCTION public.admin_suspend_user(
  p_user_id UUID,
  p_reason TEXT DEFAULT NULL,
  p_admin_identifier TEXT DEFAULT 'unknown'
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE public.users SET is_suspended = TRUE WHERE user_id = p_user_id;
  UPDATE public.moderation_flags SET status = 'resolved' WHERE user_id = p_user_id AND status = 'open';
  UPDATE public.reports SET status = 'resolved' WHERE target_id = p_user_id AND status = 'pending';

  INSERT INTO public.admin_audit_log (admin_identifier, action, target_user_id, detail)
  VALUES (p_admin_identifier, 'suspend_user', p_user_id, jsonb_build_object('reason', p_reason));
END;
$$;

DROP FUNCTION IF EXISTS public.admin_unsuspend_user(UUID);
CREATE OR REPLACE FUNCTION public.admin_unsuspend_user(
  p_user_id UUID,
  p_admin_identifier TEXT DEFAULT 'unknown'
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE public.users SET is_suspended = FALSE WHERE user_id = p_user_id;
  UPDATE public.moderation_flags SET status = 'ignored' WHERE user_id = p_user_id AND status = 'open';
  UPDATE public.reports SET status = 'reviewed' WHERE target_id = p_user_id AND status = 'pending';

  INSERT INTO public.admin_audit_log (admin_identifier, action, target_user_id)
  VALUES (p_admin_identifier, 'unsuspend_user', p_user_id);
END;
$$;

DROP FUNCTION IF EXISTS public.admin_dismiss_user(UUID);
CREATE OR REPLACE FUNCTION public.admin_dismiss_user(
  p_user_id UUID,
  p_admin_identifier TEXT DEFAULT 'unknown'
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE public.moderation_flags SET status = 'ignored' WHERE user_id = p_user_id AND status = 'open';
  UPDATE public.reports SET status = 'reviewed' WHERE target_id = p_user_id AND status = 'pending';

  INSERT INTO public.admin_audit_log (admin_identifier, action, target_user_id)
  VALUES (p_admin_identifier, 'dismiss_user', p_user_id);
END;
$$;

REVOKE ALL ON FUNCTION public.admin_suspend_user(UUID, TEXT, TEXT)   FROM public;
REVOKE ALL ON FUNCTION public.admin_unsuspend_user(UUID, TEXT)       FROM public;
REVOKE ALL ON FUNCTION public.admin_dismiss_user(UUID, TEXT)         FROM public;
GRANT  EXECUTE ON FUNCTION public.admin_suspend_user(UUID, TEXT, TEXT) TO service_role;
GRANT  EXECUTE ON FUNCTION public.admin_unsuspend_user(UUID, TEXT)     TO service_role;
GRANT  EXECUTE ON FUNCTION public.admin_dismiss_user(UUID, TEXT)       TO service_role;

-- ③ 通報対象メッセージのみを閲覧する専用RPC（DM本文への「正規の」アクセス経路）
CREATE OR REPLACE FUNCTION public.get_reported_message_content(
  p_report_id UUID,
  p_admin_identifier TEXT DEFAULT 'unknown'
)
RETURNS TABLE (
  target_type TEXT,
  sender_id UUID,
  body TEXT,
  photo_path TEXT,
  created_at TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_report public.reports;
BEGIN
  SELECT * INTO v_report FROM public.reports WHERE report_id = p_report_id;
  IF v_report IS NULL THEN
    RETURN;
  END IF;

  INSERT INTO public.admin_audit_log (admin_identifier, action, target_report_id, detail)
  VALUES (p_admin_identifier, 'view_reported_message', p_report_id,
          jsonb_build_object('target_type', v_report.target_type));

  IF v_report.chat_message_id IS NOT NULL THEN
    RETURN QUERY
      SELECT 'chat_message'::TEXT, cm.sender_id, cm.body, cm.photo_path, cm.created_at
      FROM public.chat_messages cm WHERE cm.message_id = v_report.chat_message_id;
  ELSIF v_report.group_message_id IS NOT NULL THEN
    RETURN QUERY
      SELECT 'group_message'::TEXT, gm.sender_id, gm.body, gm.photo_path, gm.created_at
      FROM public.group_messages gm WHERE gm.message_id = v_report.group_message_id;
  END IF;
  -- target_type='chat_message'/'group_message'以外（user/profile/board_post/photo）は
  -- このRPCの対象外（そもそもDM本文ではないため）。
END;
$$;

REVOKE ALL ON FUNCTION public.get_reported_message_content(UUID, TEXT) FROM public;
GRANT EXECUTE ON FUNCTION public.get_reported_message_content(UUID, TEXT) TO service_role;

-- ④ データ保持期間のcronジョブ
DO $retention_cron$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'pg_cron') THEN
    CREATE EXTENSION IF NOT EXISTS pg_cron;

    -- 通報：1年経過かつ解決済み(pending以外)のみ削除。未解決の通報は保持し続ける。
    IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'delete-old-reports') THEN
      PERFORM cron.unschedule('delete-old-reports');
    END IF;
    PERFORM cron.schedule(
      'delete-old-reports',
      '0 3 * * *',
      $job$DELETE FROM public.reports WHERE created_at < now() - interval '1 year' AND status <> 'pending'$job$
    );

    -- FCMトークン：180日以上更新が無いものをバックストップとして削除
    -- （ログアウト時の即時削除は別途アプリ側で行う想定。これは取りこぼし対策）
    IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'delete-stale-fcm-tokens') THEN
      PERFORM cron.unschedule('delete-stale-fcm-tokens');
    END IF;
    PERFORM cron.schedule(
      'delete-stale-fcm-tokens',
      '0 4 * * *',
      $job$DELETE FROM public.user_push_tokens WHERE updated_at < now() - interval '180 days'$job$
    );
  END IF;
END $retention_cron$;

-- ============================================================
-- 動作確認用クエリ（手動実行）
-- ============================================================
-- SELECT jobname FROM cron.job WHERE jobname IN ('delete-old-reports', 'delete-stale-fcm-tokens');
-- SELECT public.admin_dismiss_user('<user_id>', 'test-run'); SELECT * FROM public.admin_audit_log ORDER BY created_at DESC LIMIT 1;
