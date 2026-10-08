#!/usr/bin/env bash
# 01_bootstrap.sh — bz PostgreSQL bootstrap
#
# Runs ONCE, on first init of the PRIMARY's empty data directory, via
# docker-entrypoint-initdb.d/ (mounted as a DIRECTORY in bz/docker-compose.yml).
# The replica never runs this: it clones the primary's data directory, which
# already contains everything below.
#
# Why a shell script and not plain .sql: docker-entrypoint-initdb.d executes each
# file exactly once against $POSTGRES_DB, with no way to say "run this against
# N databases". This script owns the loop and hands each database to the
# database-agnostic template in templates/schema.sql.
#
# SCOPE
#   1. Roles       : app (DML), ro (read-only, the read proxy's only role),
#                    admin (owner/DDL), repl (streaming replication)
#   2. repmgr db   : cluster metadata, owned by the replication role
#   3. Database    : $BZ_DB_NAME, owner = admin
#   4. Schema      : templates/schema.sql applied once, to that database
#   5. Citus       : extension + single-node coordinator registration
#
# IDEMPOTENCE: every step checks before it acts. docker-entrypoint-initdb.d runs
# these only on an empty PGDATA, so idempotence is belt-and-braces — but it is
# also what makes the script safe to re-run by hand while diagnosing a stack.
#
# $POSTGRES_DB (compose: PG_DB_NAME, default "postgres") is the database the
# image auto-creates and the one this script connects to for admin work
# (CREATE ROLE / CREATE DATABASE). It is NOT the application database.
set -euo pipefail

BZ_DB="${BZ_DB_NAME:?BZ_DB_NAME must be set (docker-compose.yml passes it from .env)}"
SCHEMA_TEMPLATE="/docker-entrypoint-initdb.d/templates/schema.sql"
REPMGR_DB="${REPMGR_DB:-repmgr}"

APP_USER="${BZ_APP_USER:-bz_app}"
APP_PASSWORD="${BZ_APP_PASSWORD:?BZ_APP_PASSWORD must be set}"
RO_USER="${BZ_RO_USER:-bz_ro}"
RO_PASSWORD="${BZ_RO_PASSWORD:?BZ_RO_PASSWORD must be set}"
ADMIN_USER="${BZ_ADMIN_USER:-bz_admin}"
ADMIN_PASSWORD="${BZ_ADMIN_PASSWORD:?BZ_ADMIN_PASSWORD must be set}"
REPL_USER="${BZ_REPL_USER:-replicator}"
REPL_PASSWORD="${BZ_REPL_PASSWORD:?BZ_REPL_PASSWORD must be set}"

psql_admin() {
    # $POSTGRES_DB is auto-created by the image before any initdb.d script runs,
    # so it is always a safe, already-existing database to do admin work against.
    psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" "$@"
}

# ── 1. Roles ─────────────────────────────────────────────────────────────────
echo "[01_bootstrap] ── Roles ───────────────────────────────────────────"
# Credentials come from the container environment (compose interpolates bz/.env),
# NOT from literals — the same values scripts/gen_pgbouncer_userlist.sh writes to
# conf/pgbouncer/{rw,ro}/userlist.txt. \getenv keeps passwords out of argv/`ps`;
# format(%I/%L) quotes names and values safely.
psql_admin <<'EOSQL'
\getenv app_user  BZ_APP_USER
\getenv app_pw    BZ_APP_PASSWORD
\getenv ro_user   BZ_RO_USER
\getenv ro_pw     BZ_RO_PASSWORD
\getenv adm_user  BZ_ADMIN_USER
\getenv adm_pw    BZ_ADMIN_PASSWORD
\getenv rep_user  BZ_REPL_USER
\getenv rep_pw    BZ_REPL_PASSWORD

-- app: DML only. No CREATEDB, no SUPERUSER — it is the role every pooled
-- connection authenticates as, so a compromise here must not be able to drop
-- the schema or create a role.
SELECT format('CREATE ROLE %I WITH LOGIN PASSWORD %L', :'app_user', :'app_pw')
 WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'app_user') \gexec
