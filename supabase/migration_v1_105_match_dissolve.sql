-- ============================================================
-- Migration v1.105 : マッチ解消（アンマッチ）後もチャット履歴を保持する
-- Supabase SQL Editor で実行してください。前提: v1.97, v1.101実行済み。
-- ------------------------------------------------------------
-- 背景:
--   これまで matches の削除は matches_delete_own ポリシーでハードDELETEを
--   許可しており、chat_threads.match_id が ON DELETE CASCADE のため、
--   マッチを削除すると chat_threads → chat_messages まで連鎖的に消えて
--   いた（チャット履歴が完全に失われる）。ブロック時は履歴を残す設計に
--   なっているのに、アンマッチ時だけ全消去されるのは非対称だった。
--
--   matches をハードDELETEするのではなく dissolved_at を立てるソフト
--   デリート方式に変更し、chat_threads/chat_messagesの行自体は残す
--   （chat_messages_select_participant 等のRLSは matches の存在だけを
--   見ており dissolved_at を見ないため、閲覧権限は変更なしで維持される）。
--
--   解消後は以下を制限する:
--     - 新規メッセージの送信（send_chat_message）
--     - can_view_user() 経由のプロフィール/愛車閲覧（マッチ由来の分岐のみ）
--     - user_sns_links / public_sns_links のマッチ由来の表示
--   一方で維持するもの:
--     - 既存チャット履歴の閲覧（chat_messages_select_participant等は変更なし）
--
--   再度相互いいねが成立した場合は同じmatches行を再度アクティブ化する
--   （dissolved_at を NULL に戻す）。
--
--   何度実行しても安全（冪等）。
-- ============================================================

-- ① 解消日時・解消者を記録するカラム
ALTER TABLE public.matches
  ADD COLUMN IF NOT EXISTS dissolved_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS dissolved_by UUID REFERENCES public.users(user_id) ON DELETE SET NULL;

-- ② クライアントからの直接ハードDELETEを禁止（ソフトデリートRPC経由のみにする）
DROP POLICY IF EXISTS "matches_delete_own" ON public.matches;

-- ③ dissolve_match RPC：本人同士のみ、ソフトデリート
CREATE OR REPLACE FUNCTION public.dissolve_match(p_match_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller UUID;
  v_a UUID;
  v_b UUID;
BEGIN
  SELECT user_id INTO v_caller FROM public.users WHERE auth_id = auth.uid();
  IF v_caller IS NULL THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'unauthorized');
  END IF;

  SELECT user_a_id, user_b_id INTO v_a, v_b FROM public.matches WHERE match_id = p_match_id;
  IF v_a IS NULL THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'not_found');
  END IF;
  IF v_caller <> v_a AND v_caller <> v_b THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'forbidden');
  END IF;

  UPDATE public.matches
  SET dissolved_at = NOW(), dissolved_by = v_caller
  WHERE match_id = p_match_id AND dissolved_at IS NULL;

  RETURN jsonb_build_object('success', TRUE);
END;
$$;

