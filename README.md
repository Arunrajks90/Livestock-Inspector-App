# Livestock Inspector – Field Officer App

A single-file web app (`index.html`) for Livestock Inspectors to manage farmers, animals, treatments, artificial insemination (AI), PD checks, free feed supply with weight checks, and inspector-only payment tracking. Accounts and records are stored in **Supabase**, so an inspector can log in from any phone or computer.

## Files
| File | Purpose |
|---|---|
| `index.html` | The whole app (HTML, CSS and JavaScript). Upload this to GitHub. |
| `supabase-setup.sql` | Database setup. Run once in Supabase. Do **not** upload it to the website. |
| `README.md` | This guide. |

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
1. Upload `index.html` (and this README) to the root of your repository.
2. **Settings → Pages → Deploy from a branch → `main` / `root` → Save.**
3. Open the link GitHub gives you. On a phone, use **Add to Home screen** to keep it like an app.

## Features
- **Sign up** with name, hospital / centre, qualification, age, gender, phone, email, area / panchayat and a password / PIN. **Log in** with email ID **or** phone number. **Forgot password** sends a reset link by email. Profile and Logout are under the name button at the top right.
- **Farmer → Animal workflow:** all animals for Treatment and Feed Supply, female animals only for AI and PD Check.
- **AI** records with a **monthly target** (default 20) on the dashboard and a daily reminder of the remaining count.
- **PD Check:** *Not Confirmed* leads to a repeat AI date with reminders. *Confirmed* opens a pregnancy page with next follow-up, expected due date and a 10 / 20-day (or custom) advance reminder.
- **Free Feed Supply** with an automatic 3-month weight check, reminders and weight verification.
- **Payments (inspector only):** amount, mode, Paid / Pending. Each record keeps its own status, you get an alert when you pick a farmer with dues, and **no payment messages are ever sent to farmers**.
- **WhatsApp / SMS** pre-filled messages for clinical and service follow-ups only.

## Saving and offline use
- Every change is saved to the cloud automatically. The badge in the header shows **☁️ Saved**, **⏳ Saving…** or **⚠️ Offline**.
- Without internet, changes are kept on the device and uploaded automatically when the connection returns. Don't log out while offline, or the changes stay on that device until you log in there again.
- Records saved on a phone before cloud login are offered for upload after the first login. The copy on the phone is kept.
- New accounts start with a completely **empty workspace**: no sample or demo records are ever added. Sample records left over from earlier test versions are removed automatically at login.

## Database tables
`profiles`, `farmers`, `animals`, `treatments`, `ai_records` (AI + PD Check + repeat AI + pregnancy), `feed_supplies`. Every record table has `user_id` linked to `auth.users(id)` and Row Level Security. The full record is stored in the `data` column, and readable columns such as name, dates, amount and payment status are filled in automatically for viewing and export in Supabase's Table Editor.
