-- =====================================================================
-- BrowTech Kumasi – services, income & appointments (Supabase database)
-- Run this ONCE in Supabase: SQL Editor → New query → paste → Run.
-- Before running, change the name and PIN in the LAST line of this file.
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

-- Bookings. Never changed or deleted; moves/cancellations are added in appt_changes.
create table if not exists browtech.appointments (
  id           bigserial primary key,
  logged_at    timestamptz not null default now(),
  user_id      int not null references browtech.users(id),
  appt_date    date not null,
  appt_time    time not null,
  service_id   int references browtech.services(id),
  category     text not null check (category in ('brows','lashes','nails','tattoo','piercing','pony')),
  service_name text not null,
  staff_id     int references browtech.users(id),            -- null = anyone
  customer     text not null,
  phone        text,
  note         text
);
alter table browtech.sales drop constraint if exists sales_appt_fk;
alter table browtech.sales add constraint sales_appt_fk foreign key (appointment_id) references browtech.appointments(id);

create table if not exists browtech.appt_changes (
  id             bigserial primary key,
  logged_at      timestamptz not null default now(),
  user_id        int not null references browtech.users(id),
  appointment_id bigint not null references browtech.appointments(id),
  action         text not null check (action in ('moved','cancelled','no-show')),
  new_date       date,
  new_time       time,
  new_staff_id   int references browtech.users(id),
  note           text
);
create index if not exists appt_changes_a on browtech.appt_changes(appointment_id);

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

-- Activity log: people added, PINs changed, prices changed, lockouts ...
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

-- Starter price list (prices 0 = not set yet; the admin sets them under More → Price list)
insert into browtech.services(category, name) values
  ('brows','Brow shaping'), ('brows','Brow tint'), ('brows','Brow lamination'), ('brows','Microblading'), ('brows','Microblading touch-up'),
  ('lashes','Classic lash set'), ('lashes','Volume lash set'), ('lashes','Lash refill'), ('lashes','Lash lift'),
  ('nails','Gel polish'), ('nails','Acrylic set'), ('nails','Acrylic refill'), ('nails','Pedicure'),
  ('tattoo','Small tattoo'), ('tattoo','Medium tattoo'), ('tattoo','Large tattoo'),
  ('piercing','Ear piercing'), ('piercing','Nose piercing'), ('piercing','Belly piercing'),
  ('pony','Ponytail')
on conflict do nothing;

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

-- "today" is Ghana time (Africa/Accra), whatever the server's clock zone
create or replace function browtech.today() returns date language sql stable as $$
  select (now() at time zone 'Africa/Accra')::date;
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
create or replace function browtech.pick_service(p_service_id int, p_category text, p_name text,
  out service_id int, out category text, out service_name text, out price numeric)
language plpgsql as $$
declare s browtech.services;
begin
  if p_service_id is not null then
    select * into s from browtech.services where id = p_service_id;
    if not found then raise exception 'Service not found'; end if;
    service_id := s.id; category := s.category; service_name := s.name; price := nullif(s.price, 0);
  else
    perform browtech.check_category(p_category);
    if p_name is null or btrim(p_name) = '' then raise exception 'Enter the service name'; end if;
    service_id := null; category := p_category; service_name := left(btrim(p_name), 60); price := null;
  end if;
end $$;

create or replace function browtech.lock_all() returns void language sql as $$
  select pg_advisory_xact_lock(515151);
$$;

create or replace function browtech.is_undone(p_target text, p_id bigint) returns boolean
language sql stable as $$
  select exists (select 1 from browtech.undos where target = p_target and target_id = p_id);
$$;

-- Where an appointment stands now: booked / done / cancelled / no-show / undone
create or replace function browtech.appt_now(p_id bigint,
  out status text, out appt_date date, out appt_time time, out staff_id int)
