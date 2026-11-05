-- Enforce one free daily claim per Supabase account per Bangladesh calendar day.
-- Apply this migration in the Supabase SQL Editor for the connected project.

begin;

create table if not exists public.daily_claims (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  claim_date date not null,
  amount numeric(12,2) not null default 20,
  created_at timestamptz not null default now(),
  constraint daily_claims_user_date_unique unique (user_id, claim_date)
);

alter table public.daily_claims enable row level security;

drop policy if exists daily_claims_select_own on public.daily_claims;
create policy daily_claims_select_own
  on public.daily_claims
  for select
  to authenticated
  using (user_id = auth.uid());

revoke insert, update, delete on public.daily_claims from anon, authenticated;
grant select on public.daily_claims to authenticated;

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

  insert into public.daily_claims (user_id, claim_date, amount)
  values (v_user_id, v_today, 20)
  on conflict (user_id, claim_date) do nothing
  returning id into v_claim_id;

  if v_claim_id is null then
    return jsonb_build_object('claimed', false, 'claim_date', v_today);
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
    updated_at = now()
  where id = v_user_id;

  return jsonb_build_object('claimed', true, 'claim_date', v_today, 'amount', 20);
end;
$$;

revoke all on function public.claim_daily_reward() from public;
grant execute on function public.claim_daily_reward() to authenticated;

commit;
