-- templates/schema.sql
--
-- bz PostgreSQL stack — application schema (4 tables, 1 schema).
--
-- IMPORTANT: This file is NOT auto-run by docker-entrypoint-initdb.d — it lives
-- in a subdirectory (templates/), which Postgres's init-script runner ignores.
-- It is only ever invoked explicitly, once per database, by ../01_bootstrap.sh
-- (`psql --dbname "$db" -f templates/schema.sql`), so it is intentionally
-- database-name-agnostic: never hardcode a database name here — use
-- current_database() where one is needed. It is also role-name-agnostic: the
-- role names arrive as psql variables (app_user / admin_user) set by
-- 01_bootstrap.sh from the container environment.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- WHAT THIS SCHEMA DEMONSTRATES
--
--   4 tables, all in ONE schema (biz), each standing in for a different
--   Postgres distribution/placement strategy:
--
--   | Table          | Strategy                          | Why it is that way      |
--   |----------------|-----------------------------------|-------------------------|
--   | biz.customer   | LOCAL (not shared)                | local↔local FKs        |
--   | biz.address    | SHARED (Citus distributed table)  | sharded by customer_id   |
--   | biz.stock      | plain reference table             | small, stable, hot      |
--   | biz.sales      | PARTITIONED (RANGE on sold_at)    | monthly partitions      |
--
--   The section order below is DDL order, and it is dictated by the foreign key
--   from sales to stock — a table cannot be referenced before it exists. The
--   business order (customer, address, sales, stock) differs only in that one
--   swap.
--
--   THE PLACEMENT SPLIT IS NOT ARBITRARY — it is forced by Citus's foreign-key
--   rules, which is worth stating because it is invisible until it bites:
--
--     Citus supports a foreign key only when BOTH ends are distributed, or when
--     BOTH ends are local. A distributed table referencing a local table is
--     rejected outright (ERROR: cannot use a local reference table in a foreign
--     key constraint).
--
--     So biz.address — the table that wants to be sharded, because addresses are
--     numerous and grow forever — cannot declare `REFERENCES biz.customer`.
--     customer_id on address is therefore a PLAIN COLUMN with no constraint, and
--     integrity for that one edge is the application's job. Everything else in
--     this schema keeps real constraints, because both of its ends are local.
--
--   The same rule is why biz.sales is partitioned rather than distributed: it
--   has real foreign keys to biz.customer and biz.stock (both local), and loses
--   nothing by not being sharded. Partitioning by time is what sales actually
--   needs anyway — old months get detached, not scanned.
--
--   No BEGIN/COMMIT anywhere in this file: create_distributed_table() cannot run
--   inside a transaction block, so 01_bootstrap.sh applies it with psql in
--   autocommit mode (no -1 / --single-transaction).
-- ─────────────────────────────────────────────────────────────────────────────

-- ── Grants (dynamic) ────────────────────────────────────────────────────────
-- current_database() so this template works against any database name without
-- modification; app_user/admin_user are passed in by 01_bootstrap.sh.
SELECT format('GRANT ALL PRIVILEGES ON DATABASE %I TO %I', current_database(), :'admin_user') \gexec
SELECT format('GRANT CONNECT ON DATABASE %I TO %I', current_database(), :'app_user') \gexec

CREATE EXTENSION IF NOT EXISTS pgcrypto;
-- Citus: what makes biz.address a SHARED table. Must exist before the
-- create_distributed_table() call at the bottom.
CREATE EXTENSION IF NOT EXISTS citus;
-- pg_trgm: backs the fuzzy customer-name index below, so "acct" finds
-- "Accountability Holdings" instead of nothing.
CREATE EXTENSION IF NOT EXISTS pg_trgm;

CREATE SCHEMA IF NOT EXISTS biz;

COMMENT ON SCHEMA biz IS
  'bz demo domain: customer, address, sales, stock. Placement strategy differs '
  'per table on purpose — see the header of this file.';


