-- Supabase の SQL Editor でこのファイルの内容をそのまま実行してください。
-- 学園祭版の属性（学部・今日の目的・目標・2択など）を保存する列を追加します。通常版のテーブルには一切触りません。
-- 何度実行しても同じ結果になるように書いてあります（再実行しても壊れません）。
--
-- 項目ごとに列を分けず jsonb の1列にまとめたのは、2択のお題や選択肢が MTG で変わっても
-- 列の追加・変更（＝SQLの再実行）をしなくて済むようにするため。

alter table public.fes_profiles add column if not exists fes_attrs jsonb not null default '{}'::jsonb;

-- いいねした時点で「何が共通していたか」を残す。
-- どの種類の共通点（学部／今日の目的／目標／2択）がマッチにつながったかを、学園祭のあとで集計するため。
alter table public.fes_likes add column if not exists matched jsonb;

-- アプリ（PostgREST）に新しい列をすぐ認識させる
notify pgrst, 'reload schema';

-- 確認: 2行出ればOK
select table_name, column_name, data_type
from information_schema.columns
where table_schema = 'public'
  and ((table_name = 'fes_profiles' and column_name = 'fes_attrs')
    or (table_name = 'fes_likes'    and column_name = 'matched'));
