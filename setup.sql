-- =====================================================================
-- BrowTech Kumasi – online booking, services, income & appointments (Supabase)
--
-- First time:  SQL Editor → New query → paste everything → change the
--              name and PIN in the LAST line → Run.
-- Updating:    paste the newest version of this file and Run it again.
--              It is safe to run again: people, PINs, prices and all
--              entries are kept.
-- =====================================================================

create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;

-- Private schema: not reachable from the website directly.
-- The website can only call the functions further down.
create schema if not exists browtech;
revoke all on schema browtech from public;

-- ---------- tables ----------
create table if not exists browtech.users (
  id           serial primary key,
  name         text not null unique check (length(btrim(name)) between 1 and 40),
  pin_hash     text not null,
  is_admin     boolean not null default false,
  active       boolean not null default true,
  failed       int not null default 0,
  locked_until timestamptz,
  created_at   timestamptz not null default now()
);

create table if not exists browtech.sessions (
  token      uuid primary key default gen_random_uuid(),
  user_id    int not null references browtech.users(id),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '14 days'
);

-- Price list (admin keeps it up to date). price 0 = no price set yet.
create table if not exists browtech.services (
  id       serial primary key,
  category text not null check (category in ('brows','lashes','nails','tattoo','piercing','pony')),
  name     text not null check (length(btrim(name)) between 1 and 60),
  price    numeric(10,2) not null default 0 check (price >= 0),
  active   boolean not null default true,
  unique (category, name)
);
-- added for online booking (kept if they already exist)
do $$
begin
  if not exists (select 1 from information_schema.columns where table_schema = 'browtech' and table_name = 'services' and column_name = 'duration_min') then
    alter table browtech.services add column duration_min int not null default 60 check (duration_min between 5 and 600);
    -- sensible starting durations for the starter list
    update browtech.services s set duration_min = d.m from (values
      ('Brow shaping',30), ('Brow tint',30), ('Brow lamination',60), ('Microblading',150), ('Microblading touch-up',90),
      ('Classic lash set',120), ('Volume lash set',150), ('Lash refill',90), ('Lash lift',60),
      ('Gel polish',60), ('Acrylic set',90), ('Acrylic refill',60), ('Pedicure',60),
      ('Small tattoo',60), ('Medium tattoo',120), ('Large tattoo',240),
      ('Ear piercing',30), ('Nose piercing',30), ('Belly piercing',30), ('Ponytail',120)) as d(n, m)
     where s.name = d.n;
  end if;
end $$;
alter table browtech.services add column if not exists online boolean not null default true;  -- bookable on the customer page
alter table browtech.services add column if not exists sort_order int;  -- admin's order; empty = after the arranged ones, by name

-- Services done = income. One row per service. Never changed or deleted.
create table if not exists browtech.sales (
  id             bigserial primary key,
  logged_at      timestamptz not null default now(),        -- real time of entry, set by the server
  user_id        int not null references browtech.users(id), -- who entered it
  staff_id       int not null references browtech.users(id), -- who did the service
  entry_date     date not null,                              -- the day it was done
  service_id     int references browtech.services(id),
  category       text not null check (category in ('brows','lashes','nails','tattoo','piercing','pony')),
  service_name   text not null,
  list_price     numeric(10,2),                              -- price-list price at that moment
  amount         numeric(10,2) not null check (amount >= 0 and amount <= 1000000),
  payment        text not null check (payment in ('cash','momo','card','free')),
  customer       text,
  phone          text,
  note           text,
  appointment_id bigint
);

-- Bookings. Never changed or deleted; confirmations, moves and cancellations are added in appt_changes.
create table if not exists browtech.appointments (
  id           bigserial primary key,
  logged_at    timestamptz not null default now(),
  user_id      int references browtech.users(id),           -- null = booked online by the customer
  appt_date    date not null,
  appt_time    time not null,
  service_id   int references browtech.services(id),
  category     text not null check (category in ('brows','lashes','nails','tattoo','piercing','pony')),
  service_name text not null,                               -- several services: "Lash refill + Brow shaping"
  staff_id     int references browtech.users(id),            -- null = anyone
  customer     text not null,
  phone        text,
  note         text
);
alter table browtech.appointments alter column user_id drop not null;
alter table browtech.appointments add column if not exists source text not null default 'staff' check (source in ('staff','online'));
alter table browtech.appointments add column if not exists duration_min int not null default 60;
-- several services in one booking: [{"id":8,"category":"lashes","name":"Lash refill","price":150,"duration_min":90}, ...]
alter table browtech.appointments add column if not exists services jsonb;
alter table browtech.sales drop constraint if exists sales_appt_fk;
alter table browtech.sales add constraint sales_appt_fk foreign key (appointment_id) references browtech.appointments(id);
create index if not exists appointments_date on browtech.appointments(appt_date);

create table if not exists browtech.appt_changes (
  id             bigserial primary key,
  logged_at      timestamptz not null default now(),
  user_id        int not null references browtech.users(id),
  appointment_id bigint not null references browtech.appointments(id),
  action         text not null,
  new_date       date,
  new_time       time,
  new_staff_id   int references browtech.users(id),
  note           text
);
alter table browtech.appt_changes drop constraint if exists appt_changes_action_check;
alter table browtech.appt_changes add constraint appt_changes_action_check check (action in ('confirmed','declined','moved','cancelled','no-show'));
create index if not exists appt_changes_a on browtech.appt_changes(appointment_id);
create index if not exists appt_changes_d on browtech.appt_changes(new_date);

-- Undo marks. The original entry stays; it is shown in red as undone.
create table if not exists browtech.undos (
  id        bigserial primary key,
  logged_at timestamptz not null default now(),
  user_id   int not null references browtech.users(id),
  target    text not null check (target in ('sale','appointment','change')),
  target_id bigint not null,
  reason    text not null check (length(btrim(reason)) between 1 and 300),
  unique (target, target_id)
);

-- Activity log: people added, PINs changed, prices and settings changed, lockouts ...
create table if not exists browtech.events (
  id        bigserial primary key,
  logged_at timestamptz not null default now(),
  user_id   int references browtech.users(id),
  action    text not null,
  details   text
);

