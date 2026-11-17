-- 0025 扉を出る（2026-11-18 オーナー「ゲートから出るのが分かりにくい」）
-- 扉の中の画面の「扉を出る」で、自分の入場をその場で終わらせる（GATE を閉じる＝お休みにするのとは別）。
-- 一度開けた GATE なので、出たあとも遠くから読める（0024）。もう一度入るには、現地でまた扉を開ける。
create or replace function public.gf_leave_visit(p_visit uuid) returns void
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  update gf_visits set expires_at = least(expires_at, now())
   where id = p_visit and user_id = me and revoked_at is null;
end $$;

revoke all on function public.gf_leave_visit(uuid) from public, anon;
grant execute on function public.gf_leave_visit(uuid) to authenticated;
