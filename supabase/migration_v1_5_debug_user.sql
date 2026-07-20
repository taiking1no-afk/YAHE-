-- Migration v1.5: テスト用ダミーユーザー作成
-- Supabase SQL Editor で1回だけ実行してください

-- ① auth.users にテスト用認証ユーザーを追加
INSERT INTO auth.users (
  id,
  email,
  encrypted_password,
  email_confirmed_at,
  created_at,
  updated_at,
  raw_app_meta_data,
  raw_user_meta_data,
  is_super_admin,
  role,
  aud
)
VALUES (
  '00000000-0000-0000-0000-000000000001',
  'debug-partner@yaeh.internal',
  crypt('debug-only', gen_salt('bf')),
  NOW(),
  NOW(),
  NOW(),
  '{"provider":"email","providers":["email"]}',
  '{}',
  FALSE,
  'authenticated',
  'authenticated'
)
ON CONFLICT (id) DO NOTHING;

-- ② public.users にテスト用プロフィールを追加
INSERT INTO public.users (
  user_id,
  auth_id,
  nickname,
  sns_links,
  plan
)
VALUES (
  '00000000-0000-0000-0000-000000000002',
  '00000000-0000-0000-0000-000000000001',
  'デバッグ用テストユーザー',
  '[]',
  'free'
)
ON CONFLICT (user_id) DO NOTHING;

-- 確認クエリ
SELECT user_id, nickname FROM public.users WHERE user_id = '00000000-0000-0000-0000-000000000002';
