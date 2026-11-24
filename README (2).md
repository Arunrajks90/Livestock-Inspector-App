# Livestock Inspector – Field Officer App

A single-file web app (`index.html`) for Livestock Inspectors to manage farmers, animals, treatments, artificial insemination (AI), PD checks, free feed supply with weight checks, and inspector-only payment tracking. It works offline in any modern browser; there is nothing to install or build.

## Features
- **Farmer → Animal workflow** for every entry: all animals for Treatment and Feed Supply, female animals only for AI and PD Check.
- **Treatment** log with follow-up dates.
- **AI** records with a **monthly target** (default 20) on the dashboard and a daily reminder of the remaining count.
- **PD Check** outcomes:
  - *Not Confirmed* → approximate repeat AI date, with repeat AI reminders.
  - *Confirmed* → a pregnancy page with next follow-up date, expected due date (calculated from the AI date by species, and editable), and a reminder 10 days, 20 days or a custom number of days before the due date.
- **Free Feed Supply** with an automatic 3-month weight check date, reminders, and weight verification that shows growth between readings.
- **Payments (inspector only):** amount, mode, Paid / Pending. Each record keeps its own status, you can mark it paid later, and you get an alert when you pick a farmer who has dues. **No payment messages are ever sent to farmers.**
- **WhatsApp / SMS** pre-filled messages for clinical and service follow-ups only.
- Bright, colourful layout for mobile and desktop.

## Publish on GitHub Pages
1. Create a repository and upload `index.html` (and this README) to the root.
2. Go to **Settings → Pages**, choose **Deploy from a branch**, select `main` / `root`, and save.
3. Open the link GitHub gives you (e.g. `https://<username>.github.io/<repo>/`) on your phone. Use the browser's **Add to Home screen** to keep it like an app.

## Data and login
- All records are saved **in the browser on that device** (localStorage). Different phones or browsers do not share data. Back up regularly from **Data ⚙ → Show export** and restore with **Import pasted**.
- **Sign Up / Login is on.** Inspectors sign up with name, hospital / centre, qualification, age, gender, phone, email, area / panchayat and a password or PIN. They log in with **email ID or phone number**. Profile and Logout are under the name button at the top right. Each inspector sees only their own records.
- **Forgot password / PIN:** enter the registered email ID **and** phone number to set a new one.
- Records saved earlier without logging in are offered to the account at sign-up or login; nothing is deleted.
- Accounts are saved only on the device and passwords are hashed. This is not server-grade security. For testing only, `const AUTH_ON=true;` in `index.html` can be set to `false` to skip login.
- A **sample farmer with 2 animals and one record per module** is added once to each account for testing. Remove it from the yellow **Remove sample data** strip on Home or from **Data ⚙**. Your real records are not affected.
