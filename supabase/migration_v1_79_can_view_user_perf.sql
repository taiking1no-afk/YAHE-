-- ============================================================
-- Migration v1.79 : can_view_user() のパフォーマンス改善
-- Supabase SQL Editor で実行してください。前提: v1.74実行済み。
-- ------------------------------------------------------------
-- 背景: can_view_user() は「自分自身」「同じグループ」「同じ掲示板投稿」
--   「ブロックしていなければ、すれ違い/マッチ/いいねのいずれか」の4つを
--   ORで判定するが、これまで「同じグループ」「同じ掲示板投稿」（自己結合を
--   伴い比較的重い）が最初に評価される順序になっていた。
--   ホーム画面（すれ違い一覧）のように、対象がほぼ確実に「すれ違い」経由
--   でしか成立しないケースでも、毎回この重い自己結合を先に評価してから
--   ようやく軽いすれ違いチェックに辿り着いていたため、無駄なコストが
--   すれ違い件数分だけ積み重なっていた。
--   OR条件の意味は変えず、評価順序だけを「軽くて命中しやすい条件を先」に
--   並べ替える。また auth.uid() → users行の解決を1回のCTEにまとめ、
--   同じ解決を複数回繰り返さないようにする。
--
--   何度実行しても安全（冪等、判定結果は変化しない）。
-- ============================================================

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
      -- 自分が相手をブロックしている場合のみ非表示にする
      -- （相手が自分をブロックしていても、自分からは引き続き見える）
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
          WHERE (m.user_a_id = p_target_user_id AND m.user_b_id = me.user_id)
             OR (m.user_b_id = p_target_user_id AND m.user_a_id = me.user_id)
        )
        OR EXISTS (
          SELECT 1 FROM public.likes l, me
          WHERE (l.from_user_id = me.user_id AND l.to_user_id = p_target_user_id)
             OR (l.to_user_id = me.user_id AND l.from_user_id = p_target_user_id)
        )
      )
    )
    OR EXISTS (
      SELECT 1
      FROM public.group_memberships gm_me
      JOIN public.group_memberships gm_target
        ON gm_target.group_id = gm_me.group_id
      CROSS JOIN me
      WHERE gm_me.user_id = me.user_id AND gm_me.status = 'member'
        AND gm_target.user_id = p_target_user_id AND gm_target.status = 'member'
    )
    OR EXISTS (
      SELECT 1
      FROM public.board_participations bp_me
      JOIN public.board_participations bp_target
        ON bp_target.post_id = bp_me.post_id
      CROSS JOIN me
      WHERE bp_me.user_id = me.user_id AND bp_me.status IN ('joined', 'interested')
        AND bp_target.user_id = p_target_user_id AND bp_target.status IN ('joined', 'interested')
    );
$function$;