language plpgsql stable as $$
declare a browtech.appointments; c record;
begin
  select * into a from browtech.appointments where id = p_id;
  if not found then raise exception 'Appointment not found'; end if;
  appt_date := a.appt_date; appt_time := a.appt_time; staff_id := a.staff_id; status := 'booked';
  if browtech.is_undone('appointment', p_id) then status := 'undone'; return; end if;
  for c in select x.* from browtech.appt_changes x
            where x.appointment_id = p_id and not browtech.is_undone('change', x.id) order by x.id loop
    if c.action = 'moved' then
      appt_date := c.new_date; appt_time := c.new_time; staff_id := c.new_staff_id; status := 'booked';
    else
      status := c.action;
    end if;
  end loop;
  if exists (select 1 from browtech.sales s where s.appointment_id = p_id and not browtech.is_undone('sale', s.id)) then
    status := 'done';
  end if;
end $$;

-- Used once below to create the first admin.
create or replace function browtech.create_first_admin(p_name text, p_pin text) returns text
language plpgsql as $$
begin
  if exists (select 1 from browtech.users) then return 'Users already exist – nothing changed'; end if;
  perform browtech.check_pin(p_pin);
  insert into browtech.users(name, pin_hash, is_admin) values (btrim(p_name), extensions.crypt(p_pin, extensions.gen_salt('bf')), true);
  insert into browtech.events(user_id, action, details) values (currval('browtech.users_id_seq'), 'setup', 'First admin created: ' || btrim(p_name));
  return 'Admin ' || btrim(p_name) || ' created';
end $$;

-- =====================================================================
-- Functions the website calls
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
create or replace function public.get_state(p_token uuid, p_after_sale bigint default 0, p_after_appt bigint default 0,
  p_after_change bigint default 0, p_after_undo bigint default 0, p_after_event bigint default 0) returns json
language plpgsql stable security definer set search_path = browtech, public as $$
declare u browtech.users;
begin
  u := browtech.me(p_token);
  return json_build_object(
    'me', json_build_object('id', u.id, 'name', u.name, 'is_admin', u.is_admin),
    'users', (select coalesce(json_agg(json_build_object('id', id, 'name', name, 'is_admin', is_admin, 'active', active) order by id), '[]') from browtech.users),
    'services', (select coalesce(json_agg(s order by s.category, s.name), '[]') from browtech.services s),
    'sales', (select coalesce(json_agg(x order by x.id), '[]') from browtech.sales x where x.id > coalesce(p_after_sale, 0)),
    'appointments', (select coalesce(json_agg(x order by x.id), '[]') from browtech.appointments x where x.id > coalesce(p_after_appt, 0)),
    'changes', (select coalesce(json_agg(x order by x.id), '[]') from browtech.appt_changes x where x.id > coalesce(p_after_change, 0)),
    'undos', (select coalesce(json_agg(x order by x.id), '[]') from browtech.undos x where x.id > coalesce(p_after_undo, 0)),
    'events', case when u.is_admin then (select coalesce(json_agg(e order by e.id), '[]') from browtech.events e where e.id > coalesce(p_after_event, 0)) else '[]'::json end,
    'reset_count', (select reset_count from browtech.meta where id = 1),
    'server_time', now()
  );
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
  perform browtech.check_staff(p_staff_id, true);
  if p_amount is null or p_amount < 0 or p_amount > 1000000 then raise exception 'Enter the amount paid'; end if;
  pay := case when p_amount = 0 then 'free' else p_payment end;
  if pay is null or pay not in ('cash','momo','card','free') then raise exception 'Choose how the customer paid'; end if;
  if pay = 'free' and p_amount <> 0 then raise exception 'Choose how the customer paid'; end if;
  perform browtech.lock_all();
  if p_appointment_id is not null then
    select * into a from browtech.appt_now(p_appointment_id);
    if a.status = 'done' then raise exception 'This appointment is already marked as done'; end if;
    if a.status <> 'booked' then raise exception 'This appointment is %', a.status; end if;
  end if;
  insert into browtech.sales(user_id, staff_id, entry_date, service_id, category, service_name, list_price, amount, payment, customer, phone, note, appointment_id)
  values (u.id, p_staff_id, p_date, s.service_id, s.category, s.service_name, s.price, round(p_amount, 2), pay,
          nullif(left(btrim(p_customer), 80), ''), nullif(left(btrim(p_phone), 30), ''), nullif(left(btrim(p_note), 300), ''), p_appointment_id)
  returning id into new_id;
  return json_build_object('ok', true, 'id', new_id);
