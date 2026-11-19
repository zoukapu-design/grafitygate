-- 0032：カードの形で見せる所に、カードの名前（title・0029）と仕上げ（finish・0026）を足す（2026-11-20 オーナー「画面をわかりやすく、オシャレに」）。
-- 保存したカード・近くの友達のカード・メッセージで届いたカードを、どこでも同じトレーディングカードの形で見せるため。
-- 見せてよいかの判定は前の関数のまま（その結果に、見えているカードの名前と仕上げを足すだけ）。前の関数は古いアプリ用に残す。
-- 何度実行しても大丈夫。

-- 保存したカード（前の gf_my_saved_cards と同じ行・同じ並び）
create or replace function public.gf_my_saved_cards2()
returns table (id uuid, gate_id uuid, gate_title text, author uuid, author_name text, body text, photo_path text,
               mine boolean, created_at timestamptz, saved_at timestamptz,
               approx_lat double precision, approx_lon double precision, title text, finish text)
language sql stable security definer set search_path = public as $$
  select s.id, s.gate_id, s.gate_title, s.author, s.author_name, s.body, s.photo_path, s.mine, s.created_at, s.saved_at,
         s.approx_lat, s.approx_lon, x.title, x.finish
  from gf_my_saved_cards() with ordinality as s(id, gate_id, gate_title, author, author_name, body, photo_path, mine,
                                                created_at, saved_at, approx_lat, approx_lon, ord)
  join gf_graffiti x on x.id = s.id
  order by s.ord
$$;

-- 近くの友達のカード（前の gf_nearby_cards を呼ぶ＝近くの券・回数の決まりも同じ）
create or replace function public.gf_nearby_cards2(p_lat double precision, p_lon double precision, p_accuracy real)
returns table (id uuid, gate_id uuid, gate_title text, gate_kind text, author uuid, author_name text, body text,
               photo_path text, created_at timestamptz, approx_lat double precision, approx_lon double precision,
               distance_m double precision, title text, finish text)
language sql security definer set search_path = public as $$
  select n.id, n.gate_id, n.gate_title, n.gate_kind, n.author, n.author_name, n.body, n.photo_path, n.created_at,
         n.approx_lat, n.approx_lon, n.distance_m, x.title, x.finish
  from gf_nearby_cards(p_lat, p_lon, p_accuracy) with ordinality
       as n(id, gate_id, gate_title, gate_kind, author, author_name, body, photo_path, created_at,
            approx_lat, approx_lon, distance_m, ord)
  join gf_graffiti x on x.id = n.id
  order by n.ord
$$;

-- メッセージ（カードの中身は、前と同じく送った人が書いた・消していないものだけ。card_id が空なら名前も仕上げも返さない）
create or replace function public.gf_dm_messages_with4(p_other uuid)
returns table (id uuid, sender uuid, body text, photo_path text, created_at timestamptz, read_at timestamptz,
               card_id uuid, card_body text, card_photo text, card_gate_id uuid, card_gate_title text,
               card_created_at timestamptz, card_gone boolean, card_title text, card_finish text)
language sql security definer set search_path = public as $$
  select m.id, m.sender, m.body, m.photo_path, m.created_at, m.read_at,
         m.card_id, m.card_body, m.card_photo, m.card_gate_id, m.card_gate_title, m.card_created_at, m.card_gone,
         x.title, x.finish
  from gf_dm_messages_with3(p_other) with ordinality
       as m(id, sender, body, photo_path, created_at, read_at, card_id, card_body, card_photo, card_gate_id,
            card_gate_title, card_created_at, card_gone, ord)
  left join gf_graffiti x on x.id = m.card_id and m.card_id is not null
  order by m.ord
$$;

-- 友達に見せるカード図鑑（文は返さないまま。名前と仕上げだけ足す）
create or replace function public.gf_user_card_atlas2(p_user uuid)
returns table (id uuid, gate_id uuid, gate_title text, gate_kind text, photo_path text,
               approx_lat double precision, approx_lon double precision, created_at timestamptz,
               title text, finish text)
language sql stable security definer set search_path = public as $$
  select a.id, a.gate_id, a.gate_title, a.gate_kind, a.photo_path, a.approx_lat, a.approx_lon, a.created_at,
         x.title, x.finish
  from gf_user_card_atlas(p_user) with ordinality
       as a(id, gate_id, gate_title, gate_kind, photo_path, approx_lat, approx_lon, created_at, ord)
  join gf_graffiti x on x.id = a.id
  order by a.ord
$$;

do $$
declare f text;
begin
  foreach f in array array[
    'gf_my_saved_cards2()', 'gf_nearby_cards2(double precision, double precision, real)', 'gf_dm_messages_with4(uuid)',
    'gf_user_card_atlas2(uuid)']
  loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;
