-- 0033：写真で GATE を開けやすくする（2026-11-21 オーナー「画像の認識精度悪い？もっと簡単に認識してほしい」）
--
-- 前は、「ここで開く」を押した瞬間の 1 コマ・1 枚の絵の特徴だけで判定していた。作った人より少し遠く・近く・ななめから
-- 写すと、同じ物でも距離が大きくなり「写したものが合いませんでした」になりやすかった。
--
-- ・アプリは 1 回の「ここで開く」で、数コマ × いくつかの切り抜き（全体・まん中・下寄りなど）の特徴をまとめて送る（12 まで）。
--   サーバーは、送られた特徴と見本の特徴のすべての組み合わせのうち、いちばん近いもので判定する（gf_enter2）。
--   作るときも、アプリは正面などの写真の「まん中の切り抜き」の特徴を見本に足す（gf_create_gate はそのまま。8 つまで）。
-- ・同じ GATE かどうかのしきい値 match_max_distance を 0.75 → 0.8 に（前の値のままのときだけ。オーナーが変えた値は残す）。
--   位置（120m 以内・精度 35m）・合言葉（90 秒・1 回）の決まりは変えない（GPS だけ・写真だけでは入れないまま）。
-- ・距離の数字はアプリに返さない（前と同じ）。何枚送ったかは gf_enter_attempts.prints に残す（しきい値を決め直すため）。
-- ・前の gf_enter・gf_match_candidates は、1 枚だけ送る形として gf_enter2・gf_match_candidates2 に渡す（古いアプリ用）。

alter table public.gf_enter_attempts add column if not exists prints smallint;

update public.gf_settings set value = 0.8,
  note = '写真の特徴の距離がこれ以下なら同じ対象とみなす（0033 で 0.75 → 0.8。送られた何枚かの特徴のいちばん近いもので判定。現場の記録 gf_enter_attempts を見て決め直す）'
where key = 'match_max_distance' and value = 0.75;

-- 送られた特徴（[[数...], [数...]]）を 1 つずつの real[] にする。12 より多いときは断る。
-- 配列でないもの・空のものは飛ばす（何も残らなければ、見本と比べられない＝前と同じ no_reference）。
create or replace function public.gf_parse_prints(p_prints jsonb)
returns table (print real[])
language plpgsql immutable set search_path = public as $$
declare e jsonb;
begin
  if p_prints is null or jsonb_typeof(p_prints) <> 'array' then return; end if;
  if jsonb_array_length(p_prints) > 12 then
    raise exception 'gf_bad_prints' using errcode = 'P0001';
  end if;
  for e in select value from jsonb_array_elements(p_prints) loop
    if jsonb_typeof(e) = 'array' and jsonb_array_length(e) between 1 and 4096 then
      print := array(select x::real from jsonb_array_elements_text(e) as t(x));
      return next;
    end if;
  end loop;
end $$;

-- GATE に入る（いくつかの特徴をまとめて送る形）。決まりは前の gf_enter と同じ：
-- 合言葉・位置（120m・精度）・写真の特徴の一致がそろえば、入場券を出す。合わなかった理由も返す（試みの記録を残すため）。
create or replace function public.gf_enter2(
  p_gate uuid, p_challenge uuid, p_lat double precision, p_lon double precision, p_accuracy real,
  p_prints jsonb, p_print_rev int)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  why text;
  g gf_gates;
  dist double precision;
  best double precision;
  vid uuid;
  vexp timestamptz;
  sent int;
