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

`supabase-setup.sql`, `supabase-circles.sql`, `supabase-messages.sql`, `supabase-abortion.sql`, `supabase-subscriptions.sql`, `supabase-security-hardening.sql` and `supabase-support.sql` are **not** part of the website. Run them in Supabase (below); you do not need to upload them.

**Uploading on github.com:** open the repository → **Add file → Upload files** → drag in `index.html`, `manifest.json`, `sw.js` and `README.md`, then commit. For the icons, choose **Add file → Upload files** again and drag the whole `icons` folder in (or unzip `field-officer-pwa.zip` and drag all of its contents at once). The file names must stay exactly as shown.

## One-time Supabase setup
1. Open your project at [supabase.com](https://supabase.com) → **SQL Editor** → **New query**. Paste the whole of `supabase-setup.sql` and click **Run**. Then do the same with `supabase-circles.sql` (Inspector Circle and task handover) then `supabase-messages.sql` (circle messaging), `supabase-abortion.sql` (abortion columns) `supabase-subscriptions.sql` (₹99/month plans; admin = id.arunraj@gmail.com) `supabase-security-hardening.sql` (closes the loopholes found in the security audit) and finally `supabase-support.sql` (Help & Support chat + admin User Directory). All are safe to run again later.
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

## Inspector Circle and task handover (👥 Circle tab)
- **Create** a circle (you get a 6-letter invite code) or **join** one with a colleague's code. Members see only each other's name, hospital and area: **never** each other's farmers, animals, records or payments.
- **👥 Allot** on a pending treatment follow-up, AI follow-up, PD check or repeat AI (and **👥 Allot visit** on an animal page for a new treatment visit or AI) sends **only that task** to a chosen member, with your description. It shows the farmer's name, phone and village, the animal summary and that task's clinical details. Payment details are never shared.
- The colleague sees it under **📥 Waiting for you** and can **Accept** or **Decline** (with a reason). Before accepting, the farmer's phone is hidden. Accepted tasks go to **📋 My allotted feed**, with WhatsApp / SMS to the farmer, and appear in their 🔔 reminders.
- **Closing an allotted task (assignee):** a **closure description is required** and the closed date is saved. The task then goes **back to the sender** as **Closed by Assignee**. The assignee's part ends there: no more follow-ups, buttons or reminders for them.
- **Declined by the assignee:** the colleague can **Decline** with an optional reason. The task leaves their incoming list, feed and reminders at once. It goes straight back to the sender as an **open follow-up in the sender's 📅 Tracker on its original due date**, marked **"↩ Declined by …"** with the reason. Its 1-day-before reminders return to the sender, and it stays open until the sender closes it (✔ Mark closed) or allots it again. On each declined item the sender gets two buttons: **✅ Do / Complete** (do it yourself: record the treatment / AI / follow-up visit, optionally with a next follow-up date so the follow-up cycle continues, each next visit offering **✅ Complete** again) and **✔ Close** (close it with a note). A declined *visit request* from an animal page becomes an open **📌 Planned visit** on the requested date. The Tracker filter **↩ Returned / declined** lists these items.
- **Returned to the sender:** the sender sees it under **↩ Returned to you** (also on Home, the Circle badge and the 🔔 popup) with the closed date and description, and taps **📅 Set next follow-up** (or **No further follow-up**). As soon as the date is saved, the follow-up **appears in the sender's 📅 Tracker** (the app opens it there), labelled **↩ After handover**, with the normal 1-day-before reminders; the Tracker also lists tasks still waiting for a date, and has an **↩ After handover** filter. In Supabase the same list is in the private view **my_follow_up_tracker**. The next follow-up date is saved **only in the sender's own records**, so its reminders belong to the sender alone and the assignee never sees it. An AI done by a colleague is recorded with its PD date but does not count toward the sender's monthly AI target.
- **✔ Mark closed** (on your own pending follow-ups and on allotted tasks) records a closure description, for example *"Completed by another person — confirmed with farmer on call"*. The record stays, the note is added to the animal's history, and the reminder stops. When a colleague closes a task you allotted, your own record is closed automatically with their note.
- Allotments are never deleted, so the history works as an audit trail.

## Circle messaging (💬 in the Circle tab)
- **🔒 Private chat:** tap a member's name (or their row under *Private chats*). Messages are visible **only to you and that inspector**; other circle members cannot see or fetch them. ✓ Sent / ✓✓ Read receipts.
- **📢 Circle announcement:** *Message all circle members*. Posts are visible to **every member of that circle**, shown in orange and labelled as an announcement so they are never confused with private chats.
- **Unread badges:** separately per member and for announcements, plus the total on the Circle tab and a card on Home. Read marks for announcements are saved to your profile, so they stay read on your other devices.
- **Live:** new messages and read receipts arrive automatically through Supabase Realtime (green dot). If Realtime is unavailable, the app checks every 20 seconds instead (grey dot). On a computer, Ctrl / ⌘ + Enter sends.
- Messages cannot be edited or deleted by anyone. They never include farmer, animal or payment records unless you type them yourself.

## History
- **Animal page → 📜 Clinical history timeline:** every treatment, follow-up visit, closure note, AI, PD result, feed supply, weight check and animal event, newest first.
- **Farmer page → 📜 Clinical history · all animals of this farmer:** the same, for all of that farmer's animals together.
- **📜 Activity log** (Home, Tracker, or 👤 profile): your own actions, newest first: treatments, AI & PD, follow-ups scheduled / closed, feed & weight, payments received, animal events, and circle tasks (allotted, accepted, declined, closed, follow-up set). Filter by type, by 7 / 30 / 90 days / all time, or search; tap an event to open the animal. It is built from your own private records, so only you see it.

## Mark as Aborted (confirmed pregnancies)
- **⚠️ Mark as Aborted** is on every confirmed pregnancy: the animal's AI card, the pregnancy page, pregnancy reminders in the Tracker / Home, and the 🔔 popup cards.
- Enter the **abortion date** (today by default, editable) and the **reason / clinical notes** (required). Saving changes the status from Confirmed to **Aborted** and permanently stops that pregnancy's calving-date, 10 / 20-day and 1-day reminders. Other pregnancies are not affected.
- Optional **post-abortion follow-up / next heat check** date and note: it goes into your Follow-Up Tracker with the normal 1-day-before reminder and WhatsApp / SMS options.
- The abortion (date and notes) shows in the animal's AI card, its clinical timeline, the farmer's timeline and your 📜 Activity log. **↩ Undo "Aborted"** restores the pregnancy if it was marked by mistake.

## Reminder popup (🔔)
- When the app opens (and every 30 seconds while it is open) a popup lists reminders that are **due tomorrow, today or overdue**: treatment and AI follow-ups, PD checks, repeat AI dates, pregnancy follow-ups, expected due dates and 3-month weight checks.
- Expected due dates also pop up during your **10 / 20-day advance window**, and again as a separate **1-day-before** alert.
- The **daily AI target** (default 20 / month) shows once a day while AIs remain.
- **💤 Snooze:** 2 hours, until tomorrow 8 AM, or 1 day. It pops up again when the time is up.
- **🔕 Stop:** silences that reminder for that date (the AI target is stopped for the rest of the month). If the date is changed later, a new reminder is created.
- Snooze / Stop never change your records. They are saved to your Supabase profile, so they stay after refresh, re-login or on another device.
- The **🔔 bell** in the header shows how many reminders need attention and lists snoozed / stopped ones with a **Resume** button.
- No payment information is ever included in reminders or in messages to farmers.

## ₹99/month subscription (⭐ chip in the header)
| Plan | What works |
|---|---|
| 🧪 **Trial** (every new inspector, no time limit) | Up to 5 farmers and 5 animals, treatments, AI / PD, feed, payments, reminders, Mark as Aborted. Activity log shows the latest 10 events. Inspector Circle, task allotment and circle chat show **“Pro Feature — Upgrade for ₹99/month”**. |
| ⭐ **Pro** (`active`, 30 days per ₹99) | Everything. Days left show in the header chip and the profile. 5 days before the end a renew banner appears; a renewal is added after the current end date. |
| ⛔ **Expired** (end date passed or revoked) | **Nothing is deleted.** All records stay visible; adding / editing / deleting is paused and Pro features lock, with **“Subscription Expired — Renew ₹99/month to Continue”**. Everything resumes immediately after renewal. |

**How an inspector pays:** ⭐ chip → pay ₹99 to your UPI ID / QR → paste the UPI transaction / reference ID (UTR) → **Submit for verification** (shows *Pending Verification*).

**How you approve (admin only):** your account shows 🛡 in the header and a “payment requests waiting” banner on Home. Open **🛡 Subscription Manager** → check the UPI reference in your bank / UPI app → **✅ Activate 30 Days** (or **✕ Reject** with a reason). For any inspector you can also **+30 days**, **Extend…** (any number of days) or **Revoke**. Set your **UPI ID, payee name and QR image** once under **⚙ Payment settings** in the Subscription Manager.

**Security:** the rules are enforced by Supabase itself, not only by the app — inspectors can read only their own subscription, cannot change it, cannot reuse a UPI reference, and the database refuses circle / chat use without Pro, more than 5 farmers or animals on trial, and any record change when expired. Only accounts listed in `app_admins` can approve. The admin screen shows only names, contact details and plan status — never anyone's clinical or payment records.

**Automatic payments later (Razorpay):** a Supabase Edge Function that verifies the Razorpay webhook signature can call `select public.apply_provider_payment('<user id>', 'razorpay', '<payment id>', '<order id>', 99, 30);` with the service-role key. It extends `subscription_end` by 30 days and ignores a payment id it has already applied.

## Help & Support + User Directory
* **Inspectors:** 🛟 *Help & Support* (Home card, Profile, Subscription screen) shows your support email and phone (tap to call / email / copy) and a private chat with you. Replies arrive live; a red badge shows unread replies. Works on every plan, including expired.
* **Admin (you):** *Admin → 👥 Users* lists everyone who registered — name, office, designation, area, age, email, phone, plan, registration date, last login, last seen / 🟢 online now — with 📞 one-tap call, WhatsApp, email and copy. *Admin → 🛟 Support* is the inbox (All / Unread, search); open a thread to read and reply. Set the support email and phone under *⚙ Support email & phone*.
* Passwords are never stored or shown — they stay inside Supabase Auth. Each inspector can read only their own profile and support thread; only `app_admins` see the directory and all threads.

## Security
* Every table has row-level security: inspectors see only their own records (`auth.uid() = user_id`); circle members see only the tasks sent between them and the messages meant for them.
* Plans are enforced by the database (expired = read-only, trial limits, Circle needs Pro); nobody can activate Pro except the admin.
* `vercel.json` adds security headers on Vercel (Content-Security-Policy, no framing, nosniff, HSTS). `index.html` also carries the Content-Security-Policy, so GitHub Pages is covered too. If you change Supabase project, update the project address in both.
* Supabase dashboard: keep **Confirm email** on, set **Site URL / Redirect URLs** to your app address only, use a strong unique password for the admin account.

## Saving and offline use
- Every change is saved to the cloud automatically. The badge in the header shows **☁️ Saved**, **⏳ Saving…** or **⚠️ Offline**.
- Without internet, changes are kept on the device and uploaded automatically when the connection returns. Don't log out while offline, or the changes stay on that device until you log in there again.
- Records saved on a phone before cloud login are offered for upload after the first login. The copy on the phone is kept.
- New accounts start with a completely **empty workspace**: no sample or demo records are ever added. Sample records left over from earlier test versions are removed automatically at login.

## Database tables
Subscription tables: `subscriptions` (one row per inspector: `subscription_status`, `plan_price`, `subscription_start`, `subscription_end`, `upi_ref_id`, `request_status` …), `subscription_payments` (every UPI / Razorpay payment), `app_settings` (your UPI ID, payee name, QR, price ₹99, 30 days, trial limit 5) and `app_admins` (you).

`profiles`, `farmers`, `animals`, `treatments`, `ai_records` (AI + PD Check + repeat AI + pregnancy), `feed_supplies`. Every record table has `user_id` linked to `auth.users(id)` and Row Level Security. The full record is stored in the `data` column, and readable columns such as name, dates, amount and payment status are filled in automatically for viewing and export in Supabase's Table Editor.