-- ══════════════════════════════════════════════════════════════════════════════
-- 1. biz.customer — LOCAL (not shared, not partitioned)
-- ══════════════════════════════════════════════════════════════════════════════
-- Local on purpose: biz.sales holds real foreign keys to it, and Citus only
-- permits a local↔local FK. Making this table distributed would force every FK
-- pointing at it to be dropped.
CREATE TABLE IF NOT EXISTS biz.customer (
    customer_id    bigint       GENERATED ALWAYS AS IDENTITY,
    customer_ref   text         NOT NULL,
    full_name      text         NOT NULL,
    email          text,
    phone          text,
    country_code   char(2)      NOT NULL DEFAULT 'ZA',
    -- A CHECK rather than a native enum: adding a value is then an ALTER that
    -- needs no lock-ordering dance, and an invalid value can never reach
    -- storage.
    status         text         NOT NULL DEFAULT 'ACTIVE',
    created_at     timestamptz  NOT NULL DEFAULT now(),
    updated_at     timestamptz  NOT NULL DEFAULT now(),
    CONSTRAINT customer_pkey      PRIMARY KEY (customer_id),
    CONSTRAINT customer_ref_key   UNIQUE (customer_ref),
    CONSTRAINT customer_status_ck CHECK (status IN ('ACTIVE', 'SUSPENDED', 'CLOSED')),
    CONSTRAINT customer_email_ck  CHECK (email IS NULL OR email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$')
);

-- Business identifier lookups (customer_ref) are already served by the UNIQUE
-- constraint's own index — not duplicated here.

-- Case-insensitive email, which a plain UNIQUE(email) cannot express: two
-- addresses differing only in case must collide, and NULLs must stay legal
-- (many customers have no email), which a plain UNIQUE treats as distinct.
CREATE UNIQUE INDEX IF NOT EXISTS customer_email_lower_uidx
    ON biz.customer (lower(email)) WHERE email IS NOT NULL;

-- The operational query: "active customers, newest first". One index serves the
-- filter and the sort, instead of the planner choosing between two indexes.
CREATE INDEX IF NOT EXISTS customer_status_created_idx
    ON biz.customer (status, created_at DESC);

-- Fuzzy name search for the console's customer picker. GIN + gin_trgm_ops turns
-- a LIKE '%...%' into an index scan.
CREATE INDEX IF NOT EXISTS customer_name_trgm_idx
    ON biz.customer USING gin (full_name gin_trgm_ops);

COMMENT ON TABLE  biz.customer IS 'Customer master. LOCAL table — real FKs point at it (see file header).';
COMMENT ON COLUMN biz.customer.customer_ref IS 'Human-facing business key; the only identifier exposed to operators.';


-- ══════════════════════════════════════════════════════════════════════════════
-- 2. biz.address — SHARED (Citus distributed table)
-- ══════════════════════════════════════════════════════════════════════════════
-- The one table that is shared across the cluster.
--
-- Sharded on customer_id, NOT on address_id. That is a forced choice, not a
-- preference, and the reason is Citus's rule that every UNIQUE constraint on a
-- distributed table must include the distribution column. The partial unique
-- index below ("one primary address per customer per type") is on
-- (customer_id, address_type) — with address_id as the distribution column,
-- create_distributed_table() rejects the table outright:
--     ERROR: Distributed relations cannot have UNIQUE, EXCLUDE, or PRIMARY KEY
--            constraints that do not include the partition column
-- So customer_id is the distribution column, which makes that index legal AND
-- co-locates every address of a customer on one node — "this customer's
-- addresses" then touches exactly one shard instead of fanning out.
--
-- Either way this table cannot carry a foreign key to customer: a distributed
-- table may not reference a local one (see file header).
CREATE TABLE IF NOT EXISTS biz.address (
    address_id     bigint       GENERATED ALWAYS AS IDENTITY,
    customer_id    bigint       NOT NULL,
    address_type   text         NOT NULL DEFAULT 'SHIPPING',
    line1          text         NOT NULL,
    line2          text,
    city           text         NOT NULL,
    postal_code    text,
    country_code   char(2)      NOT NULL DEFAULT 'ZA',
    is_primary     boolean      NOT NULL DEFAULT false,
    created_at     timestamptz  NOT NULL DEFAULT now(),
    updated_at     timestamptz  NOT NULL DEFAULT now(),
    -- The distribution column (customer_id) must lead the primary key on a
    -- distributed table. It also means address_id is only unique per customer,
    -- which is why the business identifier that leaves this table is never
    -- address_id alone.
    CONSTRAINT address_pkey      PRIMARY KEY (customer_id, address_id),
    CONSTRAINT address_type_ck   CHECK (address_type IN ('BILLING', 'SHIPPING', 'OTHER')),
    CONSTRAINT address_line1_ck  CHECK (btrim(line1) <> ''),
    CONSTRAINT address_city_ck   CHECK (btrim(city)  <> '')
);

-- The overwhelmingly common query: "this customer's addresses", newest first.
-- This is also the access path that crosses shards — each of these lands on
-- exactly one node.
CREATE INDEX IF NOT EXISTS address_customer_idx
    ON biz.address (customer_id, created_at DESC);

-- At most ONE primary address per customer per type. A partial UNIQUE index is
-- the only construct that expresses this: a plain UNIQUE(customer_id,
-- address_type) would also forbid the customer from ever having a second
-- SHIPPING address, which is the normal case.
CREATE UNIQUE INDEX IF NOT EXISTS address_one_primary_per_type_uidx
    ON biz.address (customer_id, address_type) WHERE is_primary;

-- Batch/geographic lookups. INCLUDE columns let a covering index scan satisfy
-- the typical "list addresses in this postal code" with no heap fetch per row.
CREATE INDEX IF NOT EXISTS address_postal_idx
    ON biz.address (postal_code) INCLUDE (city, country_code);

COMMENT ON TABLE  biz.address IS
  'Customer addresses. SHARED — Citus distributed on customer_id (4 shards), so '
  'one customer''s addresses are co-located. No FK to biz.customer: Citus '
  'forbids a distributed table referencing a local one.';
COMMENT ON COLUMN biz.address.customer_id IS
  'NO foreign key — see file header. Integrity of this edge is enforced by the '
  'application; Citus cannot enforce it across the local/distributed boundary.';


-- ══════════════════════════════════════════════════════════════════════════════
-- 3. biz.stock — plain local reference table
-- ══════════════════════════════════════════════════════════════════════════════
-- Small, stable, read on every sale line: a textbook reference table. Kept local
-- (not shared) because biz.sales carries a real foreign key to it, and this is
-- exactly the table where a CHECK-constraint text column beats a native enum.
CREATE TABLE IF NOT EXISTS biz.stock (
    sku            text         NOT NULL,
    description    text         NOT NULL,
    category       text         NOT NULL DEFAULT 'GENERAL',
    unit           text         NOT NULL DEFAULT 'EA',
    qty_on_hand    integer      NOT NULL DEFAULT 0,
    reorder_level  integer      NOT NULL DEFAULT 0,
    unit_cost      numeric(18,2) NOT NULL DEFAULT 0,
    is_active      boolean      NOT NULL DEFAULT true,
    updated_at     timestamptz  NOT NULL DEFAULT now(),
    CONSTRAINT stock_pkey       PRIMARY KEY (sku),
    CONSTRAINT stock_qty_ck      CHECK (qty_on_hand >= 0),
    CONSTRAINT stock_reorder_ck  CHECK (reorder_level >= 0),
    CONSTRAINT stock_cost_ck     CHECK (unit_cost >= 0),
    CONSTRAINT stock_sku_ck      CHECK (sku ~ '^[A-Z0-9][A-Z0-9-]{2,31}$')
);

-- Catalogue browsing / category drill-down.
CREATE INDEX IF NOT EXISTS stock_category_idx
    ON biz.stock (category, description);

-- Replenishment report: "at or below reorder level". A PARTIAL index holding
-- only the rows that qualify — on a healthy catalogue that is a small fraction
-- of the table, and the index stays that small however many SKUs are added. The
-- same query without the predicate scans the whole table forever.
CREATE INDEX IF NOT EXISTS stock_low_stock_idx
    ON biz.stock (sku) WHERE qty_on_hand <= reorder_level;

COMMENT ON TABLE biz.stock IS
  'Stock/SKU master. Plain local reference table; referenced by a real FK from biz.sales.';
COMMENT ON INDEX biz.stock_low_stock_idx IS
  'Partial index for the replenishment report. The predicate is not immutable, '
  'but it does not need to be: PostgreSQL maintains the index incrementally, so '
  'a row that stops qualifying is removed and a row that starts qualifying is '
  'inserted — no reindex required.';


-- ══════════════════════════════════════════════════════════════════════════════
-- 4. biz.sales — PARTITIONED (RANGE on sold_at)
-- ══════════════════════════════════════════════════════════════════════════════
-- Partitioned by month so a reporting query prunes to the partitions it needs,
-- and so closed months can be DETACHED and archived in one statement instead of
-- deleted row by row.
--
-- sold_at is deliberately the TIMESTAMP OF THE SALE as recorded by the till,
-- not an ingestion timestamp. Partition pruning follows whatever the query
-- filters on, and only one of those two columns is ever filtered by a business
-- question ("what did we sell in March").
CREATE TABLE IF NOT EXISTS biz.sales (
    -- The partition key must be part of every unique constraint on a partitioned
    -- table, hence PRIMARY KEY (sold_at, sale_id) and not (sale_id).
    sale_id        bigint       GENERATED ALWAYS AS IDENTITY,
    sold_at        timestamptz  NOT NULL,
    customer_id    bigint       NOT NULL,
    stock_sku      text         NOT NULL,
    quantity       integer      NOT NULL DEFAULT 1,
    unit_price     numeric(18,2) NOT NULL,
    currency       char(3)      NOT NULL DEFAULT 'ZAR',
    channel        text         NOT NULL DEFAULT 'POS',
    status         text         NOT NULL DEFAULT 'SETTLED',
    CONSTRAINT sales_pkey        PRIMARY KEY (sold_at, sale_id),
    -- Both FKs are legal precisely because both targets are LOCAL tables.
    CONSTRAINT sales_customer_fk FOREIGN KEY (customer_id)
        REFERENCES biz.customer (customer_id) ON DELETE RESTRICT,
    CONSTRAINT sales_stock_fk    FOREIGN KEY (stock_sku)
        REFERENCES biz.stock (sku) ON DELETE RESTRICT,
    CONSTRAINT sales_qty_ck      CHECK (quantity > 0),
    CONSTRAINT sales_price_ck    CHECK (unit_price >= 0),
    CONSTRAINT sales_channel_ck  CHECK (channel IN ('POS', 'ONLINE', 'BATCH', 'ADJUSTMENT')),
    CONSTRAINT sales_status_ck   CHECK (status IN ('PENDING', 'SETTLED', 'REVERSED'))
) PARTITION BY RANGE (sold_at);

-- Monthly partitions. Deliberately DATED, not "the current month": a partition
-- boundary that moves with the clock silently re-parents history, which is the
-- one thing a partitioned table must never do. A month that arrives with no
-- partition falls into biz_sales_default rather than failing the insert — losing
-- a sale to a missing DDL script is not an acceptable failure mode.
CREATE TABLE IF NOT EXISTS biz.sales_2026_01 PARTITION OF biz.sales
    FOR VALUES FROM ('2026-01-01') TO ('2026-02-01');
CREATE TABLE IF NOT EXISTS biz.sales_2026_02 PARTITION OF biz.sales
    FOR VALUES FROM ('2026-02-01') TO ('2026-03-01');
CREATE TABLE IF NOT EXISTS biz.sales_2026_03 PARTITION OF biz.sales
    FOR VALUES FROM ('2026-03-01') TO ('2026-04-01');
CREATE TABLE IF NOT EXISTS biz.sales_default PARTITION OF biz.sales DEFAULT;

-- Partition-level indexes. Declared on the PARENT, so PostgreSQL creates the
-- matching index on every existing partition and — critically — on every
-- partition added later. An index created on a partition directly would silently
-- miss future partitions: the classic partitioned-table bug.
--
-- Reporting: revenue for one customer over a date range, newest first.
CREATE INDEX IF NOT EXISTS sales_customer_sold_idx
    ON biz.sales (customer_id, sold_at DESC);
-- Reconciliation: everything in a period that is not settled. currency and
-- unit_price are INCLUDEd so the ledger groups line up without a heap fetch.
CREATE INDEX IF NOT EXISTS sales_settled_idx
    ON biz.sales (sold_at DESC, status) INCLUDE (currency, unit_price);
-- Reverse lookup from an inventory movement back to the sale that caused it.
CREATE INDEX IF NOT EXISTS sales_stock_idx
    ON biz.sales (stock_sku, sold_at DESC);

COMMENT ON TABLE  biz.sales IS
  'Sales lines, PARTITIONED BY RANGE (sold_at). The partition key is part of the '
  'PK, so a unique constraint cannot span partitions.';
COMMENT ON TABLE  biz.sales_default IS
  'Catch-all partition. Rows landing here mean no monthly partition exists for '
  'the period — alert on it; it is a missing-DDL symptom, not a design.';


-- ══════════════════════════════════════════════════════════════════════════════
-- SHARED TABLE REGISTRATION — last, on purpose
-- ══════════════════════════════════════════════════════════════════════════════
-- create_distributed_table() cannot run inside a transaction block, which is
-- why this file is applied by psql WITHOUT -1/--single-transaction. It is
-- idempotent (OR REPLACE), so re-running the template against an existing
-- database leaves the placement alone instead of failing or silently resharding.
--
-- It also VALIDATES the placement: Citus checks the table's unique constraints
-- against the distribution column at this moment, and refuses a distribution
-- that would break one. A create_distributed_table() that fails here has caught
-- a real modelling error, and the schema must not be treated as built.
-- Distributed on customer_id — see the note on the table. shard_count is passed
-- explicitly rather than inherited from citus.shard_count so the shape of this
-- demo table is visible at the call site.
SELECT create_distributed_table('biz.address', 'customer_id',
                               colocate_with => 'none',
                               shard_count => 4);


-- ── Ownership / access ──────────────────────────────────────────────────────
-- Table-level GRANTs rather than a blanket database grant: the app role gets DML
-- on the four tables and USAGE on the schema, and nothing else. Sequences are
-- granted explicitly because an INSERT into an identity column needs them, and
-- USAGE on the schema alone does not confer that.
GRANT USAGE ON SCHEMA biz TO :app_user;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES    IN SCHEMA biz TO :app_user;
GRANT USAGE, SELECT      ON ALL SEQUENCES IN SCHEMA biz TO :app_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA biz
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO :app_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA biz
    GRANT USAGE, SELECT ON SEQUENCES TO :app_user;

-- The read-only role — the only role the read proxy accepts. SELECT on the
-- tables and USAGE on the schema; deliberately NO sequence privileges and
-- deliberately no DML. That is lock one of two: even a client that turns
-- default_transaction_read_only back off has nothing to write with.
-- (Lock two, the role's own default_transaction_read_only=on, is set in
-- 01_bootstrap.sh — it cannot be granted from here, because it is a role
-- attribute rather than a per-object privilege.)
GRANT USAGE  ON SCHEMA biz TO :ro_user;
GRANT SELECT ON ALL TABLES IN SCHEMA biz TO :ro_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA biz
    GRANT SELECT ON TABLES TO :ro_user;

-- The read-only guarantee is checked in ../01_bootstrap.sh, not here, and the
-- reason is mechanical rather than stylistic: psql does NOT substitute :'var'
-- inside a dollar-quoted body, so a PL/pgSQL guard cannot see the role name that
-- arrives as a psql variable. An earlier version of this block was written here
-- and failed at parse time with:
--     ERROR:  syntax error at or near ":"
--     LINE 8:      WHERE grantee = :'ro_user'
-- The check runs one step later, from the shell, where the role name is just a
-- variable. What it asserts: bz_ro holds no write privilege on any biz table,
-- because "SELECT-only" is a claim that a later grant can quietly invalidate.

-- Report what was actually built, so a schema failure surfaces here with the
-- shape of the result rather than 200 lines later in a bootstrap log.
\echo '── biz schema created ─────────────────────────────────────────────'
SELECT c.relname AS table_name,
       CASE c.relkind WHEN 'r' THEN 'table'
                      WHEN 'p' THEN 'partitioned' END           AS kind,
       (SELECT count(*) FROM pg_index x WHERE x.indrelid = c.oid) AS indexes,
       (SELECT count(*) FROM pg_inherits h WHERE h.inhparent = c.oid) AS partitions
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname = 'biz'
 WHERE c.relkind IN ('r', 'p')
 ORDER BY c.relkind DESC, c.relname;