-- ro: the read-only role, and the ONLY role the read proxy accepts. The role's
-- own default is what makes it read-only on EVERY node the proxy balances
-- across, not just on the standby — see templates/schema.sql for the grants
-- (SELECT only) and conf/pgbouncer/ro/pgbouncer.ini for why the proxy itself
-- cannot enforce this.
SELECT format('CREATE ROLE %I WITH LOGIN PASSWORD %L', :'ro_user', :'ro_pw')
 WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'ro_user') \gexec
-- ALTER ROLE ... SET is a separate \gexec because a \gexec carries exactly one
-- statement; the session default is the second of the two locks and is
-- asserted below rather than assumed.
SELECT format('ALTER ROLE %I SET default_transaction_read_only = on', :'ro_user') \gexec
-- admin: database owner + DDL. CREATEDB for the harness, not SUPERUSER.
SELECT format('CREATE ROLE %I WITH LOGIN PASSWORD %L CREATEDB', :'adm_user', :'adm_pw')
 WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'adm_user') \gexec
-- pg_monitor so the operator role can actually SEE the cluster's replication and
-- connection state.
--
-- Without this, `SELECT ... FROM pg_stat_replication` as bz_admin returns ZERO
-- ROWS rather than an error — pg_stat_* views are restricted to superusers and
-- pg_read_all_stats members. A monitoring check written against it therefore
-- reports "no replication configured" on a cluster that is replicating happily,
-- which is a check that fails for the wrong reason and gets ignored. Caught by
-- `make verify` printing an empty replication line on a working stack.
SELECT format('GRANT pg_monitor TO %I', :'adm_user') \gexec
-- repl: streaming replication. This is the role the replica's walsender
-- authenticates as; it is NOT an application role and is deliberately absent
-- from PgBouncer's userlist.txt — replication never traverses the proxy.
SELECT format('CREATE ROLE %I WITH LOGIN REPLICATION PASSWORD %L', :'rep_user', :'rep_pw')
 WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'rep_user') \gexec

-- repmgr database (owned by the replication role)
SELECT format('CREATE DATABASE %I OWNER %I', 'repmgr', :'rep_user')
 WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'repmgr') \gexec
EOSQL

# The repmgr EXTENSION has to exist inside that database before anything can
# read or write repmgr.nodes — and nothing creates it for you. A `CREATE
# DATABASE repmgr` on its own gives you an empty database, so the first query
# against repmgr.nodes fails with "relation repmgr.nodes does not exist" and
# `repmgr primary register` cannot record the node. This step cannot live in the
# heredoc above: CREATE DATABASE cannot run inside the same transaction as the
# \gexec that issued it, so it is a separate psql invocation against the
# freshly-created database.
echo "[01_bootstrap] ── repmgr extension in '${REPMGR_DB}' ───────────────"
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$REPMGR_DB" \
     -v repl_user="${REPL_USER}" <<'EOSQL'
CREATE EXTENSION IF NOT EXISTS repmgr;

-- OWNERSHIP AND GRANTS — this is the part that is easy to miss.
--
-- The extension is created by the superuser (that is the only role that can
-- create it here), so every object in it — the repmgr schema, the tables, the
-- functions — is owned by postgres. The replication role owns the DATABASE but
-- owns nothing INSIDE it, and repmgr.nodes is not readable by it:
--     ERROR: permission denied for schema repmgr
-- That breaks the replica's own `repmgr standby clone`, which has to INSERT its
-- node row, and it breaks every metadata read afterwards.
--
-- So ownership of the schema is handed to the replication role and it is granted
-- DML on the metadata tables. SELECT alone is NOT enough: the standby inserts
-- its own node row on first clone, and repmgrd updates node liveness.
--
-- GRANT USAGE on a TABLE is invalid ("invalid privilege type USAGE for table") —
-- the table privileges are the DML set, and USAGE belongs on the schema.
SELECT format('ALTER SCHEMA repmgr OWNER TO %I', :'repl_user') \gexec
GRANT USAGE ON SCHEMA repmgr TO :"repl_user";
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES    IN SCHEMA repmgr TO :"repl_user";
GRANT EXECUTE                  ON ALL FUNCTIONS IN SCHEMA repmgr TO :"repl_user";
EOSQL

