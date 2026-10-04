-- MEROUANE MOTOCYCLE PRO - Supabase schema
create extension if not exists pgcrypto;

create table if not exists public.stores (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  code text not null unique,
  created_at timestamptz not null default now()
);

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  store_id uuid references public.stores(id) on delete cascade,
  full_name text not null default '',
  role text not null default 'seller' check (role in ('admin','seller')),
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.products (
  id uuid primary key default gen_random_uuid(),
  store_id uuid not null references public.stores(id) on delete cascade,
  name text not null,
  ref text not null default '',
  buy_price numeric(12,2) not null default 0,
  price numeric(12,2) not null default 0,
  qty integer not null default 0,
  min_qty integer not null default 0,
  image text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.customers (
  id uuid primary key default gen_random_uuid(),
  store_id uuid not null references public.stores(id) on delete cascade,
  name text not null,
  phone text not null default '',
  created_at timestamptz not null default now()
);

create table if not exists public.sales (
  id uuid primary key default gen_random_uuid(),
  store_id uuid not null references public.stores(id) on delete cascade,
  invoice text not null,
  customer text not null default '',
  notes text not null default '',
  total numeric(12,2) not null default 0,
  sold_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  unique(store_id, invoice)
);

create table if not exists public.sale_items (
  id uuid primary key default gen_random_uuid(),
  sale_id uuid not null references public.sales(id) on delete cascade,
  product_id uuid references public.products(id) on delete set null,
  name text not null,
  ref text not null default '',
  qty integer not null check(qty > 0),
  price numeric(12,2) not null default 0,
  original_price numeric(12,2) not null default 0
);

create index if not exists products_store_idx on public.products(store_id);
create index if not exists customers_store_idx on public.customers(store_id);
create index if not exists sales_store_idx on public.sales(store_id, created_at desc);
create index if not exists sale_items_sale_idx on public.sale_items(sale_id);

create or replace function public.my_store_id() returns uuid
language sql stable security definer set search_path=public as $$
  select store_id from public.profiles where id=auth.uid() and active=true limit 1;
$$;

create or replace function public.my_role() returns text
language sql stable security definer set search_path=public as $$
  select role from public.profiles where id=auth.uid() and active=true limit 1;
$$;

create or replace function public.create_my_store(p_name text, p_code text, p_full_name text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare s uuid;
begin
  if auth.uid() is null then raise exception 'يجب تسجيل الدخول'; end if;
  if exists(select 1 from public.profiles where id=auth.uid()) then raise exception 'الحساب مرتبط بمحل بالفعل'; end if;
  if length(trim(p_code)) < 4 then raise exception 'رمز المحل يجب أن يكون 4 أحرف أو أكثر'; end if;
  if exists(select 1 from public.stores where code=upper(trim(p_code))) then raise exception 'رمز المحل مستعمل'; end if;
  insert into public.stores(name,code) values(trim(p_name),upper(trim(p_code))) returning id into s;
  insert into public.profiles(id,store_id,full_name,role) values(auth.uid(),s,trim(p_full_name),'admin');
  return jsonb_build_object('store_id',s,'role','admin');
end; $$;

create or replace function public.join_my_store(p_code text, p_full_name text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare s uuid;
begin
  if auth.uid() is null then raise exception 'يجب تسجيل الدخول'; end if;
  select id into s from public.stores where code=upper(trim(p_code));
  if s is null then raise exception 'رمز المحل غير صحيح'; end if;
  insert into public.profiles(id,store_id,full_name,role) values(auth.uid(),s,trim(p_full_name),'seller')
  on conflict(id) do update set store_id=excluded.store_id, full_name=excluded.full_name, active=true;
  return jsonb_build_object('store_id',s,'role','seller');
end; $$;

create or replace function public.next_invoice()
returns text language plpgsql security definer set search_path=public as $$
declare base text; n integer;
begin
  base := to_char(now(),'YYMMDD');
  select coalesce(max((regexp_match(invoice,'-([0-9]+)$'))[1]::int),0)+1 into n from public.sales where store_id=public.my_store_id() and invoice like 'MM-'||base||'-%';
  return 'MM-'||base||'-'||lpad(n::text,4,'0');
end; $$;

create or replace function public.create_sale(p_customer text, p_notes text, p_items jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare sid uuid; st uuid; it jsonb; pid uuid; want_qty int; unit numeric; orig numeric; p record; total numeric:=0; inv text;
begin
  st:=public.my_store_id(); if st is null then raise exception 'الحساب غير مرتبط بمحل'; end if;
  if jsonb_array_length(p_items)=0 then raise exception 'أضف سلعة واحدة على الأقل'; end if;
  inv:=public.next_invoice();
  insert into public.sales(store_id,invoice,customer,notes,total,sold_by) values(st,inv,coalesce(p_customer,''),coalesce(p_notes,''),0,auth.uid()) returning id into sid;
  for it in select * from jsonb_array_elements(p_items) loop
    pid:=(it->>'product_id')::uuid; want_qty:=greatest(1,(it->>'qty')::int); unit:=coalesce((it->>'unit_price')::numeric,0);
    select * into p from public.products where id=pid and store_id=st for update;
    if not found then raise exception 'المنتج غير موجود'; end if;
    if want_qty>p.qty then raise exception 'الكمية غير متوفرة للمنتج: %',p.name; end if;
    if unit<=0 or unit>p.price then raise exception 'سعر البيع غير صالح للمنتج: %',p.name; end if;
    orig:=p.price;
    update public.products set qty=qty-want_qty, updated_at=now() where id=pid;
    insert into public.sale_items(sale_id,product_id,name,ref,qty,price,original_price) values(sid,pid,p.name,p.ref,want_qty,unit,orig);
    total:=total+(want_qty*unit);
  end loop;
  update public.sales set total=total where id=sid;
  return jsonb_build_object('id',sid,'invoice',inv,'total',total);
exception when others then
  raise;
end; $$;

create or replace function public.return_sale(p_sale_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare st uuid; it record; p record;
begin
  st:=public.my_store_id();
  if not exists(select 1 from public.sales where id=p_sale_id and store_id=st) then raise exception 'الفاتورة غير موجودة'; end if;
  for it in select * from public.sale_items where sale_id=p_sale_id loop
    if it.product_id is not null then
      update public.products set qty=qty+it.qty, updated_at=now() where id=it.product_id and store_id=st;
    end if;
  end loop;
  delete from public.sales where id=p_sale_id and store_id=st;
  return jsonb_build_object('ok',true);
end; $$;

-- RLS
alter table public.stores enable row level security;
alter table public.profiles enable row level security;
alter table public.products enable row level security;
alter table public.customers enable row level security;
alter table public.sales enable row level security;
alter table public.sale_items enable row level security;

drop policy if exists profiles_same_store on public.profiles;
create policy profiles_same_store on public.profiles for select to authenticated using (store_id=public.my_store_id());
drop policy if exists products_same_store on public.products;
create policy products_same_store on public.products for all to authenticated using (store_id=public.my_store_id()) with check (store_id=public.my_store_id());
drop policy if exists customers_same_store on public.customers;
create policy customers_same_store on public.customers for all to authenticated using (store_id=public.my_store_id()) with check (store_id=public.my_store_id());
drop policy if exists sales_same_store on public.sales;
create policy sales_same_store on public.sales for select to authenticated using (store_id=public.my_store_id());
drop policy if exists sale_items_same_store on public.sale_items;
create policy sale_items_same_store on public.sale_items for select to authenticated using (exists(select 1 from public.sales s where s.id=sale_id and s.store_id=public.my_store_id()));

grant usage on schema public to authenticated;
grant select,insert,update,delete on public.products,public.customers to authenticated;
grant select on public.profiles,public.sales,public.sale_items to authenticated;
grant execute on function public.my_store_id(),public.my_role(),public.create_my_store(text,text,text),public.join_my_store(text,text),public.next_invoice(),public.create_sale(text,text,jsonb),public.return_sale(uuid) to authenticated;

-- Realtime
alter publication supabase_realtime add table public.products;
alter publication supabase_realtime add table public.customers;
alter publication supabase_realtime add table public.sales;
alter publication supabase_realtime add table public.sale_items;
