# Poker Ledger — Project Guide

> **Authoritative reference.** This file is a strict superset of `CLAUDE.md`. Start here; check `index.html` for implementation details. Update this file whenever the code changes.

---

## Table of Contents

1. [What This Is](#1-what-this-is)
2. [Architecture](#2-architecture)
3. [Locked Accounting Decisions](#3-locked-accounting-decisions)
4. [Data Model](#4-data-model)
5. [The Accounting Engine](#5-the-accounting-engine)
6. [Key Flows](#6-key-flows)
7. [Invariants That Must Hold](#7-invariants-that-must-hold)
8. [Risk Map (Read Before Editing)](#8-risk-map-read-before-editing)
9. [Conventions](#9-conventions)
10. [Dev & Deploy Workflow](#10-dev--deploy-workflow)
11. [Current Feature Inventory](#11-current-feature-inventory)
12. [Known Limitations & Gotchas](#12-known-limitations--gotchas)
13. [How to Make a Safe Change](#13-how-to-make-a-safe-change)
14. [Glossary](#14-glossary)

---

## 1. What This Is

A **mobile-first poker ledger web app** for a private friend group. It tracks buy-ins, cashouts, transfers, and shared expenses across sessions, and maintains a rolling global balance (the "ledger") per player.

**What it is NOT:** not a poker game, not a betting platform, not a general-purpose accounting tool.

**Problem it replaces:** manual bookkeeping done in a WhatsApp group chat — tallying who owes whom after every session and who fronted shared expenses (food, drinks, venue). The app automates that math and shares results back to WhatsApp with one tap.

**Two user types:**
- **Admin** — logs in with email + password (Supabase Auth). Can create sessions, record events, close sessions, post to the ledger, and record settlements. Any authenticated user has full admin write access.
- **Viewer (friends)** — opens the public URL without logging in. Gets the Ledger, Live, History, and Leaderboards screens in read-only mode. No login required.

---

## 2. Architecture

### Stack

| Layer | Technology |
|---|---|
| HTML/CSS | Single `index.html` · Tailwind CSS via Play CDN |
| JavaScript | Vanilla JS, no framework, no build step, no bundler |
| Backend | Supabase (free tier): Postgres + Auth |
| Client library | `@supabase/supabase-js` v2 via jsDelivr CDN |
| Live updates | `setInterval` polling every ~4 s — NOT realtime subscriptions |
| Hosting | GitHub Pages (public repo, static file serving) |
| Money unit | Integer rupees, minimum ₹10. All values are stored and displayed as ₹10-clean integers. |

### Supabase client

```js
const { createClient } = window.supabase;
let db = null;
try { db = createClient(SUPABASE_URL, SUPABASE_ANON_KEY); } catch (e) { ... }
```

The variable `db` is the Supabase client used everywhere. All data-layer helpers call `dbQuery(label, fn)` which guards against `db === null`. The anon key in the file is public-safe — Supabase Row Level Security enforces all write restrictions server-side.

### `index.html` section layout (do not reorder)

```
// === CONFIG ===          SUPABASE_URL, SUPABASE_ANON_KEY, db client init
// === STATE ===           Single `state` object — all runtime state lives here
// === ACCOUNTING ENGINE   Pure math functions (chunk 2) — no I/O
// === DATA LAYER          Async DB helpers: read + write wrappers (chunk 3)
// === ADMIN UI            Admin-only render + interaction logic (chunk 4)
// === VIEWER UI           Public viewer screens + nav (chunk 5)
// === NAV / INIT          showScreen(), refreshData() polling loop, DOMContentLoaded wiring
```

### Screens

| Screen | Element ID | Purpose |
|---|---|---|
| Ledger | `screen-ledger` | Global player balances + WhatsApp share |
| Live | `screen-live` | Active session(s) — running totals (public) |
| History | `screen-history` | Finalized sessions + settlements toggle |
| Leaderboards | `screen-leaderboards` | Stats, standings, attendance |
| Admin | `screen-admin` | Login + all write controls |

---

## 3. Locked Accounting Decisions

> **Crown jewels. Do not modify these rules without deliberate, explicit discussion. They are not implementation details — they are the product.**

### Settlement — Water-filling

Settlement distributes a payment using **water-filling**: find all players with positive balances, reduce the highest ones down to the level of the next-highest tier until the payment amount is fully consumed.

- This is **not** proportional split.
- Settlements are **standalone ledger transactions** applied immediately.
- They are **not** session events and are **not** gated by "Update Ledger".
- Overpay beyond flattening all positive balances to zero → the remainder is held as the payer's positive credit on the ledger (rare; handled simply).

### Transfer

- The payer's (`player_id`) session result is increased by the amount (like a cashout — they gave chips away).
- The receiver's (`counterparty_id`) session result is decreased by the amount (like a buy-in — they received chips).
- Net-zero across both players.

### Expense

- The fronter (`player_id`) is reimbursed in full in their session net.
- Positive-net players are debited proportional shares of the total expense (proportional to their gross profit).
- Expense shares are computed at session finalize ("Update Ledger"), not in real-time.
- **If NO profitable players exist** → admin must manually set the split before posting. The app defaults the suggested split to equal shares among all players, but blocks posting until the override is explicitly applied.

### Session net per player

```
net = (cashouts + chips transferred out + expense reimbursement)
    − (buy-ins + rebuys + chips transferred in + expense share)
```

Where:
- `gross = cashouts + transfers_out − buy-ins − rebuys − transfers_in`
- `net = gross − expenseShare + reimbursement`

### Ledger posting — "Update Ledger"

- Each player's session net is **added** to their global balance (`ledger_balances`).
- Only triggered explicitly by the admin after a session is **closed**.
- Once closed, sessions are **immutable forever** — no new events can be added.
- Multiple sessions can run simultaneously.
- A chip imbalance warning is shown at close (chipsIn ≠ chipsOut) but it is **non-blocking** — admin can close anyway.

### Global ledger changes ONLY on

1. **Settlements** — applied immediately when confirmed.
2. **"Update Ledger"** — applied after a session is closed and admin clicks Confirm Post.

Nothing else writes to `ledger_balances`.

### Rounding

- All distribution math rounds each individual output to the nearest ₹10 (half-up towards +∞ at exactly .5).
- The rounding remainder (sum of rounded values vs. the exact total) is assigned to the player with the **largest weight** (first on tie).
- This ensures totals are always exact.

### Accounting functions

Must be **pure** (no I/O, no side effects), grouped in the `ACCOUNTING ENGINE` section of `index.html`.

---

## 4. Data Model

All tables live in Supabase Postgres. Schema is in `schema.sql`.

### `players`

| Column | Type | Notes |
|---|---|---|
| `id` | uuid PK | `gen_random_uuid()` |
| `name` | text | Not null |
| `created_at` | timestamptz | Default now() |

### `sessions`

| Column | Type | Notes |
|---|---|---|
| `id` | uuid PK | |
| `name` | text | Not null |
| `status` | text | `active` → `closed` → `finalized` |
| `created_at` | timestamptz | |
| `closed_at` | timestamptz | Set when status → closed |
| `finalized_at` | timestamptz | Set when status → finalized |

### `session_events`

| Column | Type | Notes |
|---|---|---|
| `id` | uuid PK | |
| `session_id` | uuid FK → sessions | |
| `type` | text | `buyin` \| `rebuy` \| `cashout` \| `transfer` \| `expense` |
| `player_id` | uuid FK → players | Primary actor; "fronted by" for expense; "from" for transfer |
| `counterparty_id` | uuid FK → players | Transfer recipient only; null for other types |
| `amount` | integer | Whole rupees, minimum ₹10 |
| `note` | text | Optional |
| `created_at` | timestamptz | |
| `deleted_at` | timestamptz | Soft-delete for undo; null = not deleted |

**Notes:**
- `rebuy` is a legacy type. It is still counted in accounting (treated identically to `buyin`) but the UI no longer exposes a "Rebuy" entry button.
- Soft-deleted events (`deleted_at IS NOT NULL`) are ignored by all accounting logic.

### `settlements`

| Column | Type | Notes |
|---|---|---|
| `id` | uuid PK | |
| `payer_id` | uuid FK → players | |
| `amount` | integer | Total paid |
| `distribution` | jsonb | `{ "playerId": amountReceived, ... }` — only recipients with `amount > 0` |
| `created_at` | timestamptz | |

### `ledger_balances`

| Column | Type | Notes |
|---|---|---|
| `player_id` | uuid PK FK → players | One row per player |
| `balance` | integer | Running total in rupees |
| `updated_at` | timestamptz | |

Written via upsert (`onConflict: "player_id"`).

### `session_results`

| Column | Type | Notes |
|---|---|---|
| `id` | uuid PK | |
| `session_id` | uuid FK → sessions | |
| `player_id` | uuid FK → players | |
| `net` | integer | The player's net for this session |
| `created_at` | timestamptz | |

Written during "Update Ledger". Also serves as the **idempotency marker** — if rows already exist for a session, the session has already been posted and must not be posted again.

### RLS posture

- **SELECT**: everyone, including anonymous (anon key) users.
- **INSERT / UPDATE / DELETE**: authenticated users only.

This means **any logged-in Supabase user is a full admin** with complete write access to all tables. There is no per-user permission scoping beyond authenticated vs. anonymous.

---

## 5. The Accounting Engine

All functions are in the `=== ACCOUNTING ENGINE (chunk 2) ===` section. They are **pure** (no I/O, no state reads, no DOM access). Do not modify them casually — they define the financial rules of the app.

### `roundToTen(amount)`

```js
function roundToTen(amount) → integer
```

Rounds `amount` to the nearest multiple of 10, half-up towards +∞ at exactly .5. Used internally by `splitProportional`.

### `formatINR(amount)`

```js
function formatINR(amount) → string
```

Indian number formatting (last 3 digits, then groups of 2 from right) with ₹ prefix and sign. Example: `formatINR(-12345)` → `"-₹12,345"`.

### `splitProportional(total, recipients)`

```js
function splitProportional(total, recipients) → { [id]: share }
// recipients: [{ id: string, weight: number }]
```

Distributes `total` among recipients proportional to their `weight`. Each share is rounded to ₹10. The rounding remainder is added to the recipient with the largest weight (first on tie). All shares sum exactly to `total`.

### `computeSessionResults(players, events, expenseOverride)`

```js
function computeSessionResults(players, events, expenseOverride) → {
  perPlayer: {
    [playerId]: {
      gross:          integer,   // cashouts + transfers_out − buy-ins − rebuys − transfers_in
      expenseShare:   integer,   // share of total expense this player bears
      reimbursement:  integer,   // total expense this player fronted (repaid in full)
      net:            integer,   // gross − expenseShare + reimbursement
    }
  },
  totalExpense:         integer,   // sum of all non-deleted expense event amounts
  needsExpenseOverride: boolean,   // true when totalExpense > 0 but no player has gross > 0
  suggestedEqualSplit:  { [playerId]: integer }  // equal split (used when needsExpenseOverride)
}
// expenseOverride: optional { [playerId]: amount } — overrides auto expense split completely
```

- Filters soft-deleted events first (`!e.deleted_at`).
- `players` array determines which player IDs appear in `perPlayer` output.
- When `expenseOverride` is provided, it takes precedence over both proportional and equal-split calculations.
- `suggestedEqualSplit` is populated only when `needsExpenseOverride === true`.

### `distributeSettlement(balances, payerId, amount)`

```js
function distributeSettlement(balances, payerId, amount) → {
  received:      { [playerId]: amountReceived },   // only players who received > 0
  balancesAfter: { [playerId]: newBalance },        // all players (payer balance = old + amount)
  leftover:      integer,                          // unallocated overpay remainder
}
// balances: { [playerId]: integer } — current ledger balances
```

Water-filling: repeatedly levels down the highest positive balance(s) until `amount` is consumed. Uses `splitProportional` for the final partial distribution within a tier. `balancesAfter[payerId] = balances[payerId] + amount` (the payer's balance increases by what they paid, reflecting that they now have a credit if they overpaid everyone to zero).

### `checkTableBalance(events)`

```js
function checkTableBalance(events) → {
  chipsIn:    integer,
  chipsOut:   integer,
  balanced:   boolean,
  difference: integer   // chipsIn − chipsOut
}
```

Counts only `buyin` and `rebuy` events as chips in, only `cashout` events as chips out. Transfers and expenses are excluded. Soft-deleted events are excluded.

### `runEngineTests()`

```js
function runEngineTests() → { passed, failed, total, tests }
```

Self-test harness covering water-fill settlement, expense proportional split, transfer net-zero, `roundToTen` edge cases, overpay leftover, no-winners override flag, and chip balance. Run from the browser console at any time to catch regressions: `runEngineTests()`.

---

## 6. Key Flows

### Session lifecycle

```
active  →[confirmCloseSession]→  closed  →[confirmUpdateLedger]→  finalized
```

- **active**: events can be added/edited/undone; session can be closed.
- **closed**: immutable (no new events); "Update Ledger" button appears; session can be posted.
- **finalized**: immutable forever; appears in History; contributes to Leaderboards.

### Event entry and undo

`submitEvent()` validates input (`validateAmount()`, player selection, transfer self-check), calls `createSessionEvent()`, then calls `refreshSessionEvents()` which re-fetches, unions roster, and re-renders log + totals + expense panel.

Undo calls `softDeleteSessionEvent(id)` (sets `deleted_at`) then `refreshSessionEvents()`. Edit calls `updateSessionEvent(id, { amount, note })`.

### Close session

`initiateCloseSession()` calls `checkTableBalance()` on `state.openSessionEvents`. Shows a confirmation dialog with the chip imbalance warning if unbalanced (non-blocking). On confirm, `confirmCloseSession()` calls `updateSession(id, { status: 'closed', closed_at })` then refreshes.

### Update Ledger posting

`confirmUpdateLedger()` in this exact order:

1. **Status guard**: session must be `status === 'closed'`; aborts otherwise.
2. **Idempotency guard**: calls `getSessionResults(sessionId)`; if any rows exist, aborts with "Ledger already posted."
3. **No-winners guard**: if `totalExpense > 0 && needsExpenseOverride && !sessionOverride`, aborts with a message asking admin to set the split in the expense panel.
4. **Override validation**: if an override is set, verifies all values are ₹10-clean and sum exactly to `totalExpense`; aborts if not.
5. **Write session_results first** (these are the idempotency marker — if the process crashes here, the next attempt is caught by guard #2 above).
6. **Write ledger_balances** via `upsertLedgerBalance(player_id, curBal + net)` for each player.
7. **Write session status = 'finalized'** via `updateSession`.

### Standalone settlements

`previewSettlement()` → calls `distributeSettlement(balances, payerId, amount)` → stores result in `settlementDraft` → renders distribution table.

Optional: admin clicks "Edit recipients" → `toggleSettlementEdit()` opens inline editor → `applySettlementRecipients()` manually recomputes `balancesAfter` (does NOT re-call `distributeSettlement`) and updates `settlementDraft`.

`confirmSettlement()` → calls `createSettlement(payer_id, amount, received)` → calls `upsertLedgerBalance` for payer and all recipients using `settlementDraft.balancesAfter` → refreshes state.

### Polling loop

`setInterval(refreshData, 4000)` — every ~4 s, `refreshData()` fetches all tables in parallel, updates the `state` object, then calls `renderAll()`. `renderAll()` only re-renders the currently visible viewer screen plus admin controls. An `isRefreshing` guard prevents concurrent overlapping fetches.

### Auth gating

On page load: `db.auth.getSession()` restores any existing session. `db.auth.onAuthStateChange()` keeps `state.isAdmin` in sync. `applyAuthGate()` shows/hides `#admin-login-area` vs. `#admin-controls`. All write operations are protected server-side by RLS; the `state.isAdmin` flag only controls UI visibility.

---

## 7. Invariants That Must Hold

- **Global ledger sums to ₹0** in normal operation. The only legitimate non-zero total is an overpay credit held on the payer's balance after a settlement where all winners have been paid to zero.
- **Each session's nets sum to ₹0** — verified by `runEngineTests()` tests b and c.
- **Money is always integer and ₹10-clean** — enforced by `validateAmount()` at entry and `roundToTen()` in the engine.
- **Closed and finalized sessions are immutable** — enforced by UI guards (entry form hidden) and by `confirmUpdateLedger` status check.
- **The ledger is never double-posted** — enforced by the `getSessionResults` idempotency check in `confirmUpdateLedger` and `showUpdateLedgerPreview`.
- **Settlements preserve net-zero**: payer's balance increases by `amount`; each recipient's balance decreases by exactly what they received; no recipient receives more than their current balance (manual edit enforces `v <= maxAllowed = floor(bal / 10) * 10`).
- **Polling re-renders must never clobber in-progress form input** — enforced by the inline-editor pattern: form inputs update `state.editDraft` / `state.expenseEditDraft` / `state.settlementEditDraft` via `oninput`; the render reads from those draft objects so a poll tick rewrites identical values into the inputs (or skips re-rendering the input element entirely via surgical DOM update).
- **Auth is role-based**: any authenticated Supabase user has full admin write access. There is no per-user permission scoping.

---

## 8. Risk Map (Read Before Editing)

### LOW RISK — safe to change freely

- Viewer screens: `renderLedger`, `renderLive`, `renderHistory`, `renderLeaderboards`
- Leaderboards: labels, sort orders, stat thresholds, time-window options
- WhatsApp export text (`buildLedgerText`)
- History display: session card layout, expense borne-by display
- Toast notifications (`showToast`)
- Color palette (green/red/gray constants)
- Nav labels, icons, screen names
- `SETUP.md`, documentation

### HIGH RISK — accounting-critical

- **The entire `ACCOUNTING ENGINE` section**: `roundToTen`, `formatINR`, `splitProportional`, `computeSessionResults`, `distributeSettlement`, `checkTableBalance`. Any change here changes the financial rules of the app.
- **`confirmUpdateLedger`**: the guards, write order, and validation are there for a reason. Preserve them exactly.
- **`confirmSettlement` and `applySettlementRecipients`**: these write `ledger_balances` directly. Ensure net-zero is maintained.
- **Anything that calls `upsertLedgerBalance` or `createSessionResult`** — these are the only two functions that change stored financial state.

**Rule of thumb:** UI/display code → edit freely. Any code that computes or writes money → extreme caution. Preserve all guards, verify nets sum to ₹0, run `runEngineTests()` after any engine change.

---

## 9. Conventions

- **`db`** — the Supabase client variable. All DB calls go through `dbQuery(label, fn)` which guards `db === null`.
- **`formatINR(amount)`** — used everywhere money is displayed. Never format amounts by hand.
- **Color coding**: green (`text-green-400`) for positive, red (`text-red-400`) for negative, gray (`text-gray-400`) for zero.
- **State-driven rendering**: the single `state` object is the source of truth. Poll ticks call `renderAll()` which re-derives HTML from `state`. No cached DOM state.
- **Poll-safe inline editors**: inputs write to `state.editDraft`, `state.expenseEditDraft`, or `state.settlementEditDraft` via `oninput`. Renders read from these drafts, so poll ticks preserve typing. For validation feedback (sum display, button enable/disable), the editor does a surgical DOM patch rather than a full re-render to avoid focus loss.
- **`window` registration**: functions called from `onclick` in dynamically-generated HTML must be registered on `window`. The block at the end of chunk 4 handles this. If you add a new function used in dynamic HTML, add `window.yourFn = yourFn` there. Note: top-level function declarations in non-module scripts are implicitly on `window` (e.g., `openLedgerWhatsApp` is called from dynamic HTML without explicit registration).
- **All state is in `state` + Supabase** — no `localStorage`, no cookies.
- **`expenseOverride`** is stored in-memory only (`state.expenseOverride[sessionId]`). It is never persisted to the database. It is lost on page reload before posting.

---

## 10. Dev & Deploy Workflow

1. Edit `index.html`.
2. `git add index.html && git commit -m "..." && git push`
3. GitHub Pages auto-deploys in ~1 minute.
4. Hard-refresh (`Ctrl+F5`) to pick up the new file (CDN/browser cache).

**Local testing:** serve via HTTP — `python -m http.server 8080` then open `http://localhost:8080`. Do not open `index.html` as `file://` — Supabase Auth requires an HTTP origin and will fail.

**Config values in `index.html`:**

```js
const SUPABASE_URL      = "https://xxxx.supabase.co";
const SUPABASE_ANON_KEY = "eyJ...";
```

Both values come from Supabase → Project Settings → API. The anon key is safe to commit (RLS protects all writes). The admin password lives only in Supabase Auth, never in the file.

**Adding a new admin:** Supabase dashboard → Authentication → Users → Add user (enter email + password, auto-confirm). Public sign-ups must stay **OFF** — if enabled, anyone could register and gain write access.

**Browser console testing:** `runEngineTests()` runs the accounting engine self-tests and logs pass/fail to the console.

---

## 11. Current Feature Inventory

- **Rolling ledger** — global balance per player; WhatsApp share button.
- **Sessions** — create, manage, view active sessions; event log; live totals panel.
- **4 event types** — Buy-in, Cashout, Transfer (net-zero chip move), Expense (fronted cost).
- **Event edit + undo** — inline edit (amount + note) and soft-delete undo for active sessions.
- **Session close** — with chips-in ≠ chips-out warning (non-blocking).
- **Update Ledger** — posts session nets to global balances with preview + confirm.
- **Expense split panel** — shows fronter vs. bearers breakdown; supports manual override with live sum validation; visible while session is active or closed.
- **Standalone settlements** — water-fill default; optional manual recipient edit; applied immediately to ledger.
- **History screen** — Sessions/Settlements toggle; finalized session cards with expense fronted-vs-borne detail.
- **Leaderboards** — Week/Month/All time toggle; standings (net, avg per session); attendance board (games played, win rate); biggest single-session win/loss (all-time).
- **Multi-admin** — any authenticated Supabase user has full write access.
- **Polling** — ~4 s refresh keeps all viewers in sync without websockets.

---

## 12. Known Limitations & Gotchas

**Partial-failure "stuck post" edge case.** `confirmUpdateLedger` writes `session_results` first (as the idempotency marker), then `ledger_balances`, then sets status to `finalized`. If the `ledger_balances` write fails after `session_results` has already been written, the session is left in `closed` status with `session_results` present. The idempotency guard will then block any future post attempt, leaving the ledger inconsistently updated. This is rare and would require manual Supabase intervention to resolve.

**`expenseOverrideDraft` is dead/legacy.** `state.expenseOverrideDraft` is explicitly commented `"unused legacy — kept for confirmUpdateLedger reference only"`. Do not use it. The live expense override path uses `state.expenseOverride[sessionId]`.

**In-memory expense override.** `state.expenseOverride` is never persisted to the database. If the admin sets a manual override, navigates away, or the page reloads before posting, the override is lost and must be re-entered.

**Settlement confirm uses last-applied split.** `confirmSettlement()` uses whatever is in `settlementDraft` at confirm time — whether that's the original water-fill output or a manually edited recipient split from `applySettlementRecipients()`. If the admin clicks "Edit recipients," sets values, but then cancels without clicking "Apply," the original water-fill split is used. The UI does not warn about this.

**No per-user audit trail.** All write operations are performed with the Supabase `authenticated` role. There is no record of which admin made which change.

**`rebuy` event type is legacy.** The entry form no longer shows a "Rebuy" button, but existing `rebuy` events in the database are still counted correctly in `computeSessionResults` (treated identically to `buyin`).

**`openLedgerWhatsApp` is called from dynamic HTML** without explicit `window.openLedgerWhatsApp = openLedgerWhatsApp` registration. This works because it is a top-level function declaration in a non-module script (implicitly global), but it is inconsistent with the pattern used for other dynamically-called functions.

---

## 13. How to Make a Safe Change

1. **Read this guide** to understand what you're touching.
2. **Read the relevant section of `index.html`** — locate the function(s) involved.
3. **Classify the risk** using Section 8. If it's a money path, treat it as HIGH RISK.
4. **Prefer additive changes** — add new UI elements or new display functions rather than modifying existing ones.
5. **Keep money integer and ₹10-clean** — never store or display fractional rupees. Use `validateAmount()` for user input and `roundToTen()` / `splitProportional()` for computed distributions.
6. **Keep rendering poll-safe** — if you add an inline editor, store draft values in `state` (not just in the DOM) so that poll ticks rewrite the same values and do not clobber typing.
7. **For any money path:** preserve the existing guards and write order in `confirmUpdateLedger` and `confirmSettlement`; verify that nets sum to ₹0; run `runEngineTests()` in the browser console.
8. **Register dynamic-HTML onclick functions on `window`** — add `window.yourFn = yourFn` to the registration block at the end of chunk 4.
9. **Test locally via HTTP** (not `file://`) before pushing.
10. **Update this guide** when the code changes — keep function signatures, table columns, and feature inventory in sync.

---

## 14. Glossary

| Term | Definition |
|---|---|
| **Fronter** | The player who paid an expense (food, venue, etc.) out of pocket on behalf of the group. They are reimbursed in full via their session net. |
| **Bearer** | A player who has a positive gross profit and therefore is debited a share of the group's total expense. |
| **Water-fill** | The settlement distribution algorithm: repeatedly level down the highest positive balance(s) until the payment is consumed. Ensures the most-owed player gets paid first. |
| **Gross** | A player's net chips result before expense adjustments: `cashouts + transfers_out − buy-ins − rebuys − transfers_in`. |
| **Net** | A player's final session result after expense: `gross − expenseShare + reimbursement`. This is what gets posted to the ledger. |
| **Expense share** | The portion of the total expense that a specific player bears (deducted from their net). |
| **Reimbursement** | The total expense amount a player fronted; added back to their net so they break even on it. |
| **Override** | An admin-set manual expense split that replaces the automatic proportional/equal calculation. Stored in `state.expenseOverride[sessionId]` — in-memory only until posting. |
| **Finalize / Post** | The "Update Ledger" action: writes session nets to `session_results` and `ledger_balances`, then sets session status to `finalized`. |
| **Rolling ledger** | The persistent global balance table (`ledger_balances`). Each player's balance reflects the sum of all their session nets and settlements over all time. |