# Observed, not assumed: the replication role can actually reach the table this
# script's caller is about to query. If the grants above ever regress, this
# fails here — during first init, where the log is still being read — rather than
# later in a one-shot container whose output nobody scrolls back to.
PGPASSWORD="${REPL_PASSWORD}" psql -v ON_ERROR_STOP=1 \
    --username "$REPL_USER" --dbname "$REPMGR_DB" -tAc \
    "SELECT count(*) FROM repmgr.nodes" >/dev/null \
  || { echo "[01_bootstrap] FATAL: ${REPL_USER} cannot read repmgr.nodes" >&2; exit 1; }
echo "[01_bootstrap]   repmgr.nodes readable by ${REPL_USER} — verified."

# ── 2. Application database ─────────────────────────────────────────────────
echo "[01_bootstrap] ── Database ${BZ_DB} ────────────────────────────────"
psql_admin -v db="${BZ_DB}" -v adm="${ADMIN_USER}" <<'EOSQL'
SELECT format('CREATE DATABASE %I OWNER %I', :'db', :'adm')
 WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = :'db') \gexec
EOSQL

# Assert the read-only role's session default actually took. Deliberately HERE,
# immediately after the database it needs to connect to exists — an earlier
# version of this script ran the probe before CREATE DATABASE and died with
# 'database "bzdb" does not exist', which is a confusing way to learn that
# psql needs a database to connect to.
#
# This is the property the read proxy's whole safety argument rests on: a role
# attribute that silently failed to apply would leave every read session able to
# write on the primary. The SELECT/GRANT half of the lock is asserted in
# templates/schema.sql, where the tables are.
RO_PROBE="$(psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "${BZ_DB}" \
              -tAc "SELECT rolconfig FROM pg_roles WHERE rolname = '${RO_USER}'")"
case "${RO_PROBE}" in
    *default_transaction_read_only=on*)
        echo "[01_bootstrap]   ${RO_USER}: default_transaction_read_only=on — verified." ;;
    *)
        echo "[01_bootstrap] FATAL: ${RO_USER} is not default_transaction_read_only (rolconfig=${RO_PROBE})" >&2
        exit 1 ;;
esac

# ── 3. Schema ───────────────────────────────────────────────────────────────
# NOTE: no --single-transaction (-1). templates/schema.sql calls
# create_distributed_table(), which cannot run inside a transaction block. If this
# ever needs to become atomic, the fix is to move the Citus call into its own
# step below — NOT to wrap this call in a transaction and let it fail.
echo "[01_bootstrap] ── Schema (templates/schema.sql) ───────────────────"
psql -v ON_ERROR_STOP=1 \
     --username "$POSTGRES_USER" \
     --dbname "$BZ_DB" \
     -v app_user="${APP_USER}" \
     -v ro_user="${RO_USER}" \
     -v admin_user="${ADMIN_USER}" \
     -f "$SCHEMA_TEMPLATE"

# ── 4. Citus ────────────────────────────────────────────────────────────────
# Single-node mode: this node is both coordinator and worker, so the SHARED table
# (biz.address) is distributed across local shards and no worker node has to be
# added. The multi-host `host=` list in conf/pgbouncer/ro/pgbouncer.ini is
# UNAFFECTED by Citus — that is PgBouncer balancing across PostgreSQL servers,
# which is a different mechanism from Citus's placement.
echo "[01_bootstrap] ── Citus coordinator registration ───────────────────"
PRIMARY_HOST="localhost"
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$BZ_DB" <<-EOSQL
    CREATE EXTENSION IF NOT EXISTS citus;
    DO \$do_block\$
    BEGIN
        -- citus_set_coordinator_host() fails if called twice, so guard on the
        -- node table rather than catching an exception.
        IF NOT EXISTS (SELECT 1 FROM pg_dist_node
                       WHERE nodename = '${PRIMARY_HOST}' AND nodeport = 5432) THEN
            PERFORM citus_set_coordinator_host('${PRIMARY_HOST}', 5432);
        END IF;
    END
    \$do_block\$;
EOSQL

# ── 4. Replication slot (the primary's half of the slot contract) ───────────
# The replica asks for this slot by name via `primary_slot_name` on its own
# command line (see bz/docker-compose.yml) — the setting cannot live in
# postgresql.conf because one conf file is mounted into both nodes. Creating it
# here, on the primary, means a replica that starts later finds it already there.
# A replication slot is CLUSTER-wide, so the database this runs against is
# irrelevant.
#
# Idempotent: a physical slot is a named object, so CREATE OR REPLACE is not a
# thing — check first, create only when absent.
echo "[01_bootstrap] ── Replication slot 'bz_replica_slot' ───────────────"
psql_admin <<'EOSQL'
-- A DO block rather than `SELECT pg_create_...() WHERE NOT EXISTS(...)`: a
-- function with side effects in a target list is exactly the kind of thing whose
-- evaluation order you do not want to be relying on for idempotence.
DO $do_block$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_replication_slots
                   WHERE slot_name = 'bz_replica_slot'
                     AND slot_type = 'physical') THEN
        PERFORM pg_create_physical_replication_slot('bz_replica_slot');
    END IF;