-- Raised by tools/clear_test_entries.sql so phones drop their saved copy.
create table if not exists browtech.meta (
  id          int primary key default 1 check (id = 1),
  reset_count int not null default 0
);
insert into browtech.meta(id) values (1) on conflict do nothing;

-- Online booking settings (one row). hours: key = weekday (0 Sunday … 6 Saturday), value = ["09:00","19:00"] or null = closed
create table if not exists browtech.config (
  id               int primary key default 1 check (id = 1),
  online_booking   boolean not null default true,
  slot_minutes     int not null default 30 check (slot_minutes in (15,20,30,45,60)),
  capacity         int not null default 2 check (capacity between 1 and 20),
  days_ahead       int not null default 30 check (days_ahead between 1 and 180),
  min_notice_hours int not null default 2 check (min_notice_hours between 0 and 72),
  contact_phone    text,
  hours            jsonb not null default '{"0":null,"1":["09:00","19:00"],"2":["09:00","19:00"],"3":["09:00","19:00"],"4":["09:00","19:00"],"5":["09:00","19:00"],"6":["09:00","19:00"]}'
);
insert into browtech.config(id) values (1) on conflict do nothing;

-- Starter price list – only on the very first run (prices 0 = not set yet)
do $$
begin
  if not exists (select 1 from browtech.services) then
    insert into browtech.services(category, name, duration_min) values
      ('brows','Brow shaping',30), ('brows','Brow tint',30), ('brows','Brow lamination',60), ('brows','Microblading',150), ('brows','Microblading touch-up',90),
      ('lashes','Classic lash set',120), ('lashes','Volume lash set',150), ('lashes','Lash refill',90), ('lashes','Lash lift',60),
      ('nails','Gel polish',60), ('nails','Acrylic set',90), ('nails','Acrylic refill',60), ('nails','Pedicure',60),
      ('tattoo','Small tattoo',60), ('tattoo','Medium tattoo',120), ('tattoo','Large tattoo',240),
      ('piercing','Ear piercing',30), ('piercing','Nose piercing',30), ('piercing','Belly piercing',30),
      ('pony','Ponytail',120);
  end if;
end $$;

-- ---------- entries are permanent ----------
create or replace function browtech.no_change() returns trigger language plpgsql as $$
begin
  raise exception 'Log entries cannot be changed or deleted';
end $$;

do $$
declare t text;
begin
  foreach t in array array['sales','appointments','appt_changes','undos','events'] loop
    execute format('drop trigger if exists %I on browtech.%I', t || '_locked', t);
    execute format('create trigger %I before update or delete on browtech.%I for each row execute function browtech.no_change()', t || '_locked', t);
    execute format('drop trigger if exists %I on browtech.%I', t || '_no_truncate', t);
    execute format('create trigger %I before truncate on browtech.%I for each statement execute function browtech.no_change()', t || '_no_truncate', t);
  end loop;
end $$;

-- ---------- helpers (private) ----------
create or replace function browtech.me(p_token uuid) returns browtech.users
language plpgsql as $$
declare u browtech.users;
begin
  select u2.* into u
    from browtech.sessions s join browtech.users u2 on u2.id = s.user_id
   where s.token = p_token and s.expires_at > now() and u2.active;
  if not found then raise exception 'NOT_LOGGED_IN'; end if;
  return u;
end $$;

create or replace function browtech.need_admin(u browtech.users) returns void
language plpgsql as $$
begin
  if not u.is_admin then raise exception 'Only an admin can do this'; end if;
end $$;

create or replace function browtech.check_pin(p_pin text) returns void
language plpgsql as $$
begin
  if p_pin is null or p_pin !~ '^[0-9]{6}$' then raise exception 'PIN must be exactly 6 digits'; end if;
end $$;

create or replace function browtech.check_category(c text) returns void
language plpgsql as $$
begin
  if c is null or c not in ('brows','lashes','nails','tattoo','piercing','pony') then raise exception 'Choose a category'; end if;
end $$;

-- "today" and "now" are Ghana time (Africa/Accra), whatever the server's clock zone
create or replace function browtech.today() returns date language sql stable as $$
  select (now() at time zone 'Africa/Accra')::date;
$$;
create or replace function browtech.now_local() returns timestamp language sql stable as $$
  select (now() at time zone 'Africa/Accra');
$$;

create or replace function browtech.check_past_date(d date) returns void
language plpgsql as $$
begin
  if d is null then raise exception 'Date is missing'; end if;
  if d > browtech.today() then raise exception 'Date cannot be in the future'; end if;
  if d < date '2020-01-01' then raise exception 'Date is too far in the past'; end if;
end $$;

create or replace function browtech.check_appt_date(d date, t time) returns void
language plpgsql as $$
begin
  if d is null then raise exception 'Choose a date'; end if;
  if t is null then raise exception 'Choose a time'; end if;
  if d < browtech.today() - 7 then raise exception 'That date is in the past'; end if;
  if d > browtech.today() + 400 then raise exception 'That date is too far ahead'; end if;
end $$;

create or replace function browtech.check_staff(p_id int, p_required boolean) returns void
language plpgsql as $$
begin
  if p_id is null then
    if p_required then raise exception 'Choose who did the service'; end if;
    return;
  end if;
  if not exists (select 1 from browtech.users where id = p_id and active) then raise exception 'Unknown staff member'; end if;
end $$;

-- Service picked from the price list, or typed in ("Other").
drop function if exists browtech.pick_service(int, text, text);
create or replace function browtech.pick_service(p_service_id int, p_category text, p_name text,
  out service_id int, out category text, out service_name text, out price numeric, out duration_min int)
language plpgsql as $$
declare s browtech.services;
begin
  if p_service_id is not null then
    select * into s from browtech.services where id = p_service_id;
    if not found then raise exception 'Service not found'; end if;
    service_id := s.id; category := s.category; service_name := s.name; price := nullif(s.price, 0); duration_min := s.duration_min;
  else
    perform browtech.check_category(p_category);
    if p_name is null or btrim(p_name) = '' then raise exception 'Enter the service name'; end if;
    service_id := null; category := p_category; service_name := left(btrim(p_name), 60); price := null; duration_min := 60;
  end if;
end $$;

-- Several services for one booking. p_ids from the price list (max 6), plus optionally one typed-in service.
-- p_public: only services that are bookable online.
create or replace function browtech.pick_services(p_ids int[], p_other_category text, p_other_name text, p_public boolean,
  out services jsonb, out service_id int, out category text, out service_name text, out duration_min int)
