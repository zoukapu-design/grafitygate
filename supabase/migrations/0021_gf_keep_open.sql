-- 0021：扉は、その場にいるあいだ開いたまま（オーナー 2026-11-15）。
-- 扉を開けると、はじめは visit_minutes（20 分）開く。アプリが「いまの位置」を送るたびに、GATE から 150m 以内で
-- 位置が確か（65m 以内）なら、そこから 5 分先まで延びる。はっきり離れたら（150m＋位置の確かさ＋50m より遠い）2 分で閉じる。
-- アプリが閉じられていて位置が届かないときは、最後に延びた時刻で閉じる。中が見られるのは、その場にいるあいだだけのまま。
-- 何度実行しても大丈夫な書き方。

insert into public.gf_settings (key, value, note) values
  ('keep_open_radius_m', 150, 'その場にいるあいだ扉を開けておく距離（m）'),
  ('keep_open_accuracy_m', 65, '扉を開けておくのに使う位置の確かさの上限（m）'),
  ('keep_open_minutes', 5, '近くにいると分かってから扉が開いている時間（分）'),
  ('keep_open_per_hour', 240, '1 時間に「いまの位置」を送れる回数（1 人）')
on conflict (key) do nothing;

-- いまの位置を送って、扉を開けたままにする。返すのは { open, expires_at, near }。
-- near：true＝近くにいて延びた／false＝離れたので閉じかけ／null＝位置が不確かで、そのまま
create or replace function public.gf_keep_open(p_visit uuid, p_lat double precision, p_lon double precision,
                                               p_accuracy real) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  v public.gf_visits;
  g public.gf_gates;
  d double precision;
  e timestamptz;
  r double precision := gf_setting('keep_open_radius_m');
begin
  if me is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  select * into v from gf_visits x where x.id = p_visit and x.user_id = me;
  if v.id is null or v.revoked_at is not null or v.expires_at <= now() then
    return jsonb_build_object('open', false);
  end if;
  if not gf_valid_position(p_lat, p_lon) or p_accuracy is null or p_accuracy < 0 then
    raise exception 'gf_bad_position' using errcode = 'P0001';
  end if;
  perform gf_take_rate('keep_open', gf_setting('keep_open_per_hour'), 3600);
  select * into g from gf_gates x where x.id = v.gate_id;
  -- 閉じた・見えなくなった GATE は、その場で閉じる
  if g.id is null or not gf_can_see_gate(g, me) then
    update gf_visits x set expires_at = now() where x.id = v.id;
    return jsonb_build_object('open', false);
  end if;
  d := gf_distance_m(p_lat, p_lon, g.lat, g.lon);
  if p_accuracy <= gf_setting('keep_open_accuracy_m') and d <= r then
    update gf_visits x
       set expires_at = greatest(x.expires_at, now() + make_interval(mins => gf_setting('keep_open_minutes')::int))
     where x.id = v.id
     returning x.expires_at into e;
    return jsonb_build_object('open', true, 'expires_at', e, 'near', true);
  elsif d > r + greatest(p_accuracy, 30) + 50 then
    update gf_visits x set expires_at = least(x.expires_at, now() + interval '2 minutes')
     where x.id = v.id
     returning x.expires_at into e;
    return jsonb_build_object('open', true, 'expires_at', e, 'near', false);
  end if;
  return jsonb_build_object('open', true, 'expires_at', v.expires_at, 'near', null);
end $$;

revoke all on function public.gf_keep_open(uuid, double precision, double precision, real) from public, anon;
grant execute on function public.gf_keep_open(uuid, double precision, double precision, real) to authenticated;