END
$do_block$;
EOSQL

# ── 5. Report what was actually built ───────────────────────────────────────
# The read-only guarantee is ASSERTED here rather than trusted. "bz_ro is
# SELECT-only" is a claim that any later GRANT can quietly invalidate, and the
# consequence of it being wrong is a read proxy that writes — half of those
# writes landing on a standby. So: query the actual grants and fail the bootstrap
# if a single write privilege exists.
#
# Done from the shell, not in PL/pgSQL, because psql does not substitute :'var'
# inside a dollar-quoted body — which is why the guard is not in schema.sql next
# to the GRANTs it is checking.
RO_WRITABLE="$(psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "${BZ_DB}" -tAc \
  "SELECT COALESCE(string_agg(DISTINCT privilege_type, ','), '')
     FROM information_schema.role_table_grants
    WHERE grantee = '${RO_USER}'
      AND table_schema = 'biz'
      AND privilege_type IN ('INSERT','UPDATE','DELETE','TRUNCATE','REFERENCES','TRIGGER')")"

if [[ -n "${RO_WRITABLE}" ]]; then
    echo "[01_bootstrap] FATAL: ${RO_USER} holds write privilege(s) [${RO_WRITABLE}] on schema biz" >&2
    echo "[01_bootstrap]        — the read proxy would not be read-only. Fix the GRANTs, then re-run." >&2
    exit 1
fi
echo "[01_bootstrap]   ${RO_USER}: no write privileges on biz — read-only verified."

# Observed, not assumed: the four tables, their placement, and the shard count.
# A bootstrap that prints success but produced a differently-shaped schema is
# the failure mode worth pre-empting.
echo "[01_bootstrap] ── Verified result ───────────────────────────────────"
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$BZ_DB" <<'EOSQL'
\pset footer off
SELECT c.relname                                   AS table_name,
       CASE c.relkind WHEN 'r' THEN 'local'
                      WHEN 'p' THEN 'partitioned' END AS placement,
       COALESCE((SELECT count(*) FROM pg_index i WHERE i.indrelid = c.oid), 0) AS indexes,
       COALESCE((SELECT count(*) FROM pg_inherits h WHERE h.inhparent = c.oid), 0) AS partitions
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname = 'biz'
 WHERE c.relkind IN ('r', 'p')
 ORDER BY c.relname;

SELECT 'biz.address' AS shared_table,
       count(*)      AS shards,
       count(DISTINCT nodename) AS distinct_nodes,
       min(colocation_id) AS colocation_group
  FROM citus_shards WHERE table_name = 'biz.address'::regclass;

-- The SHARED table must actually be shared, and colocated. Asserted rather than
-- printed: a create_distributed_table() that silently left the table local would
-- still make this output look plausible, and "4 shards / 1 colocation group" is
-- the evidence that the placement took effect.
DO $do_block$
DECLARE
    v_shards int;
    v_coloc  int;
BEGIN
    SELECT count(*), min(colocation_id) INTO v_shards, v_coloc
      FROM citus_shards WHERE table_name = 'biz.address'::regclass;

    IF v_shards < 2 THEN
        RAISE EXCEPTION 'biz.address has % shard(s) — it is NOT distributed. '
                        'The SHARED-table half of this schema did not take effect.', v_shards;
    END IF;
    IF v_coloc IS DISTINCT FROM 1 THEN
        RAISE EXCEPTION 'biz.address has colocation_id %, expected 1 — shards of a '
                        'single table must share one colocation group.', v_coloc;
    END IF;
    RAISE NOTICE 'biz.address: % shards, colocation group % — SHARED placement verified.', v_shards, v_coloc;
END
$do_block$;
EOSQL

echo "[01_bootstrap] Done — ${BZ_DB} created with the 4-table biz schema."
