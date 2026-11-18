-- 扉の見た目（2026-11-18 オーナー「AR で見て面白い見た目のゲートをたくさん」「シンプル・かわいいものも」）。
-- 作った本人が選ぶ。入った人にも同じ見た目で出る（gf_gate_door が返す）。飾りだけで、入る決まりは変わらない。
alter table public.gf_gates add column if not exists door_style text not null default 'neon';
alter table public.gf_gates drop constraint if exists gf_gates_door_style_check;
alter table public.gf_gates add constraint gf_gates_door_style_check check (door_style in (
  'neon', 'magic', 'torii', 'timering', 'crystal', 'wooden', 'galaxy',
  'heart', 'cloud', 'flower', 'candy', 'cat',
  'white', 'black', 'round'));

create or replace function public.gf_set_door_style(p_gate uuid, p_style text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  if coalesce(p_style, '') not in ('neon', 'magic', 'torii', 'timering', 'crystal', 'wooden', 'galaxy',
                                   'heart', 'cloud', 'flower', 'candy', 'cat', 'white', 'black', 'round') then
    raise exception 'gf_bad_style' using errcode = 'P0001';
  end if;
  update gf_gates set door_style = p_style, updated_at = now() where id = p_gate and owner = auth.uid();
  if not found then raise exception 'gf_not_found' using errcode = 'P0001'; end if;
end $$;
revoke all on function public.gf_set_door_style(uuid, text) from public, anon;
grant execute on function public.gf_set_door_style(uuid, text) to authenticated;

-- 扉の大きさと見た目（その GATE を見てよい人だけ。0016 に style を足したもの）
create or replace function public.gf_gate_door(p_gate uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare g gf_gates;
begin
  select * into g from gf_gates where id = p_gate;
  if not found or not gf_can_see_gate(g, auth.uid()) then raise exception 'gf_not_found' using errcode = 'P0001'; end if;
  return jsonb_build_object('scale', g.door_scale, 'kind', g.kind, 'style', g.door_style);
end $$;
revoke all on function public.gf_gate_door(uuid) from public, anon;
grant execute on function public.gf_gate_door(uuid) to authenticated;
