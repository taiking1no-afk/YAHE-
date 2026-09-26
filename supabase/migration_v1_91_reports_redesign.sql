-- ============================================================
-- Migration v1.91 : 通報の粒度化（メッセージ/投稿単位）・理由の細分化・
--                    即時自動停止の廃止
-- Supabase SQL Editor で実行してください。
-- ------------------------------------------------------------
-- 背景:
--   これまで public.reports は target_id（ユーザー）にしか紐づけられず、
--   DM/グループチャットの特定メッセージ・掲示板投稿・写真を個別に通報する
--   手段がなかった。また通報理由も4種類しかなく、開発者が求める10種類の
--   細分化に対応していなかった。
--
--   さらに、異なる通報者3人に達すると自動的に is_suspended = TRUE になる
--   trg_auto_suspend_on_reports が稼働しており、共謀した虚偽通報でも
--   即座にアカウントが停止されてしまう構造だった。運営確認を経てからの
--   BANに変更するため、このトリガーを廃止する（NGワード検知による
--   自動停止 scan_profile_ng_words は対象外・維持する）。
--
--   何度実行しても安全（冪等）。
-- ============================================================

-- ============================================================
-- ① reports テーブルの拡張：どの種類の対象への通報かを記録する
-- ============================================================
ALTER TABLE public.reports
  ADD COLUMN IF NOT EXISTS target_type TEXT NOT NULL DEFAULT 'user',
  ADD COLUMN IF NOT EXISTS chat_message_id  UUID REFERENCES public.chat_messages(message_id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS group_message_id UUID REFERENCES public.group_messages(message_id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS board_post_id    UUID REFERENCES public.board_posts(post_id) ON DELETE SET NULL;

ALTER TABLE public.reports DROP CONSTRAINT IF EXISTS reports_target_type_check;
ALTER TABLE public.reports ADD CONSTRAINT reports_target_type_check
  CHECK (target_type IN ('user', 'profile', 'chat_message', 'group_message', 'board_post', 'photo'));

-- 通報理由を4種類→10種類に拡張（開発者指定の内訳）
ALTER TABLE public.reports DROP CONSTRAINT IF EXISTS reports_category_check;
ALTER TABLE public.reports ADD CONSTRAINT reports_category_check
  CHECK (category IN (
    'harassment',                    -- 迷惑行為
    'spam',                          -- スパム
    'fraud',                         -- 詐欺
    'threat',                        -- 脅迫
    'stalking',                      -- ストーカー
    'sexual_harassment',             -- 性的嫌がらせ
    'doxxing',                       -- 個人情報の公開
    'impersonation',                 -- なりすまし
    'dangerous_driving_solicitation',-- 危険運転の勧誘
    'inappropriate_photo',           -- 不適切な写真（既存カテゴリ、写真通報でも使用）
    'other'                          -- その他
  ));

-- 同一対象への重複通報を防止（未解決の通報のみ対象。解決済みなら再通報可）
DROP INDEX IF EXISTS reports_no_duplicate_pending;
CREATE UNIQUE INDEX reports_no_duplicate_pending ON public.reports (
  reporter_id,
  target_type,
  target_id,
  COALESCE(chat_message_id, group_message_id, board_post_id, '00000000-0000-0000-0000-000000000000'::uuid)
) WHERE status = 'pending';

-- ============================================================
-- ①b users.birth_date のサーバー側年齢検証
-- ------------------------------------------------------------
-- age_consent_screen.dart は16歳未満をクライアント側で弾いているが、
-- auth_repository.dart の saveAgeAndConsent は users テーブルへの直接
-- UPDATE（RPC非経由）のため、クライアントを介さず直接RPC/REST呼び出し
-- すれば回避できてしまう。CHECK制約でサーバー側にも同じ下限を課す。
-- 年齢ポリシー自体（16歳以上）は変更しない。既存行の birth_date が
-- NULL の場合は許容する（未確認ユーザーの後方互換）。
-- ============================================================
ALTER TABLE public.users DROP CONSTRAINT IF EXISTS users_birth_date_min_age;
ALTER TABLE public.users ADD CONSTRAINT users_birth_date_min_age
  CHECK (birth_date IS NULL OR birth_date <= (CURRENT_DATE - INTERVAL '16 years'));

-- ============================================================
-- ② 通報3件での自動停止トリガーを廃止（運営確認の上でのBANに変更）
-- ------------------------------------------------------------
-- auto_suspend_on_reports() 関数自体は削除せず残す（将来の参考・切り戻し用）が、
-- トリガーを外すことで通報による自動停止は発生しなくなる。
-- moderation_queue ビュー（v1.13）は変更不要：通報は引き続き人間のレビュー
-- キューに集計される。
-- ============================================================
DROP TRIGGER IF EXISTS trg_auto_suspend_on_reports ON public.reports;

-- ============================================================
-- ③ submit_report RPC：reports への唯一の書き込み経路
-- ------------------------------------------------------------
-- 既存は user_repository.dart から reports へ直接 INSERT していた
-- （このテーブルだけ他と違いRPCを経由していなかった）。RPC化することで:
--   - reporter_id をクライアント指定ではなく auth.uid() から解決（なりすまし防止）
--   - メッセージ/投稿通報時に「対象へのアクセス権限があるか」を検証
--   - 重複通報を友好的なエラーとして返す
-- ============================================================
CREATE OR REPLACE FUNCTION public.submit_report(
  p_target_type       TEXT,
  p_category          TEXT,
  p_detail            TEXT DEFAULT NULL,
  p_target_id         UUID DEFAULT NULL,
  p_chat_message_id   UUID DEFAULT NULL,
  p_group_message_id  UUID DEFAULT NULL,
  p_board_post_id     UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_id      UUID;
  v_resolved_target UUID;
  v_msg_sender     UUID;
  v_thread_id      UUID;
  v_group_id       UUID;
  v_report_id      UUID;
BEGIN
  SELECT user_id INTO v_caller_id FROM public.users WHERE auth_id = auth.uid();
  IF v_caller_id IS NULL THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'unauthorized');
  END IF;

  IF p_target_type NOT IN ('user', 'profile', 'chat_message', 'group_message', 'board_post', 'photo') THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'invalid_target_type');
  END IF;

  IF p_category NOT IN (
    'harassment', 'spam', 'fraud', 'threat', 'stalking', 'sexual_harassment',
    'doxxing', 'impersonation', 'dangerous_driving_solicitation',
    'inappropriate_photo', 'other'
  ) THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'invalid_category');
  END IF;

  IF p_target_type = 'chat_message' THEN
    IF p_chat_message_id IS NULL THEN
      RETURN jsonb_build_object('success', FALSE, 'error', 'chat_message_id_required');
    END IF;

    SELECT cm.sender_id, cm.thread_id INTO v_msg_sender, v_thread_id
    FROM public.chat_messages cm
    WHERE cm.message_id = p_chat_message_id;

    IF v_msg_sender IS NULL THEN
      RETURN jsonb_build_object('success', FALSE, 'error', 'message_not_found');
    END IF;

    IF NOT EXISTS (
      SELECT 1 FROM public.chat_threads ct
      JOIN public.matches m ON m.match_id = ct.match_id
      WHERE ct.thread_id = v_thread_id
        AND (m.user_a_id = v_caller_id OR m.user_b_id = v_caller_id)
    ) THEN
      RETURN jsonb_build_object('success', FALSE, 'error', 'forbidden');
    END IF;

    v_resolved_target := v_msg_sender;

  ELSIF p_target_type = 'group_message' THEN
    IF p_group_message_id IS NULL THEN
      RETURN jsonb_build_object('success', FALSE, 'error', 'group_message_id_required');
    END IF;

    SELECT gm.sender_id, gm.group_id INTO v_msg_sender, v_group_id
    FROM public.group_messages gm
    WHERE gm.message_id = p_group_message_id;

    IF v_msg_sender IS NULL THEN
      RETURN jsonb_build_object('success', FALSE, 'error', 'message_not_found');
    END IF;

    IF NOT EXISTS (
      SELECT 1 FROM public.group_memberships
      WHERE group_id = v_group_id AND user_id = v_caller_id AND status = 'member'
    ) THEN
      RETURN jsonb_build_object('success', FALSE, 'error', 'forbidden');
    END IF;

    v_resolved_target := v_msg_sender;

  ELSIF p_target_type = 'board_post' THEN
    IF p_board_post_id IS NULL THEN
      RETURN jsonb_build_object('success', FALSE, 'error', 'board_post_id_required');
    END IF;

    SELECT bp.organizer_id INTO v_resolved_target
    FROM public.board_posts bp
    WHERE bp.post_id = p_board_post_id;

    IF v_resolved_target IS NULL THEN
      RETURN jsonb_build_object('success', FALSE, 'error', 'post_not_found');
    END IF;

  ELSE
    -- user / profile / photo：target_id 必須
    IF p_target_id IS NULL THEN
      RETURN jsonb_build_object('success', FALSE, 'error', 'target_id_required');
    END IF;

    IF NOT EXISTS (SELECT 1 FROM public.users WHERE user_id = p_target_id) THEN
      RETURN jsonb_build_object('success', FALSE, 'error', 'target_not_found');
    END IF;

    v_resolved_target := p_target_id;
  END IF;

  IF v_resolved_target = v_caller_id THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'invalid_target');
  END IF;

  BEGIN
    INSERT INTO public.reports (
      reporter_id, target_id, target_type, category, detail,
      chat_message_id, group_message_id, board_post_id
    )
    VALUES (
      v_caller_id, v_resolved_target, p_target_type, p_category, NULLIF(trim(coalesce(p_detail, '')), ''),
      p_chat_message_id, p_group_message_id, p_board_post_id
    )
    RETURNING report_id INTO v_report_id;
  EXCEPTION WHEN unique_violation THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'already_reported');
  END;

  RETURN jsonb_build_object('success', TRUE, 'report_id', v_report_id);
END;
$$;

REVOKE ALL ON FUNCTION public.submit_report(TEXT, TEXT, TEXT, UUID, UUID, UUID, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.submit_report(TEXT, TEXT, TEXT, UUID, UUID, UUID, UUID) TO authenticated;

-- クライアントからの reports への直接書き込みは禁止し、submit_report 経由のみにする
REVOKE INSERT ON public.reports FROM authenticated, anon;

-- ============================================================
-- 動作確認用クエリ（手動実行）
-- ============================================================
-- SELECT count(*) FROM pg_trigger WHERE tgname = 'trg_auto_suspend_on_reports'; -- 0件になっていること
-- SELECT conname FROM pg_constraint WHERE conrelid = 'public.reports'::regclass AND conname = 'reports_category_check';
-- SELECT indexname FROM pg_indexes WHERE tablename = 'reports' AND indexname = 'reports_no_duplicate_pending';
