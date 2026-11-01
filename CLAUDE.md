# BrowTech Kumasi – project notes for Claude

Owner: Prince (lives in Germany and Ghana). Business: BrowTech Kumasi – pony, piercing, brows, tattoo, lashes, nails (Kumasi, Ghana). Currency GH₵ (GHS). All times are Kumasi time (Africa/Accra).
Built to match the owner's earlier app `princesalasi/sakal_stocks` (same structure, PIN login, permanent log, Apple-style design).

## What it is
One static page (`index.html`, no build step, no libraries) on GitHub Pages: https://princesalasi.github.io/brTechKumasi/
Data in Supabase (free plan), project `bgfuyharbxpzdtdgaakv` (URL + publishable key in `config.js`). The website only calls SQL functions (RPC); tables live in a private schema `browtech`.

Three parts:
1. **Customer booking page** (default, no login): pick one or several services (max 6, any category) → day (only the next 3 days the shop is open, starting tomorrow; `days_ahead` is no longer used; staff book and move within today plus those 3 days, and the day strip shows the same days) → free time (fits total duration) → name/phone → sends a *request*. Tattoo requests get a "Send inspo on WhatsApp" button (wa.me link to the shop's WhatsApp number from settings; photos are not stored).
2. **Workers** (`#staff`, 6-digit PIN, 14 days per device): Today tab has a swipeable Walk-in / Appointments switch (Walk-in is the default on every load; the Appointments side shows a count of new requests). Walk-in: customers without a booking, tap services → swipeable Cash / MoMo switch (default Cash) → Pay, all on the page with no sheet, recorded at list price under the logged-in worker (no separate Service done button; the Done sheet of a booking is the only place to change amounts or staff, or add services); lists today's non-booking entries. Appointments – Available (free times of the chosen day, tap to book), Upcoming (bookings of that day, tap to expand name, clickable number, services, total), Completed services (today); new requests (confirm/decline/offer other time, ready WhatsApp text), appointments by day, book (several services, free-time chips), "Service done" (one line per service with own amount + staff). They only receive their own sales of today (no income), can only undo their own entries.
3. **Admin**: also History (filters, CSV in English format), Trends (charts, custom dates, PDF built without libraries), More: people, price list (price, duration, bookable online, Rearrange sets the order of the categories and of the services within each by hold and drag), booking settings (opening hours, customers at the same time, slot step, days ahead, min notice, WhatsApp number), activity log.

Discounts: optional GH₵ amount off the whole payment, on the walk-in page and the Done sheet. It is split across the entries in proportion to their amounts; `list_price` keeps the full price and the entry's note records the discount. No database change.

Rules: every entry is permanent (triggers block update/delete). Mistakes → Undo with a required reason (row in `browtech.undos`); undone entries are shown in red. Appointment status is derived (`browtech.appt_now`): requested / booked / done / declined / cancelled / no-show / undone.

## Files
- `index.html` – the whole app (CSS + JS inline). Design: lilac & pink, light/dark, Apple-style (sheets with drag-to-close, translucent tab bar, reduced-motion support).
- `setup.sql` – full database setup. **Safe to run again** (keeps data); run the newest version in Supabase SQL Editor after any DB change. Last line creates the first admin only once.
- `config.js` – Supabase URL + publishable key (public by design; never put a secret/service_role key here).
- `sw.js` – offline shell. **Bump `VERSION` whenever index.html changes.**
- `manifest.webmanifest` (staff app, start `./#staff`), `manifest-book.webmanifest` (booking page), icons, `logo.svg`.
- `.github/workflows/keep-awake.yml` – pings Supabase every 3 days so the free project doesn't pause.
- `tools/clear_test_entries.sql` – one-time fresh start (deletes entries, keeps people/prices).

## How it was tested
Local Postgres 16 with `setup.sql`, a tiny Node server that serves the files and maps `/rest/v1/rpc/<fn>` to `select public.<fn>(...)` as role `anon` (JSON number arrays → Postgres `int[]`), and Playwright clicking through customer / worker / admin flows at 390×844 in light and dark mode.

## Open to-dos (as of 2026-11-01)
- Owner must run the latest `setup.sql` in Supabase (multi-service + tattoo inspo version).
- In the app as admin: set WhatsApp number, opening hours, prices and durations; add staff.
- Run the "Keep database awake" workflow once by hand (Actions tab).
