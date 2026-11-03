# BrowTech Kumasi – project notes for Claude

Owner: Prince (lives in Germany and Ghana). Business: BrowTech Kumasi – pony, piercing, brows, tattoo, lashes, nails (Kumasi, Ghana). Currency GH₵ (GHS). All times are Kumasi time (Africa/Accra).
Built to match the owner's earlier app `princesalasi/sakal_stocks` (same structure, PIN login, permanent log, Apple-style design).

## What it is
One static page (`index.html`, no build step, no libraries) on GitHub Pages: https://princesalasi.github.io/brTechKumasi/. Customers get https://www.btkumasi.com/ (`SITE` in `index.html`); links sent from the app always use it.

Staff login: type the name, then the 6-digit PIN (`login_name`). Names are never listed on the login screen, so customers who tap Staff can't see who works here.
Data in Supabase (free plan), project `bgfuyharbxpzdtdgaakv` (URL + publishable key in `config.js`). The website only calls SQL functions (RPC); tables live in a private schema `browtech`.

Booking page gallery: a strip of style ideas for the chosen category, kept in `browtech.gallery`. Admins change it in Settings > Gallery photos (add, remove, hold and drag, 12 per category). The phone shrinks uploads, which are stored in the database as a small thumbnail plus a larger image fetched on tap. Older rows point to files in `gallery/` or Pexels photos. There is no built-in fallback list: when the database can't answer, the strip stays empty rather than show old photos.

A swipeable Client / Staff switch moves between the parts: top of the booking page, the login page and the Settings tab. Staff still needs a PIN unless already logged in on that device.

Three parts:
1. **Customer booking page** (default, no login): pick one or several services (max 6, any category) → day (any day the shop is open in the next 2 weeks, starting tomorrow; `days_ahead` is no longer used; staff book and move within today plus those days, and the day strip shows the same days) → free time (fits total duration) → name/phone → sends a *request*. Tattoo requests get a "Send inspo on WhatsApp" button (wa.me link to the shop's WhatsApp number from settings; photos are not stored).
2. **Workers** (`#staff`, 6-digit PIN, 14 days per device): Today tab has a swipeable Walk-in / Appointments switch (Walk-in is the default on every load; the Appointments side shows a count of new requests). Walk-in: customers without a booking, tap services → swipeable Cash / MoMo switch (default Cash) → Pay, all on the page with no sheet, recorded at list price under the logged-in worker (no separate Service done button; the Done sheet of a booking is the only place to change amounts or staff, or add services); lists today's non-booking entries. Appointments – Available (free times of the chosen day, tap to book), Upcoming (bookings of that day, tap to expand name, clickable number, services, total), Completed services (today); new requests (confirm/decline/offer other time, ready WhatsApp text), appointments by day, book (several services, free-time chips), "Service done" (one line per service with own amount + staff). They only receive their own sales of today (no income), can only undo their own entries.
3. **Admin**: also History (filters, CSV in English format), Trends (charts, custom dates, PDF built without libraries; the Income chart switches between bars and a line with points, remembered per device), Settings: staff, price list (price, duration, bookable online, Rearrange sets the order of the categories and of the services within each by hold and drag; Delete removes a service, or a category with all its services, from every list while old entries and existing bookings keep them; a category returns when a service is added to it), booking settings (opening hours, customers at the same time, slot step, days ahead, min notice, WhatsApp number), activity log. The price list and activity log are collapsible, closed by default, remembered per device.

Main services: six built-in ones plus the admin's own (`config.custom_categories`), added with New category in the Add service sheet. Every page reads `CATS` and `CAT_KEYS`, so new ones appear everywhere automatically; don't hard-code the list. Renaming is not built yet.

Discounts: optional GH₵ amount off the whole payment, on the walk-in page and the Done sheet. It is split across the entries in proportion to their amounts; `list_price` keeps the full price and the entry's note records the discount. No database change.

WhatsApp requests: after booking, the customer taps a button that opens WhatsApp with the request ready for the shop's number (from settings), and must tap send; websites cannot send it by themselves. The message holds a link (`#staff/<appointment id>`) that opens that appointment in the staff app, after the PIN if needed. Without a WhatsApp number in settings the button is not shown.

Rules: every entry is permanent (triggers block update/delete). Mistakes → Undo with a required reason (row in `browtech.undos`); undone entries are shown in red. Appointment status is derived (`browtech.appt_now`): requested / booked / done / declined / cancelled / no-show / undone.

## Files
- `index.html` – the whole app (CSS + JS inline). Design: Bubblegum Pink (#f05da3) with the logo's rose gold, light only with page background #FAF4F6 (no dark mode, at the owner's request), Apple-style (sheets with drag-to-close, translucent tab bar, reduced-motion support).
- `setup.sql` – full database setup. **Safe to run again** (keeps data); run the newest version in Supabase SQL Editor after any DB change. Last line creates the first admin only once.
- `config.js` – Supabase URL + publishable key (public by design; never put a secret/service_role key here).
- `sw.js` – offline shell. **Bump `VERSION` whenever index.html changes.**
- `manifest.webmanifest` (staff app, start `./#staff`), `manifest-book.webmanifest` (booking page), icons (`btk-*.png`, made from the owner's logo; use a new file name when they change, because phones cache icons).
- `.github/workflows/keep-awake.yml` – pings Supabase every 3 days so the free project doesn't pause.
- `tools/clear_test_entries.sql` – one-time fresh start (deletes entries, keeps people/prices).

## How it was tested
Local Postgres 16 with `setup.sql`, a tiny Node server that serves the files and maps `/rest/v1/rpc/<fn>` to `select public.<fn>(...)` as role `anon` (JSON number arrays → Postgres `int[]`), and Playwright clicking through customer / worker / admin flows at 390×844 in light and dark mode.

## Open to-dos (as of 2026-11-01)
- Owner must run the latest `setup.sql` in Supabase (multi-service + tattoo inspo version).
- In the app as admin: set WhatsApp number, opening hours, prices and durations; add staff.
- Run the "Keep database awake" workflow once by hand (Actions tab).
