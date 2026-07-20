-- Migration v1.4: FCM token + Gear+ grant RPC
-- Run this in Supabase SQL Editor

-- FCM トークン列
ALTER TABLE public.users
  ADD COLUMN IF NOT EXISTS fcm_token TEXT;

-- grant_gear_plus: RevenueCat 購入完了後にアプリから呼び出す RPC
-- 呼び出し元が自分のレコードのみ更新できる（RLS で保護）
CREATE OR REPLACE FUNCTION public.grant_gear_plus(p_user_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  -- 呼び出し元の auth.uid() と users.auth_id が一致する場合のみ更新
  UPDATE public.users
  SET plan = 'gear_plus'
  WHERE user_id = p_user_id
    AND auth_id = auth.uid()
    AND plan = 'free';
END;
$$;
