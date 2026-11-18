-- グラフィティカードの名前（2026-11-19 オーナー「カードの題名は名前ではなく、自分で選べるように。記入しなければ名前」）。
-- 書いた本人だけが付ける・直せる（扉の中でなくてよい）。空なら、アプリは書いた人の名前を出す。30 文字まで。
alter table public.gf_graffiti add column if not exists title text;
alter table public.gf_graffiti drop constraint if exists gf_graffiti_title_check;
alter table public.gf_graffiti add constraint gf_graffiti_title_check
  check (title is null or char_length(title) between 1 and 30);

create or replace function public.gf_set_card_title(p_card uuid, p_title text) returns void
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  t text := nullif(btrim(coalesce(p_title, '')), '');
begin
  if me is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  if t is not null and char_length(t) > 30 then raise exception 'gf_too_long' using errcode = 'P0001'; end if;
  update gf_graffiti set title = t where id = p_card and author = me;
  if not found then raise exception 'gf_not_found' using errcode = 'P0001'; end if;
end $$;
revoke all on function public.gf_set_card_title(uuid, text) from public, anon;
grant execute on function public.gf_set_card_title(uuid, text) to authenticated;

-- ホームの新着にも名前を返す（0027 の形に title を足す。返す形が変わるので作り直す）
drop function if exists public.gf_friend_feed2();
create or replace function public.gf_friend_feed2()
returns table (id uuid, author uuid, author_name text, gate_id uuid, gate_title text,
               approx_lat double precision, approx_lon double precision,
               body text, photo_path text, created_at timestamptz, finish text, title text)
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  return query
    select x.id, x.author, p.display_name, g.id, g.title,
           round(g.lat::numeric, 3)::double precision, round(g.lon::numeric, 3)::double precision,
           x.body, x.photo_path, x.created_at, x.finish, x.title
    from gf_graffiti x
    join gf_gates g on g.id = x.gate_id
    join profiles p on p.id = x.author
    where gf_feed_visible(x, auth.uid())
    order by x.created_at desc
    limit 200;
end $$;
revoke all on function public.gf_friend_feed2() from public, anon;
grant execute on function public.gf_friend_feed2() to authenticated;

-- チラ見せにも名前を出す（0026 の gf_gate_peek に title を足したもの）
create or replace function public.gf_gate_peek(p_gate uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  g gf_gates;
begin
  if me is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  select * into g from gf_gates where id = p_gate;
  if g.id is null or not gf_can_see_gate(g, me) then raise exception 'gf_not_found' using errcode = 'P0001'; end if;
  return jsonb_build_object(
    'opened', gf_has_opened(p_gate, me),
    'inside', gf_active_visit(p_gate, me) is not null,
    'cards', coalesce((
      select jsonb_agg(jsonb_build_object('id', x.id, 'author', x.author, 'author_name', p.display_name,
                                          'body', x.body, 'photo_path', x.photo_path, 'created_at', x.created_at,
                                          'finish', x.finish, 'title', x.title)
                       order by x.created_at desc)
      from gf_graffiti x join profiles p on p.id = x.author
      where x.id in (select gf_peek_card_ids(p_gate, me))), '[]'::jsonb),
    'threads', coalesce((
      select jsonb_agg(jsonb_build_object('id', t.id, 'topic', t.topic, 'title', t.title, 'reply_count', t.reply_count,
                                          'last_activity_at', t.last_activity_at, 'resolved', t.resolved_at is not null)
                       order by t.pinned desc, t.last_activity_at desc)
      from gf_board_threads t where t.id in (select gf_peek_thread_ids(p_gate, me))), '[]'::jsonb),
    'thread_count', (select count(*) from gf_board_threads t
                     where t.gate_id = p_gate and t.deleted_at is null and not gf_blocked(me, t.author)));
end $$;
revoke all on function public.gf_gate_peek(uuid) from public, anon;
grant execute on function public.gf_gate_peek(uuid) to authenticated;
