# BrowTech Kumasi

App for BrowTech Kumasi (pony, piercing, brows, tattoo, lashes, nails): services done, income and appointments.

- Each person logs in with their own **6-digit PIN**. Each phone stays logged in for **2 weeks**.
- **Service done**: pick the service from the price list – the price fills in automatically and can be changed for one customer. Choose who did it and how the customer paid (Cash, MoMo, Card / bank).
- **Appointments**: book, move, cancel, mark "customer didn't come", or tap **Done** to record the service and payment.
- Every entry is **permanent** and logged with who and when. Mistakes are fixed with **Undo** (a reason is required); undone entries stay visible in red.
- **History** (filters, CSV in English format), **Trends** (charts, custom dates, PDF), **More** (PIN change; admin: people, price list, activity log).
- All days and times are **Kumasi time**, even on a phone set to another time zone.

The page is hosted free on GitHub Pages; the data lives in a free Supabase database.
App address: **https://princesalasi.github.io/brTechKumasi/**

## One-time setup

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

### 5. Prices and people
Log in as the admin →
- **More → Price list**: tap each service to set its price, or **Add service**. Hide services you don't offer.
- **More → People → Add person**: name and 6-digit PIN for everyone. Everyone can change their own PIN under **More**.

### 6. Home screen
- **iPhone**: open the app address in **Safari** → **Share** → **Add to Home Screen**.
- **Android**: open it in **Chrome** → **⋮** → **Add to Home screen** / **Install app**.

### 7. Fresh start after testing (optional)
When you have finished trying things out, run `tools/clear_test_entries.sql` once in the Supabase SQL Editor. It deletes all services, bookings and the activity log, but keeps people, PINs and the price list.

## How it works
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
| `sw.js`, `manifest.webmanifest`, `icon-*.png`, `apple-touch-icon.png`, `logo.svg` | Home-screen app, logo and offline support |
| `.github/workflows/keep-awake.yml` | Keeps the free database from pausing |

When you change `index.html`, also change `VERSION` in `sw.js` so phones load the new version.
