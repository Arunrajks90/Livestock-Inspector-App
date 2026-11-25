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

`supabase-setup.sql`, `supabase-circles.sql` and `supabase-messages.sql` are **not** part of the website. Run them in Supabase (below); you do not need to upload them.

**Uploading on github.com:** open the repository → **Add file → Upload files** → drag in `index.html`, `manifest.json`, `sw.js` and `README.md`, then commit. For the icons, choose **Add file → Upload files** again and drag the whole `icons` folder in (or unzip `field-officer-pwa.zip` and drag all of its contents at once). The file names must stay exactly as shown.

## One-time Supabase setup
1. Open your project at [supabase.com](https://supabase.com) → **SQL Editor** → **New query**. Paste the whole of `supabase-setup.sql` and click **Run**. Then do the same with `supabase-circles.sql` (Inspector Circle and task handover) and then `supabase-messages.sql` (circle messaging). All are safe to run again later.
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
- **Returned to the sender:** the sender sees it under **↩ Returned to you** (also on Home, the Circle badge and the 🔔 popup) with the closed date and description, and taps **📅 Set next follow-up** (or **No further follow-up**). As soon as the date is saved, the follow-up **appears in the sender's 📅 Tracker** (the app opens it there), labelled **↩ After handover**, with the normal 1-day-before reminders; the Tracker also lists tasks still waiting for a date, and has an **↩ After handover** filter. In Supabase the same list is in the private view **my_follow_up_tracker**. The next follow-up date is saved **only in the sender's own records**, so its reminders belong to the sender alone and the assignee never sees it. An AI done by a colleague is recorded with its PD date but does not count toward the sender's monthly AI target.
- **✔ Mark closed** (on your own pending follow-ups and on allotted tasks) records a closure description, for example *"Completed by another person — confirmed with farmer on call"*. The record stays, the note is added to the animal's history, and the reminder stops. When a colleague closes a task you allotted, your own record is closed automatically with their note.
- Allotments are never deleted, so the history works as an audit trail.

## Circle messaging (💬 in the Circle tab)
- **🔒 Private chat:** tap a member's name (or their row under *Private chats*). Messages are visible **only to you and that inspector**; other circle members cannot see or fetch them. ✓ Sent / ✓✓ Read receipts.
- **📢 Circle announcement:** *Message all circle members*. Posts are visible to **every member of that circle**, shown in orange and labelled as an announcement so they are never confused with private chats.
- **Unread badges:** separately per member and for announcements, plus the total on the Circle tab and a card on Home. Read marks for announcements are saved to your profile, so they stay read on your other devices.
- **Live:** new messages and read receipts arrive automatically through Supabase Realtime (green dot). If Realtime is unavailable, the app checks every 20 seconds instead (grey dot). On a computer, Ctrl / ⌘ + Enter sends.
- Messages cannot be edited or deleted by anyone. They never include farmer, animal or payment records unless you type them yourself.

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
