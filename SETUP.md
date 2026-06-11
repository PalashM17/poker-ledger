# Setup Guide

## 1. Create Supabase project & run schema

1. Go to [supabase.com](https://supabase.com) → New project (free tier is fine).
2. In the SQL Editor, paste the entire contents of `schema.sql` and click **Run**.

## 2. Create the admin user

1. In your Supabase project → **Authentication → Users → Add user**.
2. Enter an email and password. This is the only account; keep it safe.

## 3. Wire up `index.html`

Open `index.html` and fill in the CONFIG block near the top of the `<script>`:

```js
const SUPABASE_URL      = "https://xxxx.supabase.co";
const SUPABASE_ANON_KEY = "eyJ...";
```

Both values are in your Supabase project → **Project Settings → API**.  
The anon key is safe to commit — Row Level Security enforces all write restrictions.

## 4. Push to GitHub

```bash
git init
git add .
git commit -m "initial skeleton"
gh repo create poker-ledger --public --source=. --remote=origin --push
# or manually:
# git remote add origin https://github.com/YOUR_USERNAME/poker-ledger.git
# git push -u origin main
```

## 5. Enable GitHub Pages

In your GitHub repo → **Settings → Pages → Branch: main / folder: / (root)** → Save.  
Your app will be live at `https://YOUR_USERNAME.github.io/poker-ledger/`.

Share that URL with friends — they get the read-only view automatically.  
You log in via the Admin tab using the credentials from step 2.
