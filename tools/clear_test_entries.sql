-- =====================================================================
-- ONE-TIME FRESH START – deletes ALL services done, bookings, booking changes,
-- undo marks and the activity log.
-- Kept: people, PINs, admin rights, the price list, and logins.
-- This cannot be undone. Run it only once, right before you start real use.
--
-- Supabase: SQL Editor → New query → paste everything → Run.
-- If Supabase warns about a "destructive operation", confirm.
-- =====================================================================
begin;

-- The log is normally locked against deleting. Unlock it only for this moment.
alter table browtech.sales        disable trigger user;
alter table browtech.appointments disable trigger user;
alter table browtech.appt_changes disable trigger user;
alter table browtech.undos        disable trigger user;
alter table browtech.events       disable trigger user;

delete from browtech.undos;
delete from browtech.sales;
delete from browtech.appt_changes;
delete from browtech.appointments;
delete from browtech.events;

-- Lock it again.
alter table browtech.sales        enable trigger user;
alter table browtech.appointments enable trigger user;
alter table browtech.appt_changes enable trigger user;
alter table browtech.undos        enable trigger user;
alter table browtech.events       enable trigger user;

-- Tell the app on every phone to throw away its saved copy of the old entries.
update browtech.meta set reset_count = reset_count + 1 where id = 1;
insert into browtech.events(user_id, action, details) values (null, 'log reset', 'All test entries cleared – fresh start');

commit;

-- Check: entries_left should be 0.
select (select count(*) from browtech.sales) + (select count(*) from browtech.appointments) as entries_left,
       (select count(*) from browtech.users) as people_kept;
