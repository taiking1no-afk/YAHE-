-- ============================================================
-- Migration v1.95 : ブロック可視性マトリクスの徹底（グループ/掲示板の
--                    共通参加による例外を廃止）
-- Supabase SQL Editor で実行してください。前提: v1.79実行済み。
-- ------------------------------------------------------------
-- 背景:
--   v1.62以降、can_view_user() には「同じグループ／同じ掲示板投稿に
--   参加していれば、ブロック関係があっても例外的に閲覧・接触可能にする」
--   という仕様が意図的に組み込まれていた（v1.69のコメント参照）。
--
--   今回、運営者から明示的に「ブロックした場合はイベント/グループでの
--   接触も含めて一律に非表示にする」という指示があったため、この例外を
--   廃止する。これは既存の意図的な設計を覆す変更であり、グループ/掲示板
--   経由でのみ繋がっていたユーザー同士は、ブロック後にプロフィール・
--   愛車・SNS等が互いに見えなくなる（従来は見えていた）。
--
--   グループ/掲示板の「参加登録」自体（group_memberships・
--   board_participations の行、グループチャット自体のメッセージ閲覧）は
--   維持する。他の共同参加者を巻き込んで強制退会させるのは影響が大きい
--   ため、ここでは can_view_user() が握るプロフィール等の可視性のみを
--   絞り込む。グループチャット内の表示調整はクライアント側
--   （blockedUserIdsProviderによるグレーアウト）で多層防御する。
--
--   can_view_user() のブロック方向性（v1.74の非対称化：自分が相手を
--   ブロックしている場合のみ非表示）は変更しない。グループ/掲示板の
--   例外分岐を削除するだけで、開発者の指定した双方向マトリクスが
--   自然に満たされる（相手をブロックした側は完全非表示、ブロックされた
--   側も、直接のすれ違い/マッチ/いいねが無ければ同様に非表示になる）。
--
--   何度実行しても安全（冪等）。
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
    );
$function$;

-- ============================================================
-- 動作確認用クエリ（手動実行）
-- ============================================================
-- SELECT prosrc ILIKE '%group_memberships%' AS still_has_group_exception FROM pg_proc WHERE proname = 'can_view_user';
-- 期待値: false（例外が削除されていること）