REVOKE ALL ON FUNCTION public.dissolve_match(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.dissolve_match(UUID) TO authenticated;

-- ④ can_view_user(): マッチ由来の可視性は「解消されていないマッチ」のみ有効にする
CREATE OR REPLACE FUNCTION public.can_view_user(p_target_user_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  WITH me AS (
    SELECT user_id FROM public.users WHERE auth_id = auth.uid()
  )
  SELECT
    p_target_user_id IN (SELECT user_id FROM me)
    OR (
      NOT EXISTS (
        SELECT 1 FROM public.blocks b, me
        WHERE b.blocker_id = me.user_id AND b.blocked_id = p_target_user_id
      )
      AND (
        EXISTS (
          SELECT 1 FROM public.encounters e, me
          WHERE (e.user_a_id = p_target_user_id AND e.user_b_id = me.user_id)
             OR (e.user_b_id = p_target_user_id AND e.user_a_id = me.user_id)
        )
        OR EXISTS (
          SELECT 1 FROM public.matches m, me
          WHERE ((m.user_a_id = p_target_user_id AND m.user_b_id = me.user_id)
             OR (m.user_b_id = p_target_user_id AND m.user_a_id = me.user_id))
            AND m.dissolved_at IS NULL
        )
        OR EXISTS (
          SELECT 1 FROM public.likes l, me
          WHERE (l.from_user_id = me.user_id AND l.to_user_id = p_target_user_id)
             OR (l.to_user_id = me.user_id AND l.from_user_id = p_target_user_id)
        )
      )
    );
$function$;

-- ⑤ send_chat_message: 解消済みマッチでは新規メッセージ送信を拒否
CREATE OR REPLACE FUNCTION public.send_chat_message(p_match_id uuid, p_content_type text, p_body text DEFAULT NULL::text, p_photo_path text DEFAULT NULL::text, p_related_post_id uuid DEFAULT NULL::uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_caller_id UUID;
  v_a UUID;
  v_b UUID;
  v_dissolved_at TIMESTAMPTZ;
  v_other_id UUID;
  v_thread_id UUID;
  v_message_id UUID;
  v_word RECORD;
  v_text TEXT;
  v_recent_count INT;
BEGIN
  SELECT user_id INTO v_caller_id FROM public.users WHERE auth_id = auth.uid();
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'unauthorized';
  END IF;

  SELECT count(*) INTO v_recent_count
  FROM public.chat_messages
  WHERE sender_id = v_caller_id AND created_at > now() - interval '1 minute';
  IF v_recent_count >= 60 THEN
    RAISE EXCEPTION 'rate_limited';
  END IF;

  IF p_content_type NOT IN ('text', 'photo', 'sns', 'quick_reply', 'board_invite') THEN
    RAISE EXCEPTION 'invalid content_type';
  END IF;
  IF p_content_type = 'board_invite' AND p_related_post_id IS NULL THEN
    RAISE EXCEPTION 'related_post_id required for board_invite';
  END IF;

  SELECT user_a_id, user_b_id, dissolved_at INTO v_a, v_b, v_dissolved_at
  FROM public.matches WHERE match_id = p_match_id;
  IF v_a IS NULL THEN
    RAISE EXCEPTION 'match not found';
  END IF;
  IF v_caller_id <> v_a AND v_caller_id <> v_b THEN
    RAISE EXCEPTION 'not a participant of this match';
  END IF;
  IF v_dissolved_at IS NOT NULL THEN
    RAISE EXCEPTION 'match_dissolved';
  END IF;
  v_other_id := CASE WHEN v_caller_id = v_a THEN v_b ELSE v_a END;

  IF EXISTS (
    SELECT 1 FROM public.blocks
    WHERE (blocker_id = v_caller_id AND blocked_id = v_other_id)
       OR (blocker_id = v_other_id AND blocked_id = v_caller_id)
  ) THEN
    RAISE EXCEPTION 'blocked';
  END IF;

  IF p_body IS NOT NULL AND p_body <> '' THEN
    v_text := lower(p_body);
    FOR v_word IN SELECT word FROM public.ng_words LOOP
      IF position(lower(v_word.word) IN v_text) > 0 THEN
        RAISE EXCEPTION 'ng_word_detected';
      END IF;
    END LOOP;
  END IF;

  SELECT thread_id INTO v_thread_id FROM public.chat_threads WHERE match_id = p_match_id;
  IF v_thread_id IS NULL THEN
    INSERT INTO public.chat_threads (match_id) VALUES (p_match_id)
    ON CONFLICT (match_id) DO NOTHING
    RETURNING thread_id INTO v_thread_id;

    IF v_thread_id IS NULL THEN
      SELECT thread_id INTO v_thread_id FROM public.chat_threads WHERE match_id = p_match_id;
    END IF;
  END IF;

  INSERT INTO public.chat_messages (thread_id, sender_id, content_type, body, photo_path, related_post_id)
  VALUES (v_thread_id, v_caller_id, p_content_type, p_body, p_photo_path, p_related_post_id)
  RETURNING message_id INTO v_message_id;

  PERFORM public.create_app_notification(
    v_other_id, 'chat_message',
    jsonb_build_object('match_id', p_match_id, 'thread_id', v_thread_id), v_caller_id
  );

  RETURN jsonb_build_object('success', TRUE, 'message_id', v_message_id, 'thread_id', v_thread_id);
END;
$function$;

-- ⑥ send_like: 解消済みマッチは「既にマッチ済み」判定から除外し、
--    再マッチ成立時は同じ行を再アクティブ化する
-- p_boost_type引数を追加するため、旧シグネチャ（3引数）を明示的に削除しないと
-- オーバーロードとして両方残ってしまい、呼び出し側の解決が不定になる。
DROP FUNCTION IF EXISTS public.send_like(uuid, uuid, uuid);

CREATE OR REPLACE FUNCTION public.send_like(
  p_from_user_id UUID,
  p_to_user_id   UUID,
  p_encounter_id UUID,
  p_boost_type   TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_is_matched   BOOLEAN := FALSE;
  v_match_id     UUID;
  v_like_count   INT;
  v_is_premium   BOOLEAN;
  v_is_suspended BOOLEAN;
  v_caller       UUID;
  v_user_a       UUID;
  v_user_b       UUID;
  v_enc_a        UUID;
  v_enc_b        UUID;
  v_rowcount     INT := 0;
  v_recent_count INT;
BEGIN
  SELECT user_id INTO v_caller FROM public.users WHERE auth_id = auth.uid();
  IF v_caller IS NULL OR v_caller <> p_from_user_id THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'forbidden');
  END IF;

  IF p_from_user_id = p_to_user_id THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'invalid_target');
  END IF;

  SELECT count(*) INTO v_recent_count
  FROM public.likes
  WHERE from_user_id = p_from_user_id AND created_at > now() - interval '1 minute';
  IF v_recent_count >= 20 THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'rate_limited');
  END IF;

  SELECT user_a_id, user_b_id
  INTO v_enc_a, v_enc_b
  FROM public.encounters
  WHERE encounter_id = p_encounter_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'encounter_not_found');
  END IF;

  IF NOT (
    (v_enc_a = p_from_user_id AND v_enc_b = p_to_user_id) OR
    (v_enc_b = p_from_user_id AND v_enc_a = p_to_user_id)
  ) THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'not_encounter_party');
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.blocks b
    WHERE (b.blocker_id = p_from_user_id AND b.blocked_id = p_to_user_id)
       OR (b.blocker_id = p_to_user_id AND b.blocked_id = p_from_user_id)
  ) THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'blocked');
  END IF;

  v_is_premium := public.user_is_premium(p_from_user_id);

  SELECT is_suspended INTO v_is_suspended
  FROM public.users WHERE user_id = p_from_user_id;

  IF COALESCE(v_is_suspended, FALSE) THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'suspended');
  END IF;

  SELECT like_count INTO v_like_count
  FROM public.today_like_counts
  WHERE from_user_id = p_from_user_id;

  IF NOT v_is_premium AND COALESCE(v_like_count, 0) >= 10 THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'daily_limit_exceeded');
  END IF;

  INSERT INTO public.likes (from_user_id, to_user_id, encounter_id, boost_type)
  VALUES (p_from_user_id, p_to_user_id, p_encounter_id, p_boost_type)
  ON CONFLICT (from_user_id, to_user_id) DO UPDATE
    SET encounter_id = EXCLUDED.encounter_id,
        boost_type = COALESCE(EXCLUDED.boost_type, public.likes.boost_type),
        created_at = NOW()
    WHERE public.likes.encounter_id IS DISTINCT FROM EXCLUDED.encounter_id;

  GET DIAGNOSTICS v_rowcount = ROW_COUNT;

  IF EXISTS (
    SELECT 1 FROM public.likes
    WHERE from_user_id = p_to_user_id
      AND to_user_id = p_from_user_id
  ) OR EXISTS (
    SELECT 1 FROM public.matches
    WHERE user_a_id = LEAST(p_from_user_id, p_to_user_id)
      AND user_b_id = GREATEST(p_from_user_id, p_to_user_id)
      AND dissolved_at IS NULL
  ) THEN
    v_user_a := LEAST(p_from_user_id, p_to_user_id);
    v_user_b := GREATEST(p_from_user_id, p_to_user_id);

    INSERT INTO public.matches (user_a_id, user_b_id)
    VALUES (v_user_a, v_user_b)
    ON CONFLICT (user_a_id, user_b_id) DO UPDATE
      SET dissolved_at = NULL, dissolved_by = NULL
    RETURNING match_id INTO v_match_id;

    v_is_matched := TRUE;
  END IF;

  IF v_rowcount > 0 AND NOT v_is_matched THEN
    PERFORM public.create_app_notification(
      p_to_user_id, 'like_received',
      jsonb_build_object('from_user_id', p_from_user_id, 'boost_type', p_boost_type), p_from_user_id
    );
  END IF;

  RETURN jsonb_build_object(
    'success',    TRUE,
    'is_matched', v_is_matched,
    'match_id',   v_match_id,
    'already_liked', (v_rowcount = 0)
  );