end $$;

create or replace function public.book_appointment(p_token uuid, p_service_id int, p_category text, p_name text,
  p_date date, p_time time, p_staff_id int, p_customer text, p_phone text, p_note text) returns json
language plpgsql security definer set search_path = browtech, public as $$
declare u browtech.users; s record; new_id bigint;
begin
  u := browtech.me(p_token);
  select * into s from browtech.pick_service(p_service_id, p_category, p_name);
  perform browtech.check_appt_date(p_date, p_time);
  perform browtech.check_staff(p_staff_id, false);
  if p_customer is null or btrim(p_customer) = '' then raise exception 'Enter the customer''s name'; end if;
  insert into browtech.appointments(user_id, appt_date, appt_time, service_id, category, service_name, staff_id, customer, phone, note)
  values (u.id, p_date, p_time, s.service_id, s.category, s.service_name, p_staff_id,
          left(btrim(p_customer), 80), nullif(left(btrim(p_phone), 30), ''), nullif(left(btrim(p_note), 300), ''))
  returning id into new_id;
  return json_build_object('ok', true, 'id', new_id);
end $$;

-- Move, cancel or mark no-show. p_action: 'moved' | 'cancelled' | 'no-show'
create or replace function public.change_appointment(p_token uuid, p_id bigint, p_action text, p_date date, p_time time, p_staff_id int, p_note text) returns json
language plpgsql security definer set search_path = browtech, public as $$
declare u browtech.users; a record; new_id bigint;
begin
  u := browtech.me(p_token);
  if p_action is null or p_action not in ('moved','cancelled','no-show') then raise exception 'Unknown change'; end if;
  perform browtech.lock_all();
  select * into a from browtech.appt_now(p_id);
  if a.status <> 'booked' then raise exception 'This appointment is already %', a.status; end if;
  if p_action = 'moved' then
    perform browtech.check_appt_date(p_date, p_time);
    perform browtech.check_staff(p_staff_id, false);
    if p_date = a.appt_date and p_time = a.appt_time and p_staff_id is not distinct from a.staff_id then raise exception 'Nothing was changed'; end if;
  end if;
  insert into browtech.appt_changes(user_id, appointment_id, action, new_date, new_time, new_staff_id, note)
  values (u.id, p_id, p_action,
          case when p_action = 'moved' then p_date end, case when p_action = 'moved' then p_time end,
          case when p_action = 'moved' then p_staff_id end, nullif(left(btrim(p_note), 300), ''))
  returning id into new_id;
  return json_build_object('ok', true, 'id', new_id);
end $$;

