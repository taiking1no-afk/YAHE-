-- ============================================================
-- Migration v1.76 : 公開SNSリンクのクリックも計測対象にする
-- Supabase SQL Editor で実行してください。前提: v1.75 実行済み。
-- ------------------------------------------------------------
-- record_sns_link_click() は「マッチ済み」または「鍵なし+いいね済み」の
-- 場合のみ開示済みとみなしクリックを記録していたが、v1.75で追加した
-- Gear R限定の公開SNSリンク（誰からでも常時閲覧可能）はこの条件に
-- 当てはまらないため、そのままではクリックが一切記録されなかった。
-- 「オーナーが公開SNSリンクを設定している」場合も開示済み扱いに加える。
--
--   何度実行しても安全（冪等）。
-- ============================================================

CREATE OR REPLACE FUNCTION public.record_sns_link_click(p_owner_user_id uuid, p_platform text DEFAULT NULL::text, p_url text DEFAULT NULL::text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_clicker UUID;
  v_host    TEXT;
  v_allowed BOOLEAN := FALSE;
BEGIN
  SELECT user_id INTO v_clicker FROM public.users WHERE auth_id = auth.uid();
  IF v_clicker IS NULL OR v_clicker = p_owner_user_id THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'forbidden');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.users WHERE user_id = p_owner_user_id) THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'owner_not_found');
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.blocks b
    WHERE (b.blocker_id = v_clicker AND b.blocked_id = p_owner_user_id)
       OR (b.blocker_id = p_owner_user_id AND b.blocked_id = v_clicker)
  ) THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'blocked');
  END IF;

  -- マッチ済みなら開示済み
  IF EXISTS (
    SELECT 1 FROM public.matches m
    WHERE (m.user_a_id = LEAST(v_clicker, p_owner_user_id)
       AND m.user_b_id = GREATEST(v_clicker, p_owner_user_id))
  ) THEN
    v_allowed := TRUE;
  END IF;

  -- 鍵なしオーナーへ、閲覧者がいいね済みなら開示済み
  IF NOT v_allowed AND EXISTS (
    SELECT 1
    FROM public.users owner
    JOIN public.likes l
      ON l.from_user_id = v_clicker
     AND l.to_user_id = p_owner_user_id
    WHERE owner.user_id = p_owner_user_id
      AND COALESCE(owner.is_private, TRUE) = FALSE
  ) THEN
    v_allowed := TRUE;
  END IF;

  -- Gear R限定の公開SNSリンクは常時開示済み扱い
  IF NOT v_allowed AND EXISTS (
    SELECT 1 FROM public.public_sns_links WHERE user_id = p_owner_user_id
  ) THEN
    v_allowed := TRUE;
  END IF;

  IF NOT v_allowed THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'not_disclosed');
  END IF;

  v_host := NULL;
  IF p_url IS NOT NULL AND btrim(p_url) <> '' THEN
    BEGIN
      v_host := lower(substring(p_url from '://([^/]+)'));
      IF v_host IS NULL THEN
        v_host := lower(substring(p_url from '^([^/]+)'));
      END IF;
      IF v_host LIKE 'www.%' THEN
        v_host := substring(v_host from 5);
      END IF;
    EXCEPTION WHEN OTHERS THEN
      v_host := NULL;
    END;
  END IF;

  INSERT INTO public.sns_link_clicks (owner_user_id, clicker_user_id, platform, url_host)
  VALUES (
    p_owner_user_id,
    v_clicker,
    NULLIF(btrim(COALESCE(p_platform, '')), ''),
    v_host
  );

  RETURN jsonb_build_object('success', TRUE);
END;
$function$;


-- ============================================================
-- 動作確認用クエリ（手動実行）
-- ============================================================
-- SELECT prosrc ILIKE '%public_sns_links%' AS covers_public_link FROM pg_proc WHERE proname = 'record_sns_link_click';
