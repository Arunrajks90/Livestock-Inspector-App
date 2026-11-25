# Livestock Inspector – Field Officer App

A single-file web app (`index.html`) for Livestock Inspectors to manage farmers, animals, treatments, artificial insemination (AI), PD checks, free feed supply with weight checks, and inspector-only payment tracking. Accounts and records are stored in **Supabase**, so an inspector can log in from any phone or computer.

## Files and where they go in your GitHub repository
Put everything in the **root** of the repository (the same folder), with the icons inside an `icons` folder:

```
your-repo/
├── index.html            ← the app
├── manifest.json         ← makes it installable (name, colours, icons)
├── sw.js                 ← service worker (fast start, opens offline)
├── README.md             ← this guide (optional)
└── icons/
    ├── icon.svg
    ├── icon-192.png
    ├── icon-512.png
    ├── maskable-192.png
    ├── maskable-512.png
    └── apple-touch-icon.png
```

`supabase-setup.sql` is **not** part of the website. Run it once in Supabase (below); you do not need to upload it.

**Uploading on github.com:** open the repository → **Add file → Upload files** → drag in `index.html`, `manifest.json`, `sw.js` and `README.md`, then commit. For the icons, choose **Add file → Upload files** again and drag the whole `icons` folder in (or unzip `field-officer-pwa.zip` and drag all of its contents at once). The file names must stay exactly as shown.

## One-time Supabase setup
1. Open your project at [supabase.com](https://supabase.com) → **SQL Editor** → **New query**. Paste the whole of `supabase-setup.sql` and click **Run**. It is safe to run again later.
2. Go to **Authentication → URL Configuration**:
   - **Site URL:** your GitHub Pages address, e.g. `https://<username>.github.io/<repo>/`
   - **Redirect URLs:** add the same address. This makes the email confirmation and password-reset links open your app.
3. **Authentication → Sign In / Providers → Email:**
   - **Confirm email** is on by default: new inspectors must click the link in their email before they can log in. Switch it off if you want instant sign-up while testing.
   - The minimum password length is 6 characters, so a PIN must have at least 6 digits.
4. Supabase's built-in email sender only sends a few emails per hour. For real use, add your own SMTP server under **Authentication → Emails → SMTP Settings**.

The app uses the project URL and the **publishable** key, which are safe to put in a public web page. Your data is protected by Row Level Security: each inspector can only read and change their own rows. **Never** put the `service_role` or secret key in `index.html`.

## Publish on GitHub Pages
1. Upload the files as shown above.
2. **Settings → Pages → Deploy from a branch → `main` / `root` → Save.**
3. Open the link GitHub gives you (it must be the **https** address; installing does not work from a file on your computer).

## Install on a phone
- **Android (Chrome, Edge, Samsung Internet):** a banner at the bottom offers **Install**. Or tap the menu **⋮ → Install app / Add to Home screen**.
- **iPhone / iPad (Safari):** a short guide appears. Tap **Share** → **Add to Home Screen** → **Add**.
- The app is also available any time from **👤 your name → 📲 Install app**. Closing the banner with ✕ hides it for 14 days.
- Long-press the installed icon (Android) for shortcuts: **Log treatment**, **Log AI**, **Record PD result**.

## Updating the app later
- Upload a new `index.html`: phones pick it up automatically the next time the app is opened online.
- If you change `sw.js`, `manifest.json` or the icons, also change `const VERSION = 'v1'` in `sw.js` (for example to `'v2'`) so phones refresh their saved copy.
- The service worker never stores Supabase sign-in or database requests, so logins and records are always live.

## Features
- **Sign up** with name, hospital / centre, qualification, age, gender, phone, email, area / panchayat and a password / PIN. **Log in** with email ID **or** phone number. **Forgot password** sends a reset link by email. Profile and Logout are under the name button at the top right.
- **Farmer → Animal workflow:** all animals for Treatment and Feed Supply, female animals only for AI and PD Check.
- **AI** records with a **monthly target** (default 20) on the dashboard and a daily reminder of the remaining count.
- **PD Check:** *Not Confirmed* leads to a repeat AI date with reminders. *Confirmed* opens a pregnancy page with next follow-up, expected due date and a 10 / 20-day (or custom) advance reminder.
- **Free Feed Supply** with an automatic 3-month weight check, reminders and weight verification.
- **Payments (inspector only):** amount, mode, Paid / Pending. Each record keeps its own status, you get an alert when you pick a farmer with dues, and **no payment messages are ever sent to farmers**.
- **WhatsApp / SMS** pre-filled messages for clinical and service follow-ups only.

## Reminder popup (🔔)
- When the app opens (and every 30 seconds while it is open) a popup lists reminders that are **due tomorrow, today or overdue**: treatment and AI follow-ups, PD checks, repeat AI dates, pregnancy follow-ups, expected due dates and 3-month weight checks.
- Expected due dates also pop up during your **10 / 20-day advance window**, and again as a separate **1-day-before** alert.
- The **daily AI target** (default 20 / month) shows once a day while AIs remain.
- **💤 Snooze:** 2 hours, until tomorrow 8 AM, or 1 day. It pops up again when the time is up.
- **🔕 Stop:** silences that reminder for that date (the AI target is stopped for the rest of the month). If the date is changed later, a new reminder is created.
- Snooze / Stop never change your records. They are saved to your Supabase profile, so they stay after refresh, re-login or on another device.
- The **🔔 bell** in the header shows how many reminders need attention and lists snoozed / stopped ones with a **Resume** button.
- No payment information is ever included in reminders or in messages to farmers.

## Saving and offline use
- Every change is saved to the cloud automatically. The badge in the header shows **☁️ Saved**, **⏳ Saving…** or **⚠️ Offline**.
- Without internet, changes are kept on the device and uploaded automatically when the connection returns. Don't log out while offline, or the changes stay on that device until you log in there again.
- Records saved on a phone before cloud login are offered for upload after the first login. The copy on the phone is kept.
- New accounts start with a completely **empty workspace**: no sample or demo records are ever added. Sample records left over from earlier test versions are removed automatically at login.

## Database tables
`profiles`, `farmers`, `animals`, `treatments`, `ai_records` (AI + PD Check + repeat AI + pregnancy), `feed_supplies`. Every record table has `user_id` linked to `auth.users(id)` and Row Level Security. The full record is stored in the `data` column, and readable columns such as name, dates, amount and payment status are filled in automatically for viewing and export in Supabase's Table Editor.
