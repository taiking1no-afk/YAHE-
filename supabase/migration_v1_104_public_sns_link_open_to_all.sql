-- ============================================================
-- Migration v1.104 : 公開SNSリンクをGear R限定から全ユーザー開放 + 表示可否トグル追加
-- Supabase SQL Editor で実行してください。前提: v1.77実行済み。
-- ------------------------------------------------------------
-- 背景:
--   v1.75で「Gear R限定」機能として導入した公開SNSリンクを、開発者の
--   意向により全ユーザーが利用できる機能に戻す。あわせて、これまで
--   「設定していれば常にマッチ相手へ表示」だった挙動に、本人が表示の
--   ON/OFFを選べるトグル(is_visible)を追加する。
--
--   表示範囲（マッチ済みの相手にのみ・本人は常に確認可）自体は
--   v1.77の仕様を維持し、Gear R限定の条件のみ外す。
--
--   何度実行しても安全（冪等）。
-- ============================================================

-- ① 表示可否トグル
ALTER TABLE public.public_sns_links
  ADD COLUMN IF NOT EXISTS is_visible BOOLEAN NOT NULL DEFAULT TRUE;

-- ② SELECTポリシー：Gear R限定の条件を外し、is_visible=trueのみ他者に公開
DROP POLICY IF EXISTS "public_sns_links_select" ON public.public_sns_links;
CREATE POLICY "public_sns_links_select" ON public.public_sns_links FOR SELECT USING (
  -- 本人は常に自分の設定を確認できる（is_visible=falseでも編集画面用に見える）
  user_id IN (SELECT user_id FROM public.users WHERE auth_id = auth.uid())
  OR (
    is_visible = TRUE
    AND NOT EXISTS (
      SELECT 1 FROM public.blocks b
      JOIN public.users me ON me.auth_id = auth.uid()
      WHERE b.blocker_id = me.user_id AND b.blocked_id = public_sns_links.user_id
    )
    -- マッチ済みの相手にのみ公開する（v1.77の仕様を維持）
    AND EXISTS (
      SELECT 1 FROM public.matches m
      JOIN public.users me ON me.auth_id = auth.uid()
      WHERE (m.user_a_id = public_sns_links.user_id AND m.user_b_id = me.user_id)
         OR (m.user_b_id = public_sns_links.user_id AND m.user_a_id = me.user_id)
    )
  )
);

-- ③ set_public_sns_link: Gear R必須チェックを廃止、p_visible引数を追加
CREATE OR REPLACE FUNCTION public.set_public_sns_link(
  p_platform TEXT,
  p_url      TEXT,
  p_label    TEXT DEFAULT NULL,
  p_visible  BOOLEAN DEFAULT TRUE
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_me UUID;
BEGIN
  SELECT user_id INTO v_me FROM public.users WHERE auth_id = auth.uid();
  IF v_me IS NULL THEN
    RAISE EXCEPTION 'unauthorized';
  END IF;

  IF p_url IS NULL OR trim(p_url) = '' THEN
    DELETE FROM public.public_sns_links WHERE user_id = v_me;
    RETURN;
  END IF;

  INSERT INTO public.public_sns_links (user_id, platform, url, label, is_visible, updated_at)
  VALUES (v_me, p_platform, trim(p_url), NULLIF(trim(COALESCE(p_label, '')), ''), COALESCE(p_visible, TRUE), NOW())
  ON CONFLICT (user_id) DO UPDATE
    SET platform = EXCLUDED.platform, url = EXCLUDED.url, label = EXCLUDED.label,
        is_visible = EXCLUDED.is_visible, updated_at = NOW();
END;
$function$;

REVOKE ALL ON FUNCTION public.set_public_sns_link(TEXT, TEXT, TEXT, BOOLEAN) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.set_public_sns_link(TEXT, TEXT, TEXT, BOOLEAN) TO authenticated;

-- 旧シグネチャ（3引数版）が残っていると混乱するため削除する
DROP FUNCTION IF EXISTS public.set_public_sns_link(TEXT, TEXT, TEXT);

-- ============================================================
-- 動作確認用クエリ（手動実行）
-- ============================================================
-- SELECT column_name FROM information_schema.columns WHERE table_name='public_sns_links' AND column_name='is_visible';
-- SELECT qual ILIKE '%gear_r%' AS still_gear_r_gated FROM pg_policies WHERE tablename='public_sns_links' AND policyname='public_sns_links_select';
-- 期待値: false（Gear R限定が外れていること）
-- SELECT pg_get_function_identity_arguments(oid) FROM pg_proc WHERE proname='set_public_sns_link';