language plpgsql as $$
declare ids int[]; s browtech.services; i int; n int := 0;
begin
  ids := array(select distinct x from unnest(coalesce(p_ids, '{}')) x where x is not null);
  services := '[]'::jsonb; duration_min := 0; service_name := '';
  foreach i in array ids loop
    select * into s from browtech.services x where x.id = i and x.active and (not p_public or x.online);
    if not found then raise exception 'A chosen service is not available any more. Please choose again.'; end if;
    services := services || jsonb_build_object('id', s.id, 'category', s.category, 'name', s.name, 'price', s.price, 'duration_min', s.duration_min);
    n := n + 1;
  end loop;
  if not p_public and coalesce(btrim(p_other_name), '') <> '' then
    perform browtech.check_category(p_other_category);
    services := services || jsonb_build_object('id', null, 'category', p_other_category, 'name', left(btrim(p_other_name), 60), 'price', 0, 'duration_min', 60);
    n := n + 1;
  end if;
  if n = 0 then raise exception 'Please choose a service'; end if;
  if n > 6 then raise exception 'Please choose at most 6 services'; end if;
  -- keep the price-list order (category, name) so the same choice always reads the same
  select jsonb_agg(e order by e->>'category' = 'other', e->>'category', e->>'name') into services from jsonb_array_elements(services) e;
  select (services->0->>'id')::int, services->0->>'category',
         string_agg(e->>'name', ' + '), sum((e->>'duration_min')::int)
    into service_id, category, service_name, duration_min
    from jsonb_array_elements(services) e;
  service_name := left(service_name, 300);
end $$;

create or replace function browtech.lock_all() returns void language sql as $$
  select pg_advisory_xact_lock(515151);
$$;

create or replace function browtech.is_undone(p_target text, p_id bigint) returns boolean
language sql stable as $$
  select exists (select 1 from browtech.undos where target = p_target and target_id = p_id);
$$;

-- Where an appointment stands now:
-- requested (online, not answered yet) / booked / done / declined / cancelled / no-show / undone
create or replace function browtech.appt_now(p_id bigint,
  out status text, out appt_date date, out appt_time time, out staff_id int)
language plpgsql stable as $$
declare a browtech.appointments; c record;
begin
  select * into a from browtech.appointments where id = p_id;
  if not found then raise exception 'Appointment not found'; end if;
  appt_date := a.appt_date; appt_time := a.appt_time; staff_id := a.staff_id;
  status := case when a.source = 'online' then 'requested' else 'booked' end;
  if browtech.is_undone('appointment', p_id) then status := 'undone'; return; end if;
  for c in select x.* from browtech.appt_changes x
            where x.appointment_id = p_id and not browtech.is_undone('change', x.id) order by x.id loop
    if c.action = 'moved' then
      appt_date := c.new_date; appt_time := c.new_time; staff_id := c.new_staff_id; status := 'booked';
    elsif c.action = 'confirmed' then
      status := 'booked';
      if c.new_staff_id is not null then staff_id := c.new_staff_id; end if;
    else
      status := c.action;
    end if;
  end loop;
  if exists (select 1 from browtech.sales s where s.appointment_id = p_id and not browtech.is_undone('sale', s.id)) then
    status := 'done';
  end if;
end $$;

-- Appointments that take up a place on a day (requested, booked or done), in minutes from midnight.
create or replace function browtech.day_load(p_date date, p_exclude bigint)
returns table(start_m int, end_m int)
language sql stable as $$
  select (extract(hour from n.appt_time) * 60 + extract(minute from n.appt_time))::int,
         (extract(hour from n.appt_time) * 60 + extract(minute from n.appt_time))::int + a.duration_min
    from browtech.appointments a
    cross join lateral browtech.appt_now(a.id) n
   where (a.appt_date = p_date or exists (select 1 from browtech.appt_changes c where c.appointment_id = a.id and c.new_date = p_date))
     and a.id is distinct from p_exclude
     and n.appt_date = p_date and n.status in ('requested','booked','done');
$$;

-- Free start times on a day for a service of p_duration minutes, using opening hours and
-- "customers at the same time". p_notice: leave out times sooner than the minimum notice.
create or replace function browtech.free_slots(p_date date, p_duration int, p_notice boolean)
returns setof time
language plpgsql stable as $$
declare cfg browtech.config; h jsonb; o int; cl int; t int; busy int; earliest int := -1; st int[]; en int[]; i int; p int; n int;
begin
  select * into cfg from browtech.config where id = 1;
  h := cfg.hours -> extract(dow from p_date)::int::text;
  if h is null or jsonb_typeof(h) <> 'array' then return; end if;
  o := (split_part(h->>0, ':', 1))::int * 60 + (split_part(h->>0, ':', 2))::int;
  cl := (split_part(h->>1, ':', 1))::int * 60 + (split_part(h->>1, ':', 2))::int;
  if p_date < browtech.today() then return; end if;
  if p_date = browtech.today() then
    earliest := (extract(hour from browtech.now_local()) * 60 + extract(minute from browtech.now_local()))::int
                + case when p_notice then cfg.min_notice_hours * 60 else 0 end;
  elsif p_notice and p_date = browtech.today() + 1 and cfg.min_notice_hours > 0 then
    earliest := (extract(hour from browtech.now_local()) * 60 + extract(minute from browtech.now_local()))::int
                + cfg.min_notice_hours * 60 - 24 * 60;
  end if;
  select coalesce(array_agg(start_m), '{}'), coalesce(array_agg(end_m), '{}') into st, en from browtech.day_load(p_date, null);
  t := o;
  while t + p_duration <= cl loop
    if t >= earliest then
      -- the most customers in the shop at any moment during [t, t + duration):
      -- check at the start and wherever another appointment begins inside it
      busy := 0;
      for p in select x from unnest(array_append(st, t)) x where x >= t and x < t + p_duration loop
        n := 0;
        for i in 1 .. coalesce(array_length(st, 1), 0) loop
          if st[i] <= p and en[i] > p then n := n + 1; end if;
        end loop;
        busy := greatest(busy, n);
      end loop;
      if busy < cfg.capacity then
        return next make_time(t / 60, t % 60, 0);
      end if;
    end if;
    t := t + cfg.slot_minutes;
  end loop;
