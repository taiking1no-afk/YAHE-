-- Migration v1.6: encounters INSERT RLS ポリシー追加
-- 【重要】これがないとすれ違いが一切記録されません
-- Supabase SQL Editor で実行してください

-- encounters: INSERT ポリシー（自分が参加者であれば登録可）
CREATE POLICY "encounters_insert_own" ON public.encounters
FOR INSERT WITH CHECK (
  user_a_id IN (SELECT user_id FROM public.users WHERE auth_id = auth.uid())
  OR
  user_b_id IN (SELECT user_id FROM public.users WHERE auth_id = auth.uid())
);

-- 確認クエリ（ポリシー一覧）
SELECT policyname, cmd, qual, with_check
FROM pg_policies
WHERE tablename = 'encounters';
