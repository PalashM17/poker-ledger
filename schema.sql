-- Poker Ledger — Supabase schema
-- Paste this entire file into the Supabase SQL editor and click Run.

-- ── Tables ────────────────────────────────────────────────────────────────────

create table players (
  id         uuid primary key default gen_random_uuid(),
  name       text not null,
  created_at timestamptz not null default now()
);

create table sessions (
  id           uuid primary key default gen_random_uuid(),
  name         text not null,
  status       text not null default 'active'
                 check (status in ('active', 'closed', 'finalized')),
  created_at   timestamptz not null default now(),
  closed_at    timestamptz,
  finalized_at timestamptz
);

create table session_events (
  id               uuid primary key default gen_random_uuid(),
  session_id       uuid not null references sessions(id),
  type             text not null
                     check (type in ('buyin', 'rebuy', 'cashout', 'transfer', 'expense')),
  player_id        uuid not null references players(id),
  counterparty_id  uuid references players(id),   -- transfer recipient only
  amount           integer not null,               -- whole rupees, minimum ₹10
  note             text,
  created_at       timestamptz not null default now(),
  deleted_at       timestamptz                     -- soft-delete for undo
);

create table settlements (
  id           uuid primary key default gen_random_uuid(),
  payer_id     uuid not null references players(id),
  amount       integer not null,
  distribution jsonb not null,   -- { playerId: amountReceived, ... }
  created_at   timestamptz not null default now()
);

create table ledger_balances (
  player_id  uuid primary key references players(id),
  balance    integer not null default 0,
  updated_at timestamptz not null default now()
);

create table session_results (
  id         uuid primary key default gen_random_uuid(),
  session_id uuid not null references sessions(id),
  player_id  uuid not null references players(id),
  net        integer not null,
  created_at timestamptz not null default now()
);

-- ── Row Level Security ─────────────────────────────────────────────────────────

alter table players         enable row level security;
alter table sessions        enable row level security;
alter table session_events  enable row level security;
alter table settlements     enable row level security;
alter table ledger_balances enable row level security;
alter table session_results enable row level security;

-- Everyone (anon + authenticated) can read all tables
create policy "public read" on players         for select using (true);
create policy "public read" on sessions        for select using (true);
create policy "public read" on session_events  for select using (true);
create policy "public read" on settlements     for select using (true);
create policy "public read" on ledger_balances for select using (true);
create policy "public read" on session_results for select using (true);

-- Only authenticated (admin) can write
create policy "admin insert" on players         for insert to authenticated with check (true);
create policy "admin update" on players         for update to authenticated using (true);
create policy "admin delete" on players         for delete to authenticated using (true);

create policy "admin insert" on sessions        for insert to authenticated with check (true);
create policy "admin update" on sessions        for update to authenticated using (true);
create policy "admin delete" on sessions        for delete to authenticated using (true);

create policy "admin insert" on session_events  for insert to authenticated with check (true);
create policy "admin update" on session_events  for update to authenticated using (true);
create policy "admin delete" on session_events  for delete to authenticated using (true);

create policy "admin insert" on settlements     for insert to authenticated with check (true);
create policy "admin update" on settlements     for update to authenticated using (true);
create policy "admin delete" on settlements     for delete to authenticated using (true);

create policy "admin insert" on ledger_balances for insert to authenticated with check (true);
create policy "admin update" on ledger_balances for update to authenticated using (true);
create policy "admin delete" on ledger_balances for delete to authenticated using (true);

create policy "admin insert" on session_results for insert to authenticated with check (true);
create policy "admin update" on session_results for update to authenticated using (true);
create policy "admin delete" on session_results for delete to authenticated using (true);

-- ── After running this SQL ─────────────────────────────────────────────────────
-- Go to Authentication > Users > Add user (email + password).
-- That single account is the admin login used in the app.
-- No other users need to be created — viewers access anonymously (anon key).