end $$;

create or replace function browtech.phone_digits(p text) returns text language sql immutable as $$
  select regexp_replace(coalesce(p, ''), '[^0-9]', '', 'g');
$$;

-- Used once below to create the first admin.
create or replace function browtech.create_first_admin(p_name text, p_pin text) returns text
language plpgsql as $$
begin
  if exists (select 1 from browtech.users) then return 'Users already exist – nothing changed. Setup is up to date.'; end if;
  perform browtech.check_pin(p_pin);
  insert into browtech.users(name, pin_hash, is_admin) values (btrim(p_name), extensions.crypt(p_pin, extensions.gen_salt('bf')), true);
  insert into browtech.events(user_id, action, details) values (currval('browtech.users_id_seq'), 'setup', 'First admin created: ' || btrim(p_name));
  return 'Admin ' || btrim(p_name) || ' created';
end $$;

-- =====================================================================
-- Customer booking page (no login)
-- =====================================================================

-- Customers can book the next 3 days the shop is open, starting tomorrow
create or replace function browtech.bookable_days() returns setof date
language sql stable as $$
  select d::date
    from browtech.config c, generate_series((browtech.today() + 1)::timestamp, (browtech.today() + 14)::timestamp, interval '1 day') d
   where c.id = 1 and jsonb_typeof(c.hours -> extract(dow from d)::int::text) = 'array'
   order by d limit 3;
$$;

-- Staff can book today if the shop is open, and the same next 3 open days
create or replace function browtech.staff_days() returns setof date
language sql stable as $$
  select browtech.today() from browtech.config c
   where c.id = 1 and jsonb_typeof(c.hours -> extract(dow from browtech.today())::int::text) = 'array'
  union all
  select browtech.bookable_days();
$$;

-- Services, prices and opening hours for the booking page
create or replace function public.public_info() returns json
language sql stable security definer set search_path = browtech, public as $$
  select json_build_object(
    'online_booking', c.online_booking, 'contact_phone', c.contact_phone, 'days_ahead', c.days_ahead,
    'hours', c.hours, 'today', browtech.today(),
    'services', (select coalesce(json_agg(json_build_object('id', s.id, 'category', s.category, 'name', s.name, 'price', s.price, 'duration_min', s.duration_min) order by s.category, s.sort_order nulls last, s.name), '[]')
                   from browtech.services s where s.active and s.online))
    from browtech.config c where c.id = 1;
$$;

-- Free times for one service on one day
drop function if exists public.public_slots(int, date);
create or replace function public.public_slots(p_service_ids int[], p_date date) returns json
language plpgsql stable security definer set search_path = browtech, public as $$
declare cfg browtech.config; dur int;
begin
  select * into cfg from browtech.config where id = 1;
  if not cfg.online_booking then raise exception 'Online booking is switched off at the moment. Please call us.'; end if;
  select duration_min into dur from browtech.pick_services(p_service_ids, null, null, true);
  if p_date is null or p_date not in (select browtech.bookable_days()) then return '[]'::json; end if;
  return (select coalesce(json_agg(to_char(t, 'HH24:MI') order by t), '[]') from browtech.free_slots(p_date, dur, true) t);
end $$;

-- A customer asks for an appointment. Staff confirm or decline it in the app.
drop function if exists public.public_request(int, date, text, text, text, text, text);
create or replace function public.public_request(p_service_ids int[], p_date date, p_time text, p_name text, p_phone text, p_note text, p_website text default null) returns json
language plpgsql security definer set search_path = browtech, public as $$
declare sv record; cfg browtech.config; t time; digits text; new_id bigint;
begin
  -- a hidden form field only robots fill in: pretend it worked, save nothing
  if coalesce(btrim(p_website), '') <> '' then return json_build_object('ok', true, 'ref', 'B0'); end if;
  select * into cfg from browtech.config where id = 1;
  if not cfg.online_booking then raise exception 'Online booking is switched off at the moment. Please call us.'; end if;
  select * into sv from browtech.pick_services(p_service_ids, null, null, true);
  if p_name is null or length(btrim(p_name)) < 2 then raise exception 'Please enter your name'; end if;
  digits := browtech.phone_digits(p_phone);
  if length(digits) < 9 or length(digits) > 15 then raise exception 'Please enter a phone number we can call or WhatsApp'; end if;
  if p_time is null or p_time !~ '^\d{2}:\d{2}$' then raise exception 'Please choose a time'; end if;
  t := p_time::time;
  if p_date is null or p_date not in (select browtech.bookable_days()) then raise exception 'Please choose another day'; end if;
  perform browtech.lock_all();
  -- limits against mistakes and abuse
  if (select count(*) from browtech.appointments a cross join lateral browtech.appt_now(a.id) n
       where a.source = 'online' and browtech.phone_digits(a.phone) = digits and n.status = 'requested' and n.appt_date >= browtech.today()) >= 3 then
    raise exception 'You already have 3 requests waiting. We will contact you soon.';
  end if;
  if (select count(*) from browtech.appointments where source = 'online' and logged_at > now() - interval '1 hour') >= 40 then
    raise exception 'Too many requests right now. Please try again later or call us.';
  end if;
  if not exists (select 1 from browtech.free_slots(p_date, sv.duration_min, true) f where f = t) then
    raise exception 'Sorry, % is no longer free. Please choose another time.', p_time;
  end if;
  insert into browtech.appointments(user_id, source, appt_date, appt_time, service_id, category, service_name, staff_id, customer, phone, note, duration_min, services)
  values (null, 'online', p_date, t, sv.service_id, sv.category, sv.service_name, null, left(btrim(p_name), 80), left(btrim(p_phone), 30), nullif(left(btrim(p_note), 300), ''), sv.duration_min, sv.services)
  returning id into new_id;
  return json_build_object('ok', true, 'ref', 'B' || new_id);
end $$;

-- =====================================================================
-- Staff functions (need a login)
-- =====================================================================

-- Names for the login screen
create or replace function public.list_users() returns json
language sql stable security definer set search_path = browtech, public as $$
  select coalesce(json_agg(json_build_object('id', id, 'name', name) order by name), '[]'::json)
    from browtech.users where active;
$$;

