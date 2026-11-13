-- Grafity Gate：場所の記憶（ARWorldMap）
--
-- GATE を作った人が扉の前で保存した「場所の記憶」を、友達の iPhone に届けて、扉を同じ位置・向きに出すためのもの。
-- 場所の記憶には周りの景色の特徴が入るので、受け取れるのは「その GATE の有効な入場券を持つ人」と作った本人だけ。
-- GATE を消すと一緒に消える（ファイル本体は、アプリが GATE を消すときに消す）。
--
-- 使い方：0001 のあとに、Supabase の SQL Editor に貼って実行する。何度実行しても大丈夫。

create table if not exists public.gf_place_maps (
  gate_id uuid primary key references public.gf_gates(id) on delete cascade,
  owner uuid not null references public.profiles(id) on delete cascade,
  path text not null,
  anchor_name text not null default 'gg.gate' check (char_length(anchor_name) between 1 and 64),
  byte_size int not null check (byte_size between 1 and 31457280),
  created_at timestamptz not null default now()
);
create index if not exists gf_place_maps_path on public.gf_place_maps(path);
-- 直接は読ませない（下の関数を通す）
alter table public.gf_place_maps enable row level security;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('gf-maps', 'gf-maps', false, 31457280, array['application/octet-stream'])
on conflict (id) do nothing;

-- 自分の GATE に場所の記憶を登録する（作り直したら置き換える）
create or replace function public.gf_register_place_map(p_gate uuid, p_path text, p_size int, p_anchor text)
returns void
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  if not exists (select 1 from gf_gates where id = p_gate and owner = me) then
    raise exception 'gf_not_found' using errcode = 'P0001';
  end if;
  if p_path is null or split_part(p_path, '/', 1) <> me::text then
    raise exception 'gf_bad_media_path' using errcode = 'P0001';
  end if;
  insert into gf_place_maps (gate_id, owner, path, anchor_name, byte_size)
  values (p_gate, me, p_path, coalesce(nullif(p_anchor, ''), 'gg.gate'), p_size)
  on conflict (gate_id) do update
    set path = excluded.path, anchor_name = excluded.anchor_name, byte_size = excluded.byte_size,
        created_at = now();
end $$;

-- 場所の記憶の置き場所（作った本人か、いま入場中の人だけに返す）
create or replace function public.gf_place_map(p_gate uuid)
returns table (path text, anchor_name text, byte_size int, created_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  return query
    select m.path, m.anchor_name, m.byte_size, m.created_at
    from gf_place_maps m
    where m.gate_id = p_gate
      and (m.owner = auth.uid() or gf_active_visit(m.gate_id, auth.uid()) is not null);
end $$;

-- 場所の記憶のファイルを読んでよいか
create or replace function public.gf_can_read_map(p_path text) returns boolean
language sql stable security definer set search_path = public as $$
  select auth.uid() is not null and (
    split_part(p_path, '/', 1) = auth.uid()::text
    or exists (select 1 from gf_place_maps m
               where m.path = p_path and gf_active_visit(m.gate_id, auth.uid()) is not null))
$$;

drop policy if exists "gf maps read" on storage.objects;
create policy "gf maps read" on storage.objects for select to authenticated
  using (bucket_id = 'gf-maps' and public.gf_can_read_map(name));
drop policy if exists "gf maps insert" on storage.objects;
create policy "gf maps insert" on storage.objects for insert to authenticated
  with check (bucket_id = 'gf-maps' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists "gf maps update" on storage.objects;
create policy "gf maps update" on storage.objects for update to authenticated
  using (bucket_id = 'gf-maps' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists "gf maps delete" on storage.objects;
create policy "gf maps delete" on storage.objects for delete to authenticated
  using (bucket_id = 'gf-maps' and (storage.foldername(name))[1] = auth.uid()::text);

revoke all on function public.gf_register_place_map(uuid, text, int, text) from public, anon;
revoke all on function public.gf_place_map(uuid) from public, anon;
revoke all on function public.gf_can_read_map(text) from public, anon;
grant execute on function public.gf_register_place_map(uuid, text, int, text) to authenticated;
grant execute on function public.gf_place_map(uuid) to authenticated;
grant execute on function public.gf_can_read_map(text) to authenticated;
