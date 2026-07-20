-- Migration v1.1 : 複数台登録・納車日・カスタム内容
ALTER TABLE public.vehicles ADD COLUMN IF NOT EXISTS delivery_date DATE;
ALTER TABLE public.vehicles ADD COLUMN IF NOT EXISTS custom_content TEXT;