-- Log in with PIN. 5 wrong PINs → that person is locked for 15 minutes.
-- (Returns an error message instead of raising, so the failed-try counter is kept.)
create or replace function public.login(p_user_id int, p_pin text) returns json
language plpgsql security definer set search_path = browtech, public as $$
declare u browtech.users; t uuid;
begin
  select * into u from browtech.users where id = p_user_id and active;
  if not found then return json_build_object('ok', false, 'error', 'Unknown user'); end if;
  if u.locked_until is not null and u.locked_until > now() then
    return json_build_object('ok', false, 'error', 'Too many wrong PINs. Locked for ' ||
      greatest(1, ceil(extract(epoch from (u.locked_until - now())) / 60))::int || ' more minute(s).');
  end if;
  if p_pin is null or u.pin_hash <> extensions.crypt(p_pin, u.pin_hash) then
    if u.failed + 1 >= 5 then
      update browtech.users set failed = 0, locked_until = now() + interval '15 minutes' where id = u.id;
      insert into browtech.events(user_id, action, details) values (u.id, 'locked', '5 wrong PINs – locked for 15 minutes');
      return json_build_object('ok', false, 'error', 'Wrong PIN. Too many tries – locked for 15 minutes.');
    end if;
    update browtech.users set failed = failed + 1 where id = u.id;
    return json_build_object('ok', false, 'error', 'Wrong PIN (' || (4 - u.failed) || case when u.failed = 3 then ' try' else ' tries' end || ' left)');
  end if;
  update browtech.users set failed = 0, locked_until = null where id = u.id;
  delete from browtech.sessions where expires_at < now();
  insert into browtech.sessions(user_id) values (u.id) returning token into t;
  return json_build_object('ok', true, 'token', t, 'user', json_build_object('id', u.id, 'name', u.name, 'is_admin', u.is_admin));
end $$;

create or replace function public.logout(p_token uuid) returns json
language sql security definer set search_path = browtech, public as $$
  delete from browtech.sessions where token = p_token;
  select json_build_object('ok', true);
$$;

-- Everything the app needs. Pass the last ids you already have to get only new rows.
-- Workers get only their own service entries of today (no income of others).
create or replace function public.get_state(p_token uuid, p_after_sale bigint default 0, p_after_appt bigint default 0,
  p_after_change bigint default 0, p_after_undo bigint default 0, p_after_event bigint default 0) returns json
language plpgsql stable security definer set search_path = browtech, public as $$
declare u browtech.users;
begin
  u := browtech.me(p_token);
  return json_build_object(
    'me', json_build_object('id', u.id, 'name', u.name, 'is_admin', u.is_admin),
    'users', (select coalesce(json_agg(json_build_object('id', id, 'name', name, 'is_admin', is_admin, 'active', active) order by id), '[]') from browtech.users),
    'services', (select coalesce(json_agg(s order by s.category, s.sort_order nulls last, s.name), '[]') from browtech.services s),
    'config', (select row_to_json(c) from browtech.config c where c.id = 1),
    'sales', (select coalesce(json_agg(x order by x.id), '[]') from browtech.sales x
               where x.id > coalesce(p_after_sale, 0) and (u.is_admin or (x.user_id = u.id and x.entry_date = browtech.today()))),
    'appt_done', case when u.is_admin then '[]'::json else
               (select coalesce(json_agg(json_build_object('id', x.id, 'appointment_id', x.appointment_id, 'staff_id', x.staff_id)), '[]') from browtech.sales x
                 where x.appointment_id is not null and not browtech.is_undone('sale', x.id)) end,
    'appointments', (select coalesce(json_agg(x order by x.id), '[]') from browtech.appointments x where x.id > coalesce(p_after_appt, 0)),
    'changes', (select coalesce(json_agg(x order by x.id), '[]') from browtech.appt_changes x where x.id > coalesce(p_after_change, 0)),
    'undos', (select coalesce(json_agg(x order by x.id), '[]') from browtech.undos x where x.id > coalesce(p_after_undo, 0)),
    'events', case when u.is_admin then (select coalesce(json_agg(e order by e.id), '[]') from browtech.events e where e.id > coalesce(p_after_event, 0)) else '[]'::json end,
    'reset_count', (select reset_count from browtech.meta where id = 1),
    'server_time', now()
  );
end $$;

-- Free times for staff booking (opening hours and places; no minimum notice, no booking window)
drop function if exists public.staff_slots(uuid, int, date);
create or replace function public.staff_slots(p_token uuid, p_service_ids int[], p_date date, p_extra_min int default 0) returns json
language plpgsql stable security definer set search_path = browtech, public as $$
declare u browtech.users; d int;
begin
  u := browtech.me(p_token);
  select coalesce(sum(duration_min), 0) into d from browtech.services where id = any(coalesce(p_service_ids, '{}'));
  d := d + greatest(coalesce(p_extra_min, 0), 0);
  if d = 0 then d := 60; end if;
  return (select coalesce(json_agg(to_char(t, 'HH24:MI') order by t), '[]') from browtech.free_slots(p_date, d, false) t);
end $$;

-- A service was done (with or without a booking).
create or replace function public.add_sale(p_token uuid, p_service_id int, p_category text, p_name text, p_amount numeric,
  p_payment text, p_staff_id int, p_date date, p_customer text, p_phone text, p_note text, p_appointment_id bigint) returns json
language plpgsql security definer set search_path = browtech, public as $$
declare u browtech.users; s record; a record; new_id bigint; pay text;
begin
  u := browtech.me(p_token);
  select * into s from browtech.pick_service(p_service_id, p_category, p_name);
  perform browtech.check_past_date(p_date);
  if not u.is_admin and p_date <> browtech.today() then raise exception 'Only an admin can enter services for another day'; end if;
  perform browtech.check_staff(p_staff_id, true);
  if p_amount is null or p_amount < 0 or p_amount > 1000000 then raise exception 'Enter the amount paid'; end if;
  pay := case when p_amount = 0 then 'free' else p_payment end;
  if pay is null or pay not in ('cash','momo','card','free') then raise exception 'Choose how the customer paid'; end if;
  perform browtech.lock_all();
  if p_appointment_id is not null then
    select * into a from browtech.appt_now(p_appointment_id);
    if a.status = 'done' then raise exception 'This appointment is already marked as done'; end if;
    if a.status not in ('booked','requested') then raise exception 'This appointment is %', a.status; end if;
  end if;
  insert into browtech.sales(user_id, staff_id, entry_date, service_id, category, service_name, list_price, amount, payment, customer, phone, note, appointment_id)
  values (u.id, p_staff_id, p_date, s.service_id, s.category, s.service_name, s.price, round(p_amount, 2), pay,
          nullif(left(btrim(p_customer), 80), ''), nullif(left(btrim(p_phone), 30), ''), nullif(left(btrim(p_note), 300), ''), p_appointment_id)
  returning id into new_id;
  return json_build_object('ok', true, 'id', new_id);
