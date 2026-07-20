-- ============================================================
-- Migration v1.10 : ブロック挙動 & 鍵アカウント（公開/非公開）
-- 前提: v1.8 / v1.9 実行済み
-- 内容:
--   1) block_user RPC … ブロック登録 + 純粋なすれ違い(いいね無しencounter)の削除
--      （いいね・マッチは残すのでブロック解除で再表示される）
--   2) users.is_private … 鍵アカウント設定（true=鍵あり/既定, false=鍵なし）
--   3) user_sns_links の SELECT ポリシー更新
--      - 本人 / マッチ済み は従来どおり開示
--      - 鍵なし(is_private=false)のユーザーは「いいねしてくれた相手」に即開示
-- ※ 何度実行しても安全な冪等スクリプト
-- ============================================================

-- ------------------------------------------------------------
-- 1) is_private カラム（既定 true = 従来の鍵あり挙動）
-- ------------------------------------------------------------
ALTER TABLE public.users
  ADD COLUMN IF NOT EXISTS is_private BOOLEAN NOT NULL DEFAULT TRUE;

-- ------------------------------------------------------------
-- 2) block_user RPC
--    ブロックを登録し、その相手との「いいねが付いていないすれ違い」を削除。
--    いいね付きの encounter は残す（likes が FK CASCADE で消えないように）。
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.block_user(p_blocked_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_me uuid;
BEGIN
  SELECT user_id INTO v_me FROM public.users WHERE auth_id = auth.uid();
  IF v_me IS NULL OR v_me = p_blocked_id THEN
    RETURN;
  END IF;

  INSERT INTO public.blocks (blocker_id, blocked_id)
  VALUES (v_me, p_blocked_id)
  ON CONFLICT (blocker_id, blocked_id) DO NOTHING;

  -- 純粋なすれ違い（いいねが1件も付いていない encounter）のみ削除。
  -- → ブロック解除しても再遭遇するまで表示されない。
  DELETE FROM public.encounters e
  WHERE (
          (e.user_a_id = v_me AND e.user_b_id = p_blocked_id)
       OR (e.user_a_id = p_blocked_id AND e.user_b_id = v_me)
        )
    AND NOT EXISTS (
      SELECT 1 FROM public.likes l WHERE l.encounter_id = e.encounter_id
    );
END;
$$;

REVOKE ALL  ON FUNCTION public.block_user(uuid) FROM public;
GRANT EXECUTE ON FUNCTION public.block_user(uuid) TO authenticated;

-- ------------------------------------------------------------
-- 3) user_sns_links SELECT ポリシー更新
--    鍵なしユーザーは「自分にいいねしてくれた相手」へ即開示する。
-- ------------------------------------------------------------
DROP POLICY IF EXISTS "user_sns_select_owner_or_matched" ON public.user_sns_links;
DROP POLICY IF EXISTS "user_sns_select_v2" ON public.user_sns_links;

CREATE POLICY "user_sns_select_v2" ON public.user_sns_links
FOR SELECT USING (
  -- 本人
  user_id IN (SELECT user_id FROM public.users WHERE auth_id = auth.uid())
  -- マッチ済みの相手
  OR EXISTS (
    SELECT 1
    FROM public.matches m
    JOIN public.users me ON me.auth_id = auth.uid()
    WHERE (m.user_a_id = public.user_sns_links.user_id AND m.user_b_id = me.user_id)
       OR (m.user_b_id = public.user_sns_links.user_id AND m.user_a_id = me.user_id)
  )
  -- 鍵なし(公開)アカウントで、閲覧者がそのユーザーへ「いいね」済み
  OR EXISTS (
    SELECT 1
    FROM public.users owner
    JOIN public.users me ON me.auth_id = auth.uid()
    JOIN public.likes l
      ON l.from_user_id = me.user_id
     AND l.to_user_id = owner.user_id
    WHERE owner.user_id = public.user_sns_links.user_id
      AND owner.is_private = FALSE
  )
);