begin
  if me is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  -- 送りすぎは、合言葉を使う前に断る
  if jsonb_typeof(p_prints) = 'array' and jsonb_array_length(p_prints) > 12 then
    raise exception 'gf_bad_prints' using errcode = 'P0001';
  end if;
  sent := case when jsonb_typeof(p_prints) = 'array' then jsonb_array_length(p_prints) else 0 end;

  why := gf_use_challenge(p_challenge);
  if why is null then
    select * into g from gf_gates where id = p_gate;
    -- 見てはいけない GATE は「ない」ものとして扱う（あるかどうかも知らせない）
    if not found or not gf_can_see_gate(g, me) then
      why := 'not_found';
    elsif not gf_valid_position(p_lat, p_lon) then
      why := 'bad_position';
    elsif p_accuracy is null or p_accuracy < 0 or p_accuracy > gf_setting('max_accuracy_m') then
      why := 'inaccurate';
    else
      dist := gf_distance_m(p_lat, p_lon, g.lat, g.lon);
      if dist > gf_setting('enter_radius_m') then
        why := 'too_far';
      else
        -- 送られた特徴と見本のすべての組み合わせのうち、いちばん近いもの
        select min(gf_print_distance(pp.print, r.print)) into best
        from gf_parse_prints(p_prints) pp
        join gf_gate_refs r on r.gate_id = g.id and r.print_rev = p_print_rev;
        if best is null then
          why := 'no_reference';
        elsif best > gf_setting('match_max_distance') then
          why := 'no_match';
        end if;
      end if;
    end if;
  end if;

  insert into gf_enter_attempts (gate_id, user_id, result, distance_m, accuracy_m, match_distance, print_rev, prints)
  values (case when why = 'not_found' or g.id is null then null else g.id end, me,
          coalesce(why, 'ok'), dist, p_accuracy, best, p_print_rev, sent);

  if why is not null then
    return jsonb_build_object('ok', false, 'reason', why);
  end if;

  insert into gf_visits (gate_id, user_id, challenge_id, expires_at, distance_m, accuracy_m, match_distance)
  values (g.id, me, p_challenge, now() + make_interval(mins => gf_setting('visit_minutes')::int),
          dist, p_accuracy, best)
  returning id, expires_at into vid, vexp;
  return jsonb_build_object('ok', true, 'visit_id', vid, 'expires_at', vexp);
end $$;

-- 前の形（1 枚だけ）。古いアプリ用に残し、gf_enter2 に渡す
create or replace function public.gf_enter(
  p_gate uuid, p_challenge uuid, p_lat double precision, p_lon double precision, p_accuracy real,
  p_print real[], p_print_rev int)
returns jsonb
language sql security definer set search_path = public as $$
  select gf_enter2(p_gate, p_challenge, p_lat, p_lon, p_accuracy,
                   case when p_print is null then '[]'::jsonb else jsonb_build_array(to_jsonb(p_print)) end,
                   p_print_rev)
$$;

-- 写真の特徴が近い、周りの GATE の候補（いくつかの特徴をまとめて送る形）。距離の数字は返さない
create or replace function public.gf_match_candidates2(p_lat double precision, p_lon double precision,
                                                       p_prints jsonb, p_print_rev int)
returns table (id uuid, title text, owner_name text, distance_m real, cover_path text, similarity text)
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  if jsonb_typeof(p_prints) = 'array' and jsonb_array_length(p_prints) > 12 then
    raise exception 'gf_bad_prints' using errcode = 'P0001';
  end if;
  perform gf_take_rate('discover', gf_setting('discover_per_10min'), 600);
  return query
    with near as (select * from gf_discover(p_lat, p_lon)),
         prints as (select pp.print from gf_parse_prints(p_prints) pp),
         best as (
           select n.id, min(gf_print_distance(p.print, r.print)) as d
           from near n
           left join gf_gate_refs r on r.gate_id = n.id and r.print_rev = p_print_rev
           left join prints p on true
           group by n.id)
    select n.id, n.title, n.owner_name, n.distance_m, n.cover_path,
           case when b.d is null then 'unknown'
                when b.d <= gf_setting('match_max_distance') then 'strong'
                when b.d <= gf_setting('match_weak_distance') then 'weak'
                else 'none' end
    from near n join best b on b.id = n.id
    order by b.d nulls last, n.distance_m;
end $$;

-- 前の形（1 枚だけ）。古いアプリ用に残し、gf_match_candidates2 に渡す
create or replace function public.gf_match_candidates(p_lat double precision, p_lon double precision,
                                                      p_print real[], p_print_rev int)
returns table (id uuid, title text, owner_name text, distance_m real, cover_path text, similarity text)
language plpgsql security definer set search_path = public as $$
begin
  return query select * from gf_match_candidates2(p_lat, p_lon,
    case when p_print is null then '[]'::jsonb else jsonb_build_array(to_jsonb(p_print)) end, p_print_rev);
end $$;

revoke all on function public.gf_parse_prints(jsonb) from public, anon, authenticated;
revoke all on function public.gf_enter2(uuid, uuid, double precision, double precision, real, jsonb, int) from public, anon;
grant execute on function public.gf_enter2(uuid, uuid, double precision, double precision, real, jsonb, int) to authenticated;
revoke all on function public.gf_match_candidates2(double precision, double precision, jsonb, int) from public, anon;
grant execute on function public.gf_match_candidates2(double precision, double precision, jsonb, int) to authenticated;