end $$;

-- Several services done for one customer at once (e.g. brows + lashes), one entry per service.
-- p_items: [{"service_id": 8 | null, "category": "...", "name": "...", "amount": 150, "staff_id": 2}, ...]
create or replace function public.add_sales(p_token uuid, p_items jsonb, p_payment text, p_date date,
  p_customer text, p_phone text, p_note text, p_appointment_id bigint) returns json
language plpgsql security definer set search_path = browtech, public as $$
declare u browtech.users; it jsonb; s record; a record; amt numeric; pay text; staff int; ids bigint[] := '{}'; new_id bigint;
begin
  u := browtech.me(p_token);
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then raise exception 'Choose a service'; end if;
  if jsonb_array_length(p_items) > 10 then raise exception 'At most 10 services at once'; end if;
  perform browtech.check_past_date(p_date);
  if not u.is_admin and p_date <> browtech.today() then raise exception 'Only an admin can enter services for another day'; end if;
  perform browtech.lock_all();
  if p_appointment_id is not null then
    select * into a from browtech.appt_now(p_appointment_id);
    if a.status = 'done' then raise exception 'This appointment is already marked as done'; end if;
    if a.status not in ('booked','requested') then raise exception 'This appointment is %', a.status; end if;
  end if;
  for it in select * from jsonb_array_elements(p_items) loop
    select * into s from browtech.pick_service(nullif(it->>'service_id', '')::int, it->>'category', it->>'name');
    begin amt := (it->>'amount')::numeric; exception when others then raise exception 'Enter the amount for %', s.service_name; end;
    if amt is null or amt < 0 or amt > 1000000 then raise exception 'Enter the amount for %', s.service_name; end if;
    staff := nullif(it->>'staff_id', '')::int;
    perform browtech.check_staff(staff, true);
    pay := case when amt = 0 then 'free' else p_payment end;
    if pay is null or pay not in ('cash','momo','card','free') then raise exception 'Choose how the customer paid'; end if;
    insert into browtech.sales(user_id, staff_id, entry_date, service_id, category, service_name, list_price, amount, payment, customer, phone, note, appointment_id)
    values (u.id, staff, p_date, s.service_id, s.category, s.service_name, s.price, round(amt, 2), pay,
            nullif(left(btrim(p_customer), 80), ''), nullif(left(btrim(p_phone), 30), ''), nullif(left(btrim(p_note), 300), ''), p_appointment_id)
    returning id into new_id;
    ids := ids || new_id;
  end loop;
  return json_build_object('ok', true, 'ids', to_json(ids));
end $$;

drop function if exists public.book_appointment(uuid, int, text, text, date, time, int, text, text, text);
create or replace function public.book_appointment(p_token uuid, p_service_ids int[], p_other_category text, p_other_name text,
  p_date date, p_time time, p_staff_id int, p_customer text, p_phone text, p_note text) returns json
language plpgsql security definer set search_path = browtech, public as $$
declare u browtech.users; sv record; new_id bigint;
begin
  u := browtech.me(p_token);
  select * into sv from browtech.pick_services(p_service_ids, p_other_category, p_other_name, false);
  perform browtech.check_appt_date(p_date, p_time);
  if p_date not in (select browtech.staff_days()) then raise exception 'Appointments can only be for today and the next 3 working days'; end if;
  perform browtech.check_staff(p_staff_id, false);
  if p_customer is null or btrim(p_customer) = '' then raise exception 'Enter the customer''s name'; end if;
  insert into browtech.appointments(user_id, source, appt_date, appt_time, service_id, category, service_name, staff_id, customer, phone, note, duration_min, services)
  values (u.id, 'staff', p_date, p_time, sv.service_id, sv.category, sv.service_name, p_staff_id,
          left(btrim(p_customer), 80), nullif(left(btrim(p_phone), 30), ''), nullif(left(btrim(p_note), 300), ''), sv.duration_min, sv.services)
  returning id into new_id;
  return json_build_object('ok', true, 'id', new_id);
end $$;

-- Confirm / decline an online request, move, cancel or mark no-show.
-- p_action: 'confirmed' | 'declined' | 'moved' | 'cancelled' | 'no-show'
create or replace function public.change_appointment(p_token uuid, p_id bigint, p_action text, p_date date, p_time time, p_staff_id int, p_note text) returns json
language plpgsql security definer set search_path = browtech, public as $$
declare u browtech.users; a record; new_id bigint;
begin
  u := browtech.me(p_token);
  if p_action is null or p_action not in ('confirmed','declined','moved','cancelled','no-show') then raise exception 'Unknown change'; end if;
  perform browtech.lock_all();
  select * into a from browtech.appt_now(p_id);
  if a.status not in ('booked','requested') then raise exception 'This appointment is already %', a.status; end if;
  if p_action in ('confirmed','declined') and a.status <> 'requested' then raise exception 'This appointment is already confirmed'; end if;
  if p_action = 'no-show' and a.status <> 'booked' then raise exception 'Confirm or decline the request first'; end if;
  if p_action in ('moved','confirmed') then perform browtech.check_staff(p_staff_id, false); end if;
  if p_action = 'moved' then
    perform browtech.check_appt_date(p_date, p_time);
    if p_date <> a.appt_date and p_date not in (select browtech.staff_days()) then raise exception 'Appointments can only be for today and the next 3 working days'; end if;
    if p_date = a.appt_date and p_time = a.appt_time and p_staff_id is not distinct from a.staff_id then raise exception 'Nothing was changed'; end if;
  end if;
  insert into browtech.appt_changes(user_id, appointment_id, action, new_date, new_time, new_staff_id, note)
  values (u.id, p_id, p_action,
          case when p_action = 'moved' then p_date end, case when p_action = 'moved' then p_time end,
          case when p_action in ('moved','confirmed') then p_staff_id end, nullif(left(btrim(p_note), 300), ''))
  returning id into new_id;
  return json_build_object('ok', true, 'id', new_id);