END;
$$;

-- ⑦ send_like_no_encounter: 同様の修正（旧2引数シグネチャを明示的に削除）
DROP FUNCTION IF EXISTS public.send_like_no_encounter(uuid, uuid);

CREATE OR REPLACE FUNCTION public.send_like_no_encounter(
  p_from_user_id UUID,
  p_to_user_id   UUID,
  p_boost_type   TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_is_matched   BOOLEAN := FALSE;
  v_match_id     UUID;
  v_like_count   INT;
  v_is_premium   BOOLEAN;
  v_is_suspended BOOLEAN;
  v_caller       UUID;
  v_user_a       UUID;
  v_user_b       UUID;
  v_rowcount     INT := 0;
BEGIN
  SELECT user_id INTO v_caller FROM public.users WHERE auth_id = auth.uid();
  IF v_caller IS NULL OR v_caller <> p_from_user_id THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'forbidden');
  END IF;

  IF p_from_user_id = p_to_user_id THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'invalid_target');
  END IF;

  IF NOT public.can_view_user(p_to_user_id) THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'not_related');
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.blocks b
    WHERE (b.blocker_id = p_from_user_id AND b.blocked_id = p_to_user_id)
       OR (b.blocker_id = p_to_user_id AND b.blocked_id = p_from_user_id)
  ) THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'blocked');
  END IF;

  v_is_premium := public.user_is_premium(p_from_user_id);

  SELECT is_suspended INTO v_is_suspended
  FROM public.users WHERE user_id = p_from_user_id;

  IF COALESCE(v_is_suspended, FALSE) THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'suspended');
  END IF;

  SELECT like_count INTO v_like_count
  FROM public.today_like_counts
  WHERE from_user_id = p_from_user_id;

  IF NOT v_is_premium AND COALESCE(v_like_count, 0) >= 10 THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'daily_limit_exceeded');
  END IF;

  INSERT INTO public.likes (from_user_id, to_user_id, encounter_id, boost_type)
  VALUES (p_from_user_id, p_to_user_id, NULL, p_boost_type)
  ON CONFLICT (from_user_id, to_user_id) DO UPDATE
    SET boost_type = COALESCE(EXCLUDED.boost_type, public.likes.boost_type)
    WHERE public.likes.boost_type IS DISTINCT FROM EXCLUDED.boost_type;

  GET DIAGNOSTICS v_rowcount = ROW_COUNT;

  IF EXISTS (
    SELECT 1 FROM public.likes
    WHERE from_user_id = p_to_user_id
      AND to_user_id = p_from_user_id
  ) OR EXISTS (
    SELECT 1 FROM public.matches
    WHERE user_a_id = LEAST(p_from_user_id, p_to_user_id)
      AND user_b_id = GREATEST(p_from_user_id, p_to_user_id)
      AND dissolved_at IS NULL
  ) THEN
    v_user_a := LEAST(p_from_user_id, p_to_user_id);
    v_user_b := GREATEST(p_from_user_id, p_to_user_id);

    INSERT INTO public.matches (user_a_id, user_b_id)
    VALUES (v_user_a, v_user_b)
    ON CONFLICT (user_a_id, user_b_id) DO UPDATE
      SET dissolved_at = NULL, dissolved_by = NULL
    RETURNING match_id INTO v_match_id;

    v_is_matched := TRUE;
  END IF;

  IF v_rowcount > 0 AND NOT v_is_matched THEN
    PERFORM public.create_app_notification(
      p_to_user_id, 'like_received',
      jsonb_build_object('from_user_id', p_from_user_id, 'boost_type', p_boost_type), p_from_user_id
    );
  END IF;

  RETURN jsonb_build_object(
    'success',    TRUE,
    'is_matched', v_is_matched,
    'match_id',   v_match_id,
    'already_liked', (v_rowcount = 0)
  );