-- Undo a wrong entry. The original stays in the log and is shown in red.
-- p_target: 'sale' | 'appointment' | 'change'
create or replace function public.undo_entry(p_token uuid, p_target text, p_id bigint, p_reason text) returns json
language plpgsql security definer set search_path = browtech, public as $$
declare u browtech.users; c browtech.appt_changes; a record;
begin
  u := browtech.me(p_token);
  if p_reason is null or btrim(p_reason) = '' then raise exception 'Write why this entry is wrong'; end if;
  if p_target is null or p_target not in ('sale','appointment','change') then raise exception 'Unknown entry type'; end if;
  perform browtech.lock_all();
  if browtech.is_undone(p_target, p_id) then raise exception 'This entry was already undone'; end if;
  if p_target = 'sale' then
    if not exists (select 1 from browtech.sales where id = p_id) then raise exception 'Entry not found'; end if;
  elsif p_target = 'appointment' then
    select * into a from browtech.appt_now(p_id);
    if a.status = 'done' then raise exception 'This appointment was marked done. Undo the service entry first.'; end if;
  else
    select * into c from browtech.appt_changes where id = p_id;
    if not found then raise exception 'Entry not found'; end if;
    select * into a from browtech.appt_now(c.appointment_id);
    if a.status in ('done','undone') then raise exception 'This appointment is %. Undo that first.', a.status; end if;
    if exists (select 1 from browtech.appt_changes x where x.appointment_id = c.appointment_id and x.id > c.id
                and not browtech.is_undone('change', x.id)) then
      raise exception 'There is a newer change on this appointment. Undo that one first.';
    end if;
  end if;
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

-- Price list: add a service, or change name / price / shown-hidden of an existing one.
create or replace function public.save_service(p_token uuid, p_id int, p_category text, p_name text, p_price numeric, p_active boolean) returns json
language plpgsql security definer set search_path = browtech, public as $$
declare u browtech.users; old browtech.services; nm text := btrim(coalesce(p_name, '')); d text := '';
begin
  u := browtech.me(p_token); perform browtech.need_admin(u);
  perform browtech.check_category(p_category);
  if nm = '' then raise exception 'Enter the service name'; end if;
  if length(nm) > 60 then raise exception 'Name is too long'; end if;
  if p_price is null or p_price < 0 or p_price > 1000000 then raise exception 'Enter a price (0 = no fixed price)'; end if;
  if exists (select 1 from browtech.services where category = p_category and lower(name) = lower(nm) and id is distinct from p_id) then
    raise exception 'That service already exists in this category';
  end if;
  if p_id is null then
    insert into browtech.services(category, name, price, active) values (p_category, nm, round(p_price, 2), coalesce(p_active, true));
    insert into browtech.events(user_id, action, details) values (u.id, 'service added', initcap(p_category) || ': ' || nm || ' – GHS ' || to_char(round(p_price, 2), 'FM999999990.00'));
  else
    select * into old from browtech.services where id = p_id; if not found then raise exception 'Service not found'; end if;
    if old.category <> p_category then d := d || '; category ' || old.category || ' → ' || p_category; end if;
    if old.name <> nm then d := d || '; name ' || old.name || ' → ' || nm; end if;
    if old.price <> round(p_price, 2) then d := d || '; price GHS ' || to_char(old.price, 'FM999999990.00') || ' → ' || to_char(round(p_price, 2), 'FM999999990.00'); end if;
    if old.active <> coalesce(p_active, true) then d := d || case when coalesce(p_active, true) then '; shown again' else '; hidden' end; end if;
    if d = '' then return json_build_object('ok', true, 'changed', false); end if;
    update browtech.services set category = p_category, name = nm, price = round(p_price, 2), active = coalesce(p_active, true) where id = p_id;
    insert into browtech.events(user_id, action, details) values (u.id, 'price list', nm || ' –' || substr(d, 2));
  end if;
  return json_build_object('ok', true, 'changed', true);
end $$;

-- Only the functions above are callable from the website.
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname in ('list_users','login','logout','get_state','add_sale','book_appointment',
       'change_appointment','undo_entry','change_pin','add_user','reset_pin','set_user_active','set_admin','save_service')
  loop
    execute format('revoke all on function %s from public', f.sig);
    execute format('grant execute on function %s to anon, authenticated', f.sig);
  end loop;
end $$;
revoke all on all tables in schema browtech from public;
revoke all on all functions in schema browtech from public;

-- =====================================================================
-- FIRST ADMIN – change the name and the 6-digit PIN before running:
select browtech.create_first_admin('Prince', '123456');
-- =====================================================================