end $$;

-- Undo a wrong entry. The original stays in the log and is shown in red.
-- p_target: 'sale' | 'appointment' | 'change'. Workers can undo only what they entered themselves.
create or replace function public.undo_entry(p_token uuid, p_target text, p_id bigint, p_reason text) returns json
language plpgsql security definer set search_path = browtech, public as $$
declare u browtech.users; c browtech.appt_changes; a record; owner int;
begin
  u := browtech.me(p_token);
  if p_reason is null or btrim(p_reason) = '' then raise exception 'Write why this entry is wrong'; end if;
  if p_target is null or p_target not in ('sale','appointment','change') then raise exception 'Unknown entry type'; end if;
  perform browtech.lock_all();
  if browtech.is_undone(p_target, p_id) then raise exception 'This entry was already undone'; end if;
  if p_target = 'sale' then
    select user_id into owner from browtech.sales where id = p_id;
    if not found then raise exception 'Entry not found'; end if;
  elsif p_target = 'appointment' then
    select user_id into owner from browtech.appointments where id = p_id;
    if not found then raise exception 'Entry not found'; end if;
    select * into a from browtech.appt_now(p_id);
    if a.status = 'done' then raise exception 'This appointment was marked done. Undo the service entry first.'; end if;
  else
    select * into c from browtech.appt_changes where id = p_id;
    if not found then raise exception 'Entry not found'; end if;
    owner := c.user_id;
    select * into a from browtech.appt_now(c.appointment_id);
    if a.status in ('done','undone') then raise exception 'This appointment is %. Undo that first.', a.status; end if;
    if exists (select 1 from browtech.appt_changes x where x.appointment_id = c.appointment_id and x.id > c.id
                and not browtech.is_undone('change', x.id)) then
      raise exception 'There is a newer change on this appointment. Undo that one first.';
    end if;
  end if;
  if not u.is_admin and owner is distinct from u.id then raise exception 'You can only undo your own entries. Ask an admin.'; end if;
  insert into browtech.undos(user_id, target, target_id, reason) values (u.id, p_target, p_id, left(btrim(p_reason), 300));
  return json_build_object('ok', true);
end $$;

create or replace function public.change_pin(p_token uuid, p_old text, p_new text) returns json
language plpgsql security definer set search_path = browtech, public as $$
declare u browtech.users;
begin
  u := browtech.me(p_token);
  if u.pin_hash <> extensions.crypt(coalesce(p_old, ''), u.pin_hash) then raise exception 'Current PIN is wrong'; end if;
  perform browtech.check_pin(p_new);
  update browtech.users set pin_hash = extensions.crypt(p_new, extensions.gen_salt('bf')) where id = u.id;
  insert into browtech.events(user_id, action, details) values (u.id, 'pin changed', u.name || ' changed their PIN');
  return json_build_object('ok', true);
end $$;

-- ---------- admin ----------
create or replace function public.add_user(p_token uuid, p_name text, p_pin text, p_is_admin boolean) returns json
language plpgsql security definer set search_path = browtech, public as $$
declare u browtech.users;
begin
  u := browtech.me(p_token); perform browtech.need_admin(u);
  if p_name is null or btrim(p_name) = '' then raise exception 'Enter a name'; end if;
  if exists (select 1 from browtech.users where lower(name) = lower(btrim(p_name))) then raise exception 'That name already exists'; end if;
  perform browtech.check_pin(p_pin);
  insert into browtech.users(name, pin_hash, is_admin) values (btrim(p_name), extensions.crypt(p_pin, extensions.gen_salt('bf')), coalesce(p_is_admin, false));
  insert into browtech.events(user_id, action, details) values (u.id, 'person added', btrim(p_name) || case when p_is_admin then ' (admin)' else '' end);
  return json_build_object('ok', true);
end $$;

create or replace function public.reset_pin(p_token uuid, p_user_id int, p_pin text) returns json
language plpgsql security definer set search_path = browtech, public as $$
declare u browtech.users; t browtech.users;
begin
  u := browtech.me(p_token); perform browtech.need_admin(u);
  select * into t from browtech.users where id = p_user_id; if not found then raise exception 'Person not found'; end if;
  perform browtech.check_pin(p_pin);
  update browtech.users set pin_hash = extensions.crypt(p_pin, extensions.gen_salt('bf')), failed = 0, locked_until = null where id = t.id;
  delete from browtech.sessions where user_id = t.id and t.id <> u.id;
  insert into browtech.events(user_id, action, details) values (u.id, 'pin reset', 'PIN reset for ' || t.name);
  return json_build_object('ok', true);
end $$;

create or replace function public.set_user_active(p_token uuid, p_user_id int, p_active boolean) returns json
language plpgsql security definer set search_path = browtech, public as $$
declare u browtech.users; t browtech.users;
begin
  u := browtech.me(p_token); perform browtech.need_admin(u);
  if p_user_id = u.id then raise exception 'You cannot deactivate yourself'; end if;
  select * into t from browtech.users where id = p_user_id; if not found then raise exception 'Person not found'; end if;
  update browtech.users set active = p_active where id = t.id;
  if not p_active then delete from browtech.sessions where user_id = t.id; end if;
  insert into browtech.events(user_id, action, details) values (u.id, case when p_active then 'person activated' else 'person deactivated' end, t.name);
  return json_build_object('ok', true);
end $$;

create or replace function public.set_admin(p_token uuid, p_user_id int, p_is_admin boolean) returns json
language plpgsql security definer set search_path = browtech, public as $$
declare u browtech.users; t browtech.users;
begin
  u := browtech.me(p_token); perform browtech.need_admin(u);
  if p_user_id = u.id then raise exception 'You cannot change your own admin rights'; end if;
  select * into t from browtech.users where id = p_user_id; if not found then raise exception 'Person not found'; end if;
  update browtech.users set is_admin = p_is_admin where id = t.id;
  insert into browtech.events(user_id, action, details) values (u.id, case when p_is_admin then 'made admin' else 'admin removed' end, t.name);
  return json_build_object('ok', true);