END;
$$;

-- ⑧ send_boosted_like / send_boosted_like_no_encounter:
--    boost_type を send_like 系に直接渡す形に簡略化（別UPDATEを廃止）
CREATE OR REPLACE FUNCTION public.send_boosted_like(
  p_from_user_id uuid,
  p_to_user_id uuid,
  p_encounter_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_caller_id UUID;
  v_item_type TEXT;
  v_qty        INT;
  v_result     JSONB;
BEGIN
  SELECT user_id INTO v_caller_id FROM public.users WHERE auth_id = auth.uid();
  IF v_caller_id IS NULL OR v_caller_id <> p_from_user_id THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'forbidden');
  END IF;

  SELECT quantity INTO v_qty FROM public.user_items
    WHERE user_id = v_caller_id AND item_type = 'geki_shibu' FOR UPDATE;
  IF COALESCE(v_qty, 0) > 0 THEN
    v_item_type := 'geki_shibu';
  ELSE
    SELECT quantity INTO v_qty FROM public.user_items
      WHERE user_id = v_caller_id AND item_type = 'shibu' FOR UPDATE;
    IF COALESCE(v_qty, 0) > 0 THEN
      v_item_type := 'shibu';
    ELSE
      RETURN jsonb_build_object('success', FALSE, 'error', 'no_boost_item');
    END IF;
  END IF;

  v_result := public.send_like(p_from_user_id, p_to_user_id, p_encounter_id, v_item_type);
  IF COALESCE((v_result->>'success')::boolean, FALSE) THEN
    UPDATE public.user_items
      SET quantity = quantity - 1
      WHERE user_id = v_caller_id AND item_type = v_item_type;
  END IF;

  RETURN v_result || jsonb_build_object('boost_type', v_item_type);
