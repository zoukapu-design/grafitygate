-- Grafity Gate：場所の記憶の「見つかりやすさ」と、GATE の数字
--
-- 場所の記憶（ARWorldMap）は、光や季節で景色が変わると見つからなくなる。入場した人の iPhone が
-- 「見つかった／見つからなかった」と探した秒数だけを送り（写真や位置は送らない）、見つからない日が続いたら
-- 作った人に「場所の記憶を撮り直す」お知らせを出す（7 日に 1 回まで）。
-- GATE の数字：訪れた人の数・最後に記録が増えた日（表紙に出す）。
--
-- 使い方：0007 のあとに、Supabase の SQL Editor に貼って実行する（setup_all.sql にも入っている）。何度実行しても大丈夫。

insert into public.gf_settings (key, value, note) values
  ('place_map_stale_misses', 3, '場所の記憶の撮り直しを知らせる：14 日のうちに見つからなかった回数'),
  ('place_map_stale_ratio', 0.6, '場所の記憶の撮り直しを知らせる：最近 10 回のうち見つからなかった割合')
on conflict (key) do nothing;

create table if not exists public.gf_relocalize_log (
  visit_id uuid primary key references public.gf_visits(id) on delete cascade,
  gate_id uuid not null references public.gf_gates(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  found boolean not null,
  seconds real not null check (seconds between 0 and 600),
  created_at timestamptz not null default now()
);
create index if not exists gf_relocalize_log_gate on public.gf_relocalize_log(gate_id, created_at desc);
alter table public.gf_relocalize_log enable row level security;
-- 表は直接読ませない（作った本人には gf_place_map_health でまとめて返す）

-- お知らせの種類に「場所の記憶を撮り直す」を足す
alter table public.gf_notifications drop constraint if exists gf_notifications_kind_check;
alter table public.gf_notifications add constraint gf_notifications_kind_check
  check (kind in ('gate_graffiti', 'gate_artwork', 'board_thread', 'board_reply', 'letter', 'letter_opened',
                  'memory_invite', 'memory_photo', 'like', 'place_map_stale'));

-- 探した結果を送る（その入場で 1 回。送り直したら上書き）
create or replace function public.gf_report_relocalize(p_visit uuid, p_found boolean, p_seconds real) returns void
language plpgsql security definer set search_path = public as $$
declare
  v gf_visits := gf_valid_visit(p_visit);
  g gf_gates;
  misses int;
  recent_total int;
  recent_misses int;
begin
  insert into gf_relocalize_log (visit_id, gate_id, user_id, found, seconds)
  values (v.id, v.gate_id, auth.uid(), coalesce(p_found, false), least(greatest(coalesce(p_seconds, 0), 0), 600))
  on conflict (visit_id) do update set found = excluded.found, seconds = excluded.seconds, created_at = now();

  select * into g from gf_gates where id = v.gate_id;
  if coalesce(p_found, false) or g.owner = auth.uid() then return; end if;

  -- 作った本人の分は数えない（本人は撮り直せるので、ほかの人が見つけられないときだけ知らせる）
  select count(*) into misses from gf_relocalize_log l
    where l.gate_id = g.id and l.user_id <> g.owner and not l.found and l.created_at > now() - interval '14 days';
  select count(*), count(*) filter (where not x.found) into recent_total, recent_misses
    from (select l.found from gf_relocalize_log l where l.gate_id = g.id and l.user_id <> g.owner
          order by l.created_at desc limit 10) x;
  if misses >= gf_setting('place_map_stale_misses')
     and recent_misses::numeric / greatest(recent_total, 1) >= gf_setting('place_map_stale_ratio')
     and not exists (select 1 from gf_notifications n where n.user_id = g.owner and n.kind = 'place_map_stale'
                     and n.gate_id = g.id and n.created_at > now() - interval '7 days') then
    -- だれが見つけられなかったかは知らせない（actor は作った本人にする）
    insert into gf_notifications (user_id, kind, actor, gate_id, ref_id)
    values (g.owner, 'place_map_stale', g.owner, g.id, null);
  end if;
end $$;

-- 場所の記憶の見つかりやすさ（作った本人だけ）
create or replace function public.gf_place_map_health(p_gate uuid)
returns table (has_map boolean, map_saved_at timestamptz, attempts bigint, found bigint,
               recent_attempts bigint, recent_found bigint, last_found_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  if not exists (select 1 from gf_gates g where g.id = p_gate and g.owner = auth.uid()) then
    raise exception 'gf_not_found' using errcode = 'P0001';
  end if;
  return query
    select exists (select 1 from gf_place_maps m where m.gate_id = p_gate),
           (select m.created_at from gf_place_maps m where m.gate_id = p_gate),
           (select count(*) from gf_relocalize_log l where l.gate_id = p_gate),
           (select count(*) from gf_relocalize_log l where l.gate_id = p_gate and l.found),
           (select count(*) from (select 1 from gf_relocalize_log l where l.gate_id = p_gate
                                  order by l.created_at desc limit 10) x),
           (select count(*) from (select l.found from gf_relocalize_log l where l.gate_id = p_gate
                                  order by l.created_at desc limit 10) x where x.found),
           (select max(l.created_at) from gf_relocalize_log l where l.gate_id = p_gate and l.found);
end $$;

-- 場所の記憶を撮り直したら、それまでの「見つからなかった」記録は数えない
create or replace function public.gf_on_place_map_saved() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  delete from gf_relocalize_log where gate_id = new.gate_id and created_at < now();
  return new;
end $$;
drop trigger if exists gf_on_place_map_saved on public.gf_place_maps;
create trigger gf_on_place_map_saved after insert or update on public.gf_place_maps
  for each row execute function public.gf_on_place_map_saved();

-- GATE の数字（表紙）：訪れた人の数、最後に記録が増えた日、自分が訪れた回数
create or replace function public.gf_gate_stats(p_gate uuid)
returns table (visitor_count bigint, last_activity_at timestamptz, my_visits int)
language plpgsql stable security definer set search_path = public as $$
declare g gf_gates;
begin
  if auth.uid() is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  select * into g from gf_gates where id = p_gate;
  if not found or not gf_can_see_gate(g, auth.uid()) then raise exception 'gf_not_found' using errcode = 'P0001'; end if;
  return query
    select (select count(distinct v.user_id) from gf_visits v where v.gate_id = g.id),
           greatest(g.created_at,
                    (select max(x.created_at) from gf_graffiti x where x.gate_id = g.id and x.deleted_at is null),
                    (select max(a.created_at) from gf_artworks a where a.gate_id = g.id and a.status = 'published'),
                    (select max(t.last_activity_at) from gf_board_threads t where t.gate_id = g.id and t.deleted_at is null),
                    (select max(s.created_at) from gf_snapshots s where s.gate_id = g.id)),
           coalesce((select a.visits from gf_atlas a where a.user_id = auth.uid() and a.gate_id = g.id), 0);
end $$;

revoke all on function public.gf_on_place_map_saved() from public, anon, authenticated;
do $$
declare f text;
begin
  foreach f in array array['gf_report_relocalize(uuid, boolean, real)', 'gf_place_map_health(uuid)',
                           'gf_gate_stats(uuid)']
  loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;
