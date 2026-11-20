-- ATIMEX bulk member controls: public maintenance status + service-role-only writes.
create table if not exists public.atimex_site_control (
  id integer primary key check (id = 1),
  maintenance_enabled boolean not null default false,
  maintenance_message text not null default 'ATIMEX-এ update চলছে। কিছুক্ষণ পর আবার চেষ্টা করুন।',
  updated_at timestamptz not null default now(),
  updated_by uuid
);

insert into public.atimex_site_control (id, maintenance_enabled, maintenance_message)
values (1, false, 'ATIMEX-এ update চলছে। কিছুক্ষণ পর আবার চেষ্টা করুন।')
on conflict (id) do nothing;

alter table public.atimex_site_control enable row level security;
revoke all on public.atimex_site_control from anon, authenticated;

create or replace function public.get_atimex_site_control()
returns table (maintenance_enabled boolean, maintenance_message text)
language sql
security definer
set search_path = public
stable
as $$
  select c.maintenance_enabled, c.maintenance_message
  from public.atimex_site_control c
  where c.id = 1;
$$;

revoke all on function public.get_atimex_site_control() from public;
grant execute on function public.get_atimex_site_control() to anon, authenticated;