END;
$function$;

CREATE OR REPLACE FUNCTION public.send_boosted_like_no_encounter(
  p_from_user_id uuid,
  p_to_user_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_caller_id UUID;
  v_item_type TEXT;
  v_qty        INT;
  v_result     JSONB;
BEGIN
  SELECT user_id INTO v_caller_id FROM public.users WHERE auth_id = auth.uid();
  IF v_caller_id IS NULL OR v_caller_id <> p_from_user_id THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'forbidden');
  END IF;

  SELECT quantity INTO v_qty FROM public.user_items
    WHERE user_id = v_caller_id AND item_type = 'geki_shibu' FOR UPDATE;
  IF COALESCE(v_qty, 0) > 0 THEN
    v_item_type := 'geki_shibu';
  ELSE
    SELECT quantity INTO v_qty FROM public.user_items
      WHERE user_id = v_caller_id AND item_type = 'shibu' FOR UPDATE;
    IF COALESCE(v_qty, 0) > 0 THEN
      v_item_type := 'shibu';
    ELSE
      RETURN jsonb_build_object('success', FALSE, 'error', 'no_boost_item');
    END IF;
  END IF;

  v_result := public.send_like_no_encounter(p_from_user_id, p_to_user_id, v_item_type);
  IF COALESCE((v_result->>'success')::boolean, FALSE) THEN
    UPDATE public.user_items
      SET quantity = quantity - 1
      WHERE user_id = v_caller_id AND item_type = v_item_type;
  END IF;

  RETURN v_result || jsonb_build_object('boost_type', v_item_type);
END;
$function$;

-- ⑨ user_sns_links / public_sns_links: マッチ由来の表示は解消済みマッチを除外
DROP POLICY IF EXISTS "user_sns_select_matched_visible" ON public.user_sns_links;
CREATE POLICY "user_sns_select_matched_visible" ON public.user_sns_links
  FOR SELECT
  USING (
    visible_to_matches = true
    AND NOT EXISTS (
      SELECT 1 FROM public.blocks b
      JOIN public.users me ON me.auth_id = auth.uid()
      WHERE (b.blocker_id = me.user_id AND b.blocked_id = user_sns_links.user_id)
         OR (b.blocker_id = user_sns_links.user_id AND b.blocked_id = me.user_id)
    )
    AND EXISTS (
      SELECT 1 FROM public.matches m
      JOIN public.users me ON me.auth_id = auth.uid()
      WHERE ((m.user_a_id = user_sns_links.user_id AND m.user_b_id = me.user_id)
         OR (m.user_b_id = user_sns_links.user_id AND m.user_a_id = me.user_id))
        AND m.dissolved_at IS NULL
    )
  );

DROP POLICY IF EXISTS "public_sns_links_select" ON public.public_sns_links;
CREATE POLICY "public_sns_links_select" ON public.public_sns_links FOR SELECT USING (
  user_id IN (SELECT user_id FROM public.users WHERE auth_id = auth.uid())
  OR (
    is_visible = TRUE
    AND NOT EXISTS (
      SELECT 1 FROM public.blocks b
      JOIN public.users me ON me.auth_id = auth.uid()
      WHERE b.blocker_id = me.user_id AND b.blocked_id = public_sns_links.user_id
    )
    AND EXISTS (
      SELECT 1 FROM public.matches m
      JOIN public.users me ON me.auth_id = auth.uid()
      WHERE ((m.user_a_id = public_sns_links.user_id AND m.user_b_id = me.user_id)
         OR (m.user_b_id = public_sns_links.user_id AND m.user_a_id = me.user_id))
        AND m.dissolved_at IS NULL
    )
  )
);

-- ============================================================
-- 動作確認用クエリ（手動実行）
-- ============================================================
-- SELECT column_name FROM information_schema.columns WHERE table_name='matches' AND column_name IN ('dissolved_at','dissolved_by');
-- SELECT count(*) FROM pg_policies WHERE tablename='matches' AND policyname='matches_delete_own'; -- 期待値: 0
-- SELECT proname FROM pg_proc WHERE proname = 'dissolve_match';
-- SELECT prosrc ILIKE '%dissolved_at%' FROM pg_proc WHERE proname = 'can_view_user';
-- SELECT prosrc ILIKE '%match_dissolved%' FROM pg_proc WHERE proname = 'send_chat_message';
