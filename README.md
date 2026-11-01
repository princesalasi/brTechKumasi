# BrowTech Kumasi

Booking page and staff app for BrowTech Kumasi (pony, piercing, brows, tattoo, lashes, nails).

**Three parts, one link:**

| Who | Address | What they can do |
|---|---|---|
| **Customers** | https://princesalasi.github.io/brTechKumasi/ | Choose **one or several services** (with prices and durations, from any category), a day and a **free** time for all of them together, enter name and phone → sends a **request**. Tattoo customers then get a button to send their **inspiration photos to your WhatsApp**. No login. |
| **Workers** | …/brTechKumasi/#staff (PIN) | New requests (confirm / decline, ready WhatsApp message), appointments, book by phone, **Service done**. They see only their own entries of today – no income. |
| **Admin** | …/brTechKumasi/#staff (PIN) | Everything above plus **History** (filters, CSV), **Trends** (charts, PDF) and **More**: people, price list (price, duration, bookable online), booking settings (opening hours, customers at the same time, how far ahead, minimum notice, contact phone), activity log. |

- Each person logs in with their own **6-digit PIN**; each phone stays logged in for **2 weeks**.
- Every entry is **permanent** and logged with who and when. Mistakes are fixed with **Undo** (reason required); undone entries stay visible in red. Workers can only undo their own entries.
- **Several services**: one booking can hold up to 6 services (e.g. brows + lashes). The times offered fit all of them together. When marking it **Done**, each service gets its own line with its own amount and "done by", so income per category and per person stays correct. Staff can also enter several services at once with **Service done**.
- **Tattoo inspo**: after a request that includes a tattoo, the customer taps **Send inspo on WhatsApp**. WhatsApp opens a chat with the shop's WhatsApp number (More → Online booking → WhatsApp number) with a message naming their request; they attach the photos and send. The photos are not stored in the app.
- Customers only see times where there is still a free place for the **whole length** of the services (opening hours + "customers at the same time"). Requests and confirmed bookings both take a place; declined/cancelled ones free it again.
- Spam protection: hidden robot trap, max. 3 open requests per phone number, max. 40 online requests per hour.
- All days and times are **Kumasi time**, even on a phone set to another time zone.

The page is hosted free on GitHub Pages; the data lives in a free Supabase database.

## One-time setup

### Updating the database after a new version
Open `setup.sql` (newest version), copy everything, paste it into Supabase **SQL Editor → New query → Run**.
It keeps people, PINs, prices and all entries. The result says `Setup is up to date`.

### 1. Database (Supabase)
1. On [supabase.com](https://supabase.com) → **New project** (free plan). Name it e.g. `BrowTech`, region **West EU (Ireland)** or **Central EU (Frankfurt)**, set a database password (keep it somewhere safe – the app doesn't need it).
2. When it's ready: **SQL Editor** → **New query**.
3. Open `setup.sql` from this repo, copy everything, paste it into the editor.
4. In the **last line**, put the first admin's name and a 6-digit PIN, e.g.
   `select browtech.create_first_admin('Prince', '258013');`
5. Click **Run**. The result should say `Admin Prince created`.

### 2. Connect the page to the database
1. In Supabase: **Project Settings → API Keys** (or the **Connect** button at the top).
2. Copy the **Project URL** and the **publishable** key (`sb_publishable_…`; older projects: the **anon public** key).
3. Put both into `config.js` in this repo (on GitHub: open the file → pencil icon → edit → **Commit changes**).

The publishable/anon key is meant to be public. It only allows calling the app's functions; the tables themselves are locked.
**Never** use the `service_role` / `secret` key anywhere in this repo.

### 3. Turn on GitHub Pages
Repo **Settings → Pages → Build and deployment**: Source = *Deploy from a branch*, Branch = `main`, folder `/ (root)` → **Save**.
After a minute the app is at https://princesalasi.github.io/brTechKumasi/

### 4. Keep the database awake
The free Supabase project pauses after a week without use. The job in `.github/workflows/keep-awake.yml` pings it every 3 days.
Check it once: repo **Actions** tab → *Keep database awake* → **Run workflow**. It should turn green (it can only work after step 2).

### 5. Prices, booking settings and people
Log in as the admin (…/brTechKumasi/#staff) →
- **More → Online booking → Change booking settings**: opening hours, how many customers can be served at the same time, how far ahead and how short-notice customers can book, the **WhatsApp number** (customers can message it, and tattoo inspo photos go to it).
- **More → Price list**: tap each service to set its price and how long it takes, or **Add service**. Hide services you don't offer, or switch off "bookable online" for ones that need a consultation first.
- **More → People → Add person**: name and 6-digit PIN for everyone. Everyone can change their own PIN under **More**.

### 6. Share the booking link, install the staff app
- Customers: share https://princesalasi.github.io/brTechKumasi/ (More → **Share link**) on WhatsApp status, Instagram bio, Google Business profile.
- Staff phones: open **…/brTechKumasi/#staff** → iPhone: **Safari → Share → Add to Home Screen**; Android: **Chrome → ⋮ → Install app**. The icon then opens straight to the staff login.

### 7. Fresh start after testing (optional)
When you have finished trying things out, run `tools/clear_test_entries.sql` once in the Supabase SQL Editor. It deletes all services, bookings and the activity log, but keeps people, PINs and the price list.

## How it works
- **Requests**: confirm (optionally choose who does it), decline, or "offer another time" (move). After each, the app offers a ready WhatsApp message to the customer.
- **Undo**: services, bookings and booking changes can each be undone with a reason. An appointment marked *Done* must have its service entry undone first. For a moved/cancelled appointment, the newest change is undone first.
- **Free services**: enter amount 0 – it is saved as *Free*.
- **Other service**: not on the price list? Choose *Other service* and type it.
- **Admins** can add people, reset PINs, make someone admin, deactivate people (their entries stay), change prices, and see the activity log.
- **Wrong PIN 5 times** → that person is locked for 15 minutes. An admin can reset the PIN.
- **Offline**: the app opens and shows the last loaded data, but entries need internet.
- **CSV**: comma-separated, dates `YYYY-MM-DD`, amounts with a decimal point (e.g. `150.00`), opens directly in Excel or Google Sheets.
- **PDF**: amounts are written as `GHS` (the built-in PDF font has no ₵ sign).

## Files
| File | What it is |
|---|---|
| `index.html` | The app |
| `config.js` | Supabase URL and public key |
| `setup.sql` | Database setup – run once in Supabase |
| `tools/clear_test_entries.sql` | Optional one-time fresh start after testing |
| `sw.js`, `manifest.webmanifest` (staff app), `manifest-book.webmanifest` (booking page), `btk-icon-*.png`, `btk-apple-touch-icon.png` | Home-screen app, logo and offline support |
| `.github/workflows/keep-awake.yml` | Keeps the free database from pausing |

When you change `index.html`, also change `VERSION` in `sw.js` so phones load the new version.
