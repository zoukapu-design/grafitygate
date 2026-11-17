-- グラフィティカードの仕上げ（2026-11-18 オーナー「カードっぽい見た目」「キラキラの加工」）。
-- normal＝ふつう、holo＝キラ（虹色の光）、gold＝ゴールド、neon＝ネオン。飾りだけで、見える人・中身は変わらない。
-- 書いた本人だけが、いつでも変えられる（扉の中でなくてよい）。
alter table public.gf_graffiti add column if not exists finish text not null default 'normal';
alter table public.gf_graffiti drop constraint if exists gf_graffiti_finish_check;
alter table public.gf_graffiti add constraint gf_graffiti_finish_check
  check (finish in ('normal', 'holo', 'gold', 'neon'));

create or replace function public.gf_set_card_finish(p_card uuid, p_finish text) returns void
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  if coalesce(p_finish, '') not in ('normal', 'holo', 'gold', 'neon') then
    raise exception 'gf_bad_finish' using errcode = 'P0001';
  end if;
  update gf_graffiti set finish = p_finish where id = p_card and author = me;
  if not found then raise exception 'gf_not_found' using errcode = 'P0001'; end if;
end $$;
revoke all on function public.gf_set_card_finish(uuid, text) from public, anon;
grant execute on function public.gf_set_card_finish(uuid, text) to authenticated;

-- チラ見せにも仕上げを出す（0024 の gf_gate_peek に finish を足したもの）
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
                                          'finish', x.finish)
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
