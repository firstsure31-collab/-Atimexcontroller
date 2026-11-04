-- ATIMEX payment-request lookup access for the Admin panel.
-- Run this once in Supabase SQL Editor after confirming payment_requests/admin_users exist.

begin;

-- Keep one payment reference from being submitted more than once (case-insensitive).
-- If this fails because duplicate TrxIDs already exist, inspect those rows before retrying.
create unique index if not exists payment_requests_trx_id_upper_uidx
  on public.payment_requests (upper(btrim(trx_id)));

-- Regular users keep their existing own-row SELECT policy.
-- This additional policy lets only listed Admin users read all requests.
drop policy if exists payment_requests_admin_select on public.payment_requests;
create policy payment_requests_admin_select
  on public.payment_requests
  for select
  to authenticated
  using (
    exists (
      select 1
      from public.admin_users au
      where au.user_id = auth.uid()
    )
  );

grant select on table public.payment_requests to authenticated;
grant select on table public.admin_users to authenticated;

commit;