end $$;

-- Price list: add a service, or change name / price / duration / shown-hidden / online of an existing one.
drop function if exists public.save_service(uuid, int, text, text, numeric, boolean);
create or replace function public.save_service(p_token uuid, p_id int, p_category text, p_name text, p_price numeric, p_active boolean, p_duration int, p_online boolean) returns json
language plpgsql security definer set search_path = browtech, public as $$
declare u browtech.users; old browtech.services; nm text := btrim(coalesce(p_name, '')); d text := ''; dur int := coalesce(p_duration, 60);
begin
  u := browtech.me(p_token); perform browtech.need_admin(u);
  perform browtech.check_category(p_category);
  if nm = '' then raise exception 'Enter the service name'; end if;
  if length(nm) > 60 then raise exception 'Name is too long'; end if;
  if p_price is null or p_price < 0 or p_price > 1000000 then raise exception 'Enter a price (0 = no fixed price)'; end if;
  if dur < 5 or dur > 600 then raise exception 'Choose how long the service takes'; end if;
  if exists (select 1 from browtech.services where category = p_category and lower(name) = lower(nm) and id is distinct from p_id) then
    raise exception 'That service already exists in this category';
  end if;
  if p_id is null then
    insert into browtech.services(category, name, price, active, duration_min, online) values (p_category, nm, round(p_price, 2), coalesce(p_active, true), dur, coalesce(p_online, true));
    insert into browtech.events(user_id, action, details) values (u.id, 'service added', initcap(p_category) || ': ' || nm || ' – GHS ' || to_char(round(p_price, 2), 'FM999999990.00') || ', ' || dur || ' min');
  else
    select * into old from browtech.services where id = p_id; if not found then raise exception 'Service not found'; end if;
    if old.category <> p_category then d := d || '; category ' || old.category || ' → ' || p_category; end if;
    if old.name <> nm then d := d || '; name ' || old.name || ' → ' || nm; end if;
    if old.price <> round(p_price, 2) then d := d || '; price GHS ' || to_char(old.price, 'FM999999990.00') || ' → ' || to_char(round(p_price, 2), 'FM999999990.00'); end if;
    if old.duration_min <> dur then d := d || '; time ' || old.duration_min || ' → ' || dur || ' min'; end if;
    if old.active <> coalesce(p_active, true) then d := d || case when coalesce(p_active, true) then '; shown again' else '; hidden' end; end if;
    if old.online <> coalesce(p_online, true) then d := d || case when coalesce(p_online, true) then '; bookable online' else '; not bookable online' end; end if;
    if d = '' then return json_build_object('ok', true, 'changed', false); end if;
    update browtech.services set category = p_category, name = nm, price = round(p_price, 2), active = coalesce(p_active, true), duration_min = dur, online = coalesce(p_online, true) where id = p_id;
    insert into browtech.events(user_id, action, details) values (u.id, 'price list', nm || ' –' || substr(d, 2));
  end if;
  return json_build_object('ok', true, 'changed', true);
end $$;

-- Price list: the order services are shown in (ids in the wanted order).
create or replace function public.reorder_services(p_token uuid, p_ids int[]) returns json
language plpgsql security definer set search_path = browtech, public as $$
declare u browtech.users;
begin
  u := browtech.me(p_token); perform browtech.need_admin(u);
  if p_ids is null or cardinality(p_ids) = 0 then raise exception 'Nothing to rearrange'; end if;
  update browtech.services s set sort_order = o.pos from unnest(p_ids) with ordinality as o(id, pos) where s.id = o.id;
  insert into browtech.events(user_id, action, details) values (u.id, 'price list', 'Services rearranged');
  return json_build_object('ok', true);
end $$;

-- Online booking settings
create or replace function public.save_settings(p_token uuid, p_online boolean, p_slot int, p_capacity int, p_days int, p_notice int, p_phone text, p_hours jsonb) returns json
language plpgsql security definer set search_path = browtech, public as $$
declare u browtech.users; k text; v jsonb; o text; c text;
begin
  u := browtech.me(p_token); perform browtech.need_admin(u);
  if p_hours is null or jsonb_typeof(p_hours) <> 'object' then raise exception 'Opening hours are missing'; end if;
  for k in select generate_series(0, 6)::text loop
    v := p_hours -> k;
    if v is null or jsonb_typeof(v) = 'null' then continue; end if;
    if jsonb_typeof(v) <> 'array' or jsonb_array_length(v) <> 2 then raise exception 'Opening hours are not valid'; end if;
    o := v->>0; c := v->>1;
    if o !~ '^\d{2}:\d{2}$' or c !~ '^\d{2}:\d{2}$' or o >= c then raise exception 'Opening time must be before closing time'; end if;
  end loop;
  update browtech.config set online_booking = coalesce(p_online, true), slot_minutes = p_slot, capacity = p_capacity, days_ahead = p_days,
         min_notice_hours = p_notice, contact_phone = nullif(left(btrim(p_phone), 30), ''),
         hours = (select jsonb_object_agg(g::text, coalesce(p_hours -> g::text, 'null'::jsonb)) from generate_series(0, 6) g)
   where id = 1;
  insert into browtech.events(user_id, action, details) values (u.id, 'booking settings',
    case when coalesce(p_online, true) then 'Online booking on' else 'Online booking OFF' end || ' · ' || p_capacity || ' at the same time · every ' || p_slot || ' min · ' || p_days || ' days ahead · ' || p_notice || ' h notice');
  return json_build_object('ok', true);
end $$;

-- Only the functions above are callable from the website.
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname in ('public_info','public_slots','public_request','list_users','login','logout','get_state','staff_slots',
       'add_sale','add_sales','book_appointment','change_appointment','undo_entry','change_pin','add_user','reset_pin','set_user_active','set_admin','save_service','reorder_services','save_settings')
  loop
    execute format('revoke all on function %s from public', f.sig);
    execute format('grant execute on function %s to anon, authenticated', f.sig);
  end loop;
end $$;
revoke all on all tables in schema browtech from public;
revoke all on all functions in schema browtech from public;

-- =====================================================================
-- FIRST ADMIN – change the name and the 6-digit PIN before the first run.
-- (On later runs this line does nothing.)
select browtech.create_first_admin('Prince', '123456');
-- =====================================================================
