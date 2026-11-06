-- Read the authenticated user's latest daily claim timestamp for the UI countdown.
create or replace function public.get_daily_claim_status()
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_user_id uuid := auth.uid();
  v_last_claim_at timestamptz;
begin
  if v_user_id is null then
    raise exception 'Login required';
  end if;

  select created_at
    into v_last_claim_at
  from public.daily_claims
  where user_id = v_user_id
  order by created_at desc
  limit 1;

  return jsonb_build_object(
    'last_claim_at', v_last_claim_at,
    'next_claim_at', case
      when v_last_claim_at is null then null
      else v_last_claim_at + interval '24 hours'
    end,
    'can_claim', v_last_claim_at is null
      or v_last_claim_at <= now() - interval '24 hours'
  );
end;
$$;

revoke all on function public.get_daily_claim_status() from public;
grant execute on function public.get_daily_claim_status() to authenticated;
