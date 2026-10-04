-- MEROUANE MOTOCYCLE PRO - Supabase patch
-- Run this AFTER multi_schema.sql. It is safe to run more than once.

-- 1) Allow the app to read the store belonging to the signed-in user.
drop policy if exists stores_same_store on public.stores;
create policy stores_same_store on public.stores
for select to authenticated
using (id = public.my_store_id());

-- 2) Allow a signed-in user to read their own profile, including when disabled,
-- so the app can show the correct disabled-account message.
drop policy if exists profiles_self on public.profiles;
create policy profiles_self on public.profiles
for select to authenticated
using (id = auth.uid());

-- 3) Atomic invoice counter per shop, avoiding duplicate invoice numbers when
-- multiple sellers create invoices at the same time.
create table if not exists public.store_counters (
  store_id uuid primary key references public.stores(id) on delete cascade,
  last_date date not null default current_date,
  last_number integer not null default 0
);
alter table public.store_counters enable row level security;

drop policy if exists store_counters_none on public.store_counters;
create policy store_counters_none on public.store_counters
for all to authenticated using (false) with check (false);

create or replace function public.next_invoice()
returns text
language plpgsql
security definer
set search_path=public
as $$
declare
  st uuid;
  today date := current_date;
  n integer;
  existing_n integer := 0;
begin
  st := public.my_store_id();
  if st is null then raise exception 'الحساب غير مرتبط بمحل'; end if;

  select coalesce(max((regexp_match(invoice,'-([0-9]+)$'))[1]::int),0)
    into existing_n
  from public.sales
  where store_id=st
    and invoice like 'MM-'||to_char(today,'YYMMDD')||'-%';

  insert into public.store_counters(store_id,last_date,last_number)
  values(st,today,existing_n)
  on conflict(store_id) do update
    set last_number = case
      when public.store_counters.last_date = excluded.last_date
        then greatest(public.store_counters.last_number, excluded.last_number)
      else excluded.last_number
    end,
    last_date = excluded.last_date;

  update public.store_counters
     set last_number = last_number + 1,
         last_date = today
   where store_id = st
   returning last_number into n;

  return 'MM-'||to_char(today,'YYMMDD')||'-'||lpad(n::text,4,'0');
end;
$$;

grant execute on function public.next_invoice() to authenticated;

-- 4) Manager can activate/deactivate seller accounts.
create or replace function public.set_user_active(p_user_id uuid, p_active boolean)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  st uuid;
  target_role text;
begin
  if auth.uid() is null then raise exception 'يجب تسجيل الدخول'; end if;
  if public.my_role() <> 'admin' then raise exception 'هذا الإجراء للمدير فقط'; end if;
  st := public.my_store_id();
  if st is null then raise exception 'الحساب غير مرتبط بمحل'; end if;
  if p_user_id = auth.uid() then raise exception 'لا يمكنك تعطيل حساب المدير الحالي'; end if;

  select role into target_role
  from public.profiles
  where id=p_user_id and store_id=st;

  if target_role is null then raise exception 'المستخدم غير موجود في هذا المحل'; end if;
  if target_role <> 'seller' then raise exception 'يمكن للمدير تفعيل أو تعطيل البائعين فقط'; end if;

  update public.profiles
     set active=p_active
   where id=p_user_id and store_id=st;

  return jsonb_build_object('ok',true,'active',p_active);
end;
$$;

grant execute on function public.set_user_active(uuid,boolean) to authenticated;

-- 5) Do not let a disabled seller silently reactivate their own profile by
-- calling the join function again. Joining is for accounts without a profile.
create or replace function public.join_my_store(p_code text, p_full_name text)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare s uuid;
begin
  if auth.uid() is null then raise exception 'يجب تسجيل الدخول'; end if;
  if exists(select 1 from public.profiles where id=auth.uid()) then
    raise exception 'الحساب مرتبط بمحل بالفعل';
  end if;
  select id into s from public.stores where code=upper(trim(p_code));
  if s is null then raise exception 'رمز المحل غير صحيح'; end if;
  insert into public.profiles(id,store_id,full_name,role)
  values(auth.uid(),s,trim(p_full_name),'seller');
  return jsonb_build_object('store_id',s,'role','seller');
end;
$$;

grant execute on function public.join_my_store(text,text) to authenticated;

-- 6) Realtime profile changes so a manager disabling a seller reaches that phone.
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname='supabase_realtime' and schemaname='public' and tablename='profiles'
  ) then
    execute 'alter publication supabase_realtime add table public.profiles';
  end if;
end $$;

-- 7) Keep direct counter access unavailable from the browser.
revoke all on public.store_counters from anon, authenticated;
