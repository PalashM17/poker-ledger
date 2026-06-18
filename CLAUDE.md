> **See [`PROJECT_GUIDE.md`](PROJECT_GUIDE.md) for the full authoritative project guide.**

# Poker Ledger — Claude Code Context

## Product summary
A mobile-first poker ledger web app for a private friend group.  
Single admin logs in (Supabase Auth) to write data; everyone else views read-only via a public link.

## Architecture
- **Single file:** `index.html` — no build step, no framework, no bundler.
- **Styling:** Tailwind CSS via Play CDN.
- **Backend:** Supabase (free tier) — Postgres + Auth.
- **Client:** `@supabase/supabase-js` v2 via CDN (jsdelivr).
- **Live updates:** polling every ~4 seconds (`setInterval` re-fetches), NOT realtime subscriptions.
- **Hosting:** GitHub Pages (public repo). No secrets in the file — only the public anon key.
- **Money unit:** integer rupees, minimum ₹10. All storage and display is ₹10-clean.

## Screens
| Screen | Purpose |
|---|---|
| Ledger | Global player balances |
| Live | Active session(s) — events, running totals |
| History | Past finalized sessions |
| Leaderboards | Stats and rankings |
| Admin | Login + all write controls (session mgmt, events, settlements) |

## Script section layout (do not reorder)
```
// === CONFIG ===
// === STATE ===
// === ACCOUNTING ENGINE (chunk 2) ===
// === DATA LAYER (chunk 3) ===
// === ADMIN UI (chunk 4) ===
// === VIEWER UI (chunk 5) ===
// === NAV / INIT ===
```

## LOCKED accounting decisions (do not change without explicit discussion)

### Settlement — Water-filling
Settlement uses **water-filling**: level the top positive balances down to equal footing until the payment amount is consumed. NOT proportional split.  
- Settlements are **standalone ledger transactions** applied immediately.
- NOT session events; NOT gated by "Update Ledger".
- Overpay beyond flattening all winners to zero → hold remainder as the payer's positive credit (rare; keep simple).

### Transfer
- Payer's session result +amount (like a cashout).
- Receiver's session result −amount (like a buy-in).
- Net-zero.

### Expense
- Payer is reimbursed in full.
- Positive-net players are debited proportional shares; net-zero.
- Computed at session finalize.
- If NO profitable players → require admin manual override, defaulting to equal split among all players.

### Session net per player
```
net = (cashouts + chips transferred out + expense reimbursement)
    − (buy-ins + rebuys + chips transferred in + expense share)
```

### Ledger posting — "Update Ledger"
- Each player's session net is added to their global balance.
- Only triggered explicitly by admin after a session is **closed**.
- Closed sessions are **immutable forever** (enforced in app logic).
- Multiple sessions can run simultaneously.
- Warn at session close if chips-in ≠ chips-out.

### Global ledger changes ONLY on
1. Settlements (immediate).
2. "Update Ledger" after a session is closed.

### Rounding
- All distribution math rounds each output to nearest ₹10.
- Remainder (from rounding) assigned to the player with the largest balance.
- Totals stay exact.

### Accounting functions
Must be **pure** (no I/O), grouped in the `ACCOUNTING ENGINE` section.
