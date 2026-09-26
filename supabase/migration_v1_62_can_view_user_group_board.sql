-- ============================================================
-- Migration v1.62 : can_view_user() をグループ/掲示板の共通参加者にも拡張
-- Supabase SQL Editor で実行してください。前提: v1.38（groups）、v1.39（掲示板）実行済み。
-- ------------------------------------------------------------
-- 目的:
--   can_view_user() はこれまで「すれ違い・マッチ・いいね」した相手しか
--   基本プロフィール（ニックネーム・アバター等）を見られない仕様だった。
--   今回グループ・掲示板機能を追加したことで、すれ違ったことのない相手と
--   グループやツーリング募集で繋がるケースが生まれたが、そうした相手の
--   プロフィールを見る・通報する手段が一切なかった（Apple審査
--   Guideline 1.2のUGC安全性要件に抵触するリスク）。
--
--   「同じグループのメンバー同士」「同じ掲示板投稿の参加者同士」も
--   お互いのプロフィールを閲覧できるよう条件を追加する。
--   ブロック済みなら従来通り見えない。
--
--   何度実行しても安全（冪等）。
-- ============================================================

CREATE OR REPLACE FUNCTION public.can_view_user(p_target_user_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  SELECT
    p_target_user_id IN (
      SELECT user_id FROM public.users WHERE auth_id = auth.uid()
    )
    OR (
      NOT EXISTS (
        SELECT 1
        FROM public.blocks b
        JOIN public.users me ON me.auth_id = auth.uid()
        WHERE (b.blocker_id = me.user_id AND b.blocked_id = p_target_user_id)
           OR (b.blocker_id = p_target_user_id AND b.blocked_id = me.user_id)
      )
      AND (
        EXISTS (
          SELECT 1
          FROM public.encounters e
          JOIN public.users me ON me.auth_id = auth.uid()
          WHERE (e.user_a_id = p_target_user_id AND e.user_b_id = me.user_id)
             OR (e.user_b_id = p_target_user_id AND e.user_a_id = me.user_id)
        )
        OR EXISTS (
          SELECT 1
          FROM public.matches m
          JOIN public.users me ON me.auth_id = auth.uid()
          WHERE (m.user_a_id = p_target_user_id AND m.user_b_id = me.user_id)
             OR (m.user_b_id = p_target_user_id AND m.user_a_id = me.user_id)
        )
        OR EXISTS (
          SELECT 1
          FROM public.likes l
          JOIN public.users me ON me.auth_id = auth.uid()
          WHERE (l.from_user_id = me.user_id AND l.to_user_id = p_target_user_id)
             OR (l.to_user_id = me.user_id AND l.from_user_id = p_target_user_id)
        )
        OR EXISTS (
          SELECT 1
          FROM public.group_memberships gm_me
          JOIN public.group_memberships gm_target
            ON gm_target.group_id = gm_me.group_id
          JOIN public.users me ON me.auth_id = auth.uid()
          WHERE gm_me.user_id = me.user_id AND gm_me.status = 'member'
            AND gm_target.user_id = p_target_user_id AND gm_target.status = 'member'
        )
        OR EXISTS (
          SELECT 1
          FROM public.board_participations bp_me
          JOIN public.board_participations bp_target
            ON bp_target.post_id = bp_me.post_id
          JOIN public.users me ON me.auth_id = auth.uid()
          WHERE bp_me.user_id = me.user_id AND bp_me.status IN ('joined', 'interested')
            AND bp_target.user_id = p_target_user_id AND bp_target.status IN ('joined', 'interested')
        )
      )
    );
$function$;
