-- ホームの友達の新着に、カードの仕上げ（0026）も返す（2026-11-18 オーナー「ホームをもっとオシャレに」）。
-- 見せてよいかの決まりは gf_friend_feed と同じ（gf_feed_visible）。前の gf_friend_feed は残す（古いアプリ用）。
create or replace function public.gf_friend_feed2()
returns table (id uuid, author uuid, author_name text, gate_id uuid, gate_title text,
               approx_lat double precision, approx_lon double precision,
               body text, photo_path text, created_at timestamptz, finish text)
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  return query
    select x.id, x.author, p.display_name, g.id, g.title,
           round(g.lat::numeric, 3)::double precision, round(g.lon::numeric, 3)::double precision,
           x.body, x.photo_path, x.created_at, x.finish
    from gf_graffiti x
    join gf_gates g on g.id = x.gate_id
    join profiles p on p.id = x.author
    where gf_feed_visible(x, auth.uid())
    order by x.created_at desc
    limit 200;
end $$;
revoke all on function public.gf_friend_feed2() from public, anon;
grant execute on function public.gf_friend_feed2() to authenticated;
