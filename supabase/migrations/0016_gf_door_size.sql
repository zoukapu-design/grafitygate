-- Grafity Gate：扉の大きさ
--
-- 前は扉がいつも人が通る大きさ（幅 0.8m・高さ約 2m）で、机の上の小さな物に作ると物よりずっと大きかった（2026-11-15）。
-- 引き継ぎの決まりにも「人や車の通行をじゃまする巨大な扉にしない」とある。
-- 作った本人が置くときに大きさを選び（0.2〜1.5 倍）、入った人にも同じ大きさで出す。作った本人はあとで変えられる。
-- 作品の位置・大きさは扉の足もとが基準で、扉の大きさとは別（扉を小さくしても作品は小さくならない）。
--
-- 使い方：0015 のあとに、Supabase の SQL Editor に貼って実行する。何度実行しても大丈夫。

alter table public.gf_gates add column if not exists door_scale real not null default 1.0;
alter table public.gf_gates drop constraint if exists gf_gates_door_scale_check;
alter table public.gf_gates add constraint gf_gates_door_scale_check check (door_scale between 0.2 and 1.5);

-- 大きさを決める（作った本人だけ。遠くからでもよい＝見た目だけの設定）
create or replace function public.gf_set_door_scale(p_gate uuid, p_scale real) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  if p_scale is null or p_scale < 0.2 or p_scale > 1.5 then raise exception 'gf_bad_scale' using errcode = 'P0001'; end if;
  update gf_gates set door_scale = p_scale, updated_at = now() where id = p_gate and owner = auth.uid();
  if not found then raise exception 'gf_not_found' using errcode = 'P0001'; end if;
end $$;

-- 扉の大きさ（その GATE を見てよい人だけ）
create or replace function public.gf_gate_door(p_gate uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare g gf_gates;
begin
  select * into g from gf_gates where id = p_gate;
  if not found or not gf_can_see_gate(g, auth.uid()) then raise exception 'gf_not_found' using errcode = 'P0001'; end if;
  return jsonb_build_object('scale', g.door_scale, 'kind', g.kind);
end $$;

revoke all on function public.gf_set_door_scale(uuid, real) from public, anon;
grant execute on function public.gf_set_door_scale(uuid, real) to authenticated;
revoke all on function public.gf_gate_door(uuid) from public, anon;
grant execute on function public.gf_gate_door(uuid) to authenticated;
