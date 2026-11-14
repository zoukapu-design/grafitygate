-- Grafity Gate：景色の GATE と、見え方（見本の写真の特徴）をあとから足す仕組み
--
-- 1. GATE の種類に「景色」（view）を足す。展望台・川辺などで、遠くの景色に向けて作る GATE。
--    入る決まり（その場から 120m 以内・精度・写真の特徴が合う）は場所・物と同じ。
-- 2. 景色は時間・天気・季節で見え方が大きく変わるので、作った本人が現地で見本の写真の特徴を足せる
--    （gf_add_gate_refs。夕方・夜・別の季節など）。入るときは、いちばん近い見本で判定する（gf_enter のまま）。
--    足すときも、合言葉（1 回だけ）・その場から 120m 以内・精度 35m 以内を確かめる（遠くから足せない）。
--    見本は 1 つの GATE に 12 まで（gf_settings の max_refs_per_gate）。写真そのものは送らない（特徴だけ）。
--
-- 使い方：0014 のあとに、Supabase の SQL Editor に貼って実行する。何度実行しても大丈夫。

insert into public.gf_settings (key, value, note) values
  ('max_refs_per_gate', 12, '1 つの GATE の見本の写真の特徴の数の上限（作るときの分も入れて）'),
  ('ref_adds_per_day', 20, '1 日に足せる見本の数（1 人）')
on conflict (key) do nothing;

-- 種類：場所／場所の中の物／景色（あとで種類を足すときも、この「最後の一覧」に足す）
alter table public.gf_gates drop constraint if exists gf_gates_kind_check;
alter table public.gf_gates add constraint gf_gates_kind_check check (kind in ('place', 'object', 'view'));

-- 見本の数（作った本人だけ）
create or replace function public.gf_gate_ref_count(p_gate uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  if not exists (select 1 from gf_gates where id = p_gate and owner = auth.uid()) then
    raise exception 'gf_not_found' using errcode = 'P0001';
  end if;
  return jsonb_build_object(
    'count', (select count(*) from gf_gate_refs where gate_id = p_gate),
    'max', gf_setting('max_refs_per_gate')::int);
end $$;

-- 見本を足す（作った本人が、現地で）。足したあとの数を返す。
create or replace function public.gf_add_gate_refs(
  p_gate uuid, p_challenge uuid, p_lat double precision, p_lon double precision, p_accuracy real, p_refs jsonb)
returns int
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  why text;
  g gf_gates;
  ref jsonb;
  pr real[];
  have int;
begin
  if me is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  if not exists (select 1 from gf_terms x where x.user_id = me and x.version >= gf_terms_version()) then
    raise exception 'gf_terms_required' using errcode = 'P0001';
  end if;
  why := gf_use_challenge(p_challenge);
  if why is not null then raise exception 'gf_%', why using errcode = 'P0001'; end if;

  select * into g from gf_gates where id = p_gate and owner = me for update;
  if not found then raise exception 'gf_not_found' using errcode = 'P0001'; end if;
  if not gf_valid_position(p_lat, p_lon) then raise exception 'gf_bad_position' using errcode = 'P0001'; end if;
  if p_accuracy is null or p_accuracy < 0 or p_accuracy > gf_setting('max_accuracy_m') then
    raise exception 'gf_inaccurate' using errcode = 'P0001';
  end if;
  if gf_distance_m(p_lat, p_lon, g.lat, g.lon) > gf_setting('enter_radius_m') then
    raise exception 'gf_too_far' using errcode = 'P0001';
  end if;
  if p_refs is null or jsonb_typeof(p_refs) <> 'array' or jsonb_array_length(p_refs) not between 1 and 3 then
    raise exception 'gf_bad_references' using errcode = 'P0001';
  end if;
  select count(*) into have from gf_gate_refs where gate_id = g.id;
  if have + jsonb_array_length(p_refs) > gf_setting('max_refs_per_gate') then
    raise exception 'gf_too_many_refs' using errcode = 'P0001';
  end if;
  perform gf_take_rate('gate_refs', gf_setting('ref_adds_per_day'), 86400);

  for ref in select * from jsonb_array_elements(p_refs) loop
    if jsonb_typeof(ref -> 'print') <> 'array' or (ref ->> 'rev') is null then
      raise exception 'gf_bad_references' using errcode = 'P0001';
    end if;
    select array_agg(x::real) into pr from jsonb_array_elements_text(ref -> 'print') as t(x);
    -- 写真そのものは持たない（特徴だけ）
    insert into gf_gate_refs (gate_id, print, print_rev, photo_path) values (g.id, pr, (ref ->> 'rev')::int, null);
  end loop;
  update gf_gates set updated_at = now() where id = g.id;
  return have + jsonb_array_length(p_refs);
end $$;

revoke all on function public.gf_gate_ref_count(uuid) from public, anon;
grant execute on function public.gf_gate_ref_count(uuid) to authenticated;
revoke all on function public.gf_add_gate_refs(uuid, uuid, double precision, double precision, real, jsonb) from public, anon;
grant execute on function public.gf_add_gate_refs(uuid, uuid, double precision, double precision, real, jsonb) to authenticated;
