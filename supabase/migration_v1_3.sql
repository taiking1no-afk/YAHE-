-- migration_v1_3: encounters テーブルに何回目かのカラムを追加
ALTER TABLE public.encounters
  ADD COLUMN IF NOT EXISTS occurrence_number INTEGER NOT NULL DEFAULT 1;

COMMENT ON COLUMN public.encounters.occurrence_number IS '同一ペアで何回目のすれ違いか（1=初回）';
