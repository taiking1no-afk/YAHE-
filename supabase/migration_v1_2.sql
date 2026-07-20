-- Migration v1.2 : バイク対応（vehicle_type カラム追加）
ALTER TABLE public.vehicles
  ADD COLUMN IF NOT EXISTS vehicle_type TEXT NOT NULL DEFAULT 'car'
  CHECK (vehicle_type IN ('car', 'bike'));
