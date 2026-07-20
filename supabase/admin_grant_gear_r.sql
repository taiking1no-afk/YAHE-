-- ============================================================
-- 無料プレミアム付与（v1.15 以降）
-- Supabase SQL Editor で実行してください（service_role 権限）
-- ============================================================
--
-- 旧 admin_grant_gear_r.sql の UPDATE 文は admin_grant_premium RPC に統合しました。
-- 付与履歴は premium_grants テーブルに記録されます。
--
-- 事前確認:
--   SELECT * FROM public.premium_status_overview
--   WHERE nickname ILIKE '%検索したい名前%';
-- ============================================================


-- ─── ① オーナー/開発者を常時 Gear R に（テスト用・永久） ─────
SELECT public.admin_grant_premium(
  'YOUR_USER_ID_HERE'::uuid,
  'gear_r',           -- 'gear_plus' | 'gear_r'
  NULL,               -- NULL = 永久付与
  'test',             -- 'admin' | 'influencer' | 'test'
  'オーナー開発用'
);


-- ─── ② インフルエンサーに3ヶ月無料 Gear+ ─────────────────────
-- SELECT public.admin_grant_premium(
--   'YOUR_USER_ID_HERE'::uuid,
--   'gear_plus',
--   NOW() + INTERVAL '90 days',
--   'influencer',
--   '@handle コラボキャンペーン'
-- );


-- ─── ③ 手動付与を解除（購入プラン / トライアルは維持） ───────
-- SELECT public.admin_revoke_premium(
--   'YOUR_USER_ID_HERE'::uuid,
--   'キャンペーン終了'
-- );


-- ─── ④ トライアルを30日延長 ─────────────────────────────────
-- SELECT public.admin_extend_trial(
--   'YOUR_USER_ID_HERE'::uuid,
--   30,
--   '再登録キャンペーン'
-- );


-- ─── ⑤ 付与状態の確認 ───────────────────────────────────────
-- SELECT * FROM public.premium_status_overview
-- WHERE user_id = 'YOUR_USER_ID_HERE';


-- ─── ⑥ Gear R 初期アイテム付与（任意） ─────────────────────
-- INSERT INTO public.user_items (user_id, item_type, quantity)
-- VALUES
--   ('YOUR_USER_ID_HERE', 'super_nitro', 1),
--   ('YOUR_USER_ID_HERE', 'geki_shibu',  10)
-- ON CONFLICT (user_id, item_type)
-- DO UPDATE SET
--   quantity = public.user_items.quantity + EXCLUDED.quantity,
--   updated_at = NOW();


-- ─── ユーザーIDの調べ方 ────────────────────────────────────────
-- SELECT user_id, nickname, effective_plan, trial_ends_at
-- FROM public.premium_status_overview
-- WHERE nickname ILIKE '%検索したいニックネーム%';
