-- Enforce a rolling 24-hour cooldown between daily claims per authenticated account.
-- Apply this migration in the Supabase SQL Editor after committing the frontend update.

create or replace function public.claim_daily_reward()
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_user_id uuid := auth.uid();
  v_today date := (now() at time zone 'Asia/Dhaka')::date;
  v_claim_id bigint;
  v_profile jsonb;
  v_last_claim_at timestamptz;
  v_now timestamptz := now();
begin
  if v_user_id is null then
    raise exception 'Login required to claim daily reward';
  end if;

  select app_data into v_profile
  from public.profiles
  where id = v_user_id
  for update;

  if v_profile is null then
    raise exception 'Profile not found';
  end if;

  if coalesce((v_profile #>> '{progressData,isActive}')::boolean, false) is not true then
    raise exception 'Account must be active to claim';
  end if;

  if jsonb_typeof(v_profile #> '{progressData,activePackages}') = 'array'
     and jsonb_array_length(v_profile #> '{progressData,activePackages}') > 0 then
    raise exception 'Free daily claim is unavailable while a package is active';
  end if;

  select created_at into v_last_claim_at
  from public.daily_claims
  where user_id = v_user_id
  order by created_at desc
  limit 1;

  if v_last_claim_at is not null
     and v_last_claim_at > v_now - interval '24 hours' then
    return jsonb_build_object(
      'claimed', false,
      'last_claim_at', v_last_claim_at,
      'next_claim_at', v_last_claim_at + interval '24 hours'
    );
  end if;

  insert into public.daily_claims (user_id, claim_date, amount, created_at)
  values (v_user_id, v_today, 20, v_now)
  on conflict (user_id, claim_date) do nothing
  returning id into v_claim_id;

  if v_claim_id is null then
    select created_at into v_last_claim_at
    from public.daily_claims
    where user_id = v_user_id
    order by created_at desc
    limit 1;

    return jsonb_build_object(
      'claimed', false,
      'last_claim_at', v_last_claim_at,
      'next_claim_at', v_last_claim_at + interval '24 hours'
    );
  end if;

  update public.profiles
  set app_data = jsonb_set(
      jsonb_set(
        coalesce(app_data, '{}'::jsonb),
        '{progressData,balance}',
        to_jsonb(coalesce((app_data #>> '{progressData,balance}')::numeric, 0) + 20),
        true
      ),
      '{progressData,totalEarned}',
      to_jsonb(coalesce((app_data #>> '{progressData,totalEarned}')::numeric, 0) + 20),
      true
    ),
    updated_at = v_now
  where id = v_user_id;

  return jsonb_build_object(
    'claimed', true,
    'claim_date', v_today,
    'amount', 20,
    'claimed_at', v_now,
    'next_claim_at', v_now + interval '24 hours'
  );
end;
$$;

revoke all on function public.claim_daily_reward() from public;
grant execute on function public.claim_daily_reward() to authenticated;
