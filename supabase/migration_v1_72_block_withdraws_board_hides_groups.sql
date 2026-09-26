-- ============================================================
-- Migration v1.72 : ブロック時の募集(イベント)自動辞退・グループ非表示の追加
-- Supabase SQL Editor で実行してください。前提: v1.65, v1.69 実行済み。
-- ------------------------------------------------------------
-- 要件:
--   1. ブロックした相手が主催する募集(ツーリング/イベント)に、既に
--      「気になる」「参加済み」「参加申請中」「招待中」だった場合、
--      ブロックした瞬間にすべて解除（辞退）する。ブロック解除しても
--      自動では復元しない（再度参加申請が必要）。
--      参加(joined)を解除する際、その募集の参加者チャット
--      (chat_group_id)からも同時に退出する。
--   2. ブロックした相手が主催する募集は、ブロック中は一覧・詳細に
--      出てこない（migration_v1_69で対応済み・変更なし）。
--   3. グループは例外: 既に参加済み(status='member')のグループは
--      オーナーをブロックしても表示され続ける（自分で退会するまで
--      消えない）。未参加のグループのみ、オーナーがブロック関係に
--      あれば一覧から非表示にする。
--
--   何度実行しても安全（冪等）。
-- ============================================================

CREATE OR REPLACE FUNCTION public.block_user(p_blocked_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_me uuid;
  v_post RECORD;
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

  -- ブロックした相手が主催する募集への自分の関わり（気になる・参加済み・
  -- 参加申請中・招待中）をすべて解除する。ブロック解除しても復元しない
  -- （再度参加申請が必要）。参加者チャットに入っていれば同時に退出する。
  FOR v_post IN
    SELECT bp.post_id, bp.chat_group_id
    FROM public.board_posts bp
    WHERE bp.organizer_id = p_blocked_id
  LOOP
    DELETE FROM public.board_participations
    WHERE post_id = v_post.post_id AND user_id = v_me;

    IF v_post.chat_group_id IS NOT NULL THEN
      DELETE FROM public.group_memberships
      WHERE group_id = v_post.chat_group_id AND user_id = v_me AND role <> 'owner';
    END IF;
  END LOOP;
END;
$function$;

-- グループは例外: 既に参加済み(member)のグループはオーナーをブロックしても
-- 表示され続ける。未参加のグループのみ、オーナーとブロック関係にあれば非表示にする。
DROP POLICY IF EXISTS "groups_select_all" ON public.groups;
CREATE POLICY "groups_select_all" ON public.groups FOR SELECT USING (
  auth.role() = 'authenticated'
  AND (
    EXISTS (
      SELECT 1 FROM public.group_memberships gm
      JOIN public.users me ON me.auth_id = auth.uid()
      WHERE gm.group_id = groups.group_id AND gm.user_id = me.user_id AND gm.status = 'member'
    )
    OR NOT EXISTS (
      SELECT 1 FROM public.blocks b
      JOIN public.users me ON me.auth_id = auth.uid()
      WHERE (b.blocker_id = me.user_id AND b.blocked_id = groups.owner_id)
         OR (b.blocker_id = groups.owner_id AND b.blocked_id = me.user_id)
    )
  )
);


-- ============================================================
-- 動作確認用クエリ（手動実行）
-- ============================================================
-- SELECT prosrc ILIKE '%board_participations%' AS withdraws_board_posts FROM pg_proc WHERE proname = 'block_user';
-- SELECT qual ILIKE '%blocks%' AS hides_blocked_owner_groups FROM pg_policies WHERE tablename = 'groups' AND policyname = 'groups_select_all';
