#!/usr/bin/env bash
# 02_register_primary.sh — register the primary node with repmgr (ONE-SHOT)
#
# Runs as its own Compose service (`repmgr_register`) against a live,
# TCP-reachable primary, with the primary's data directory mounted read-only.
#
# WHY THIS IS NOT PART OF docker-entrypoint-initdb.d
#   Two reasons, both load-bearing:
#
#   1. TIMING. During first init, docker-entrypoint.sh starts PostgreSQL on a
#      unix socket only (listen_addresses=''), so anything that connects over TCP
#      to the node's own hostname fails there and works everywhere else.
#   2. repmgr primary register() reads the cluster's system identifier out of the
#      DATA DIRECTORY (pg_control), so the process doing the registration must see
#      the real PGDATA, not an empty one.
#
# It is the equivalent of the parent stack's `make pg-bootstrap`.
#
# WHAT IT IS AND IS NOT FOR
#   It is NOT required for replication to work. Streaming replication is driven by
#   standby.signal + primary_conninfo, both established by the image entrypoint on
#   the standby. Registration is what lets repmgrd start, and what repmgr's own
#   tools use to reason about the topology.
#
#   THE STANDBY IS DELIBERATELY NOT REGISTERED HERE, and this is the single most
#   consequential decision in this stack's HA story:
#
#     * `repmgr standby clone` does not register the node. repmgr 5.5 says so in
#       its own HINT after cloning.
#     * `repmgr standby register` would fix that, but it writes primary_conninfo
#       into the standby's postgresql.auto.conf from the upstream node's conninfo
#       in repmgr.nodes — which carries NO PASSWORD, because passwords are
#       deliberately not stored there. pg_hba.conf is scram-sha-256 with no trust
#       lines, so a password-less primary_conninfo cannot authenticate and the
#       standby waits for WAL forever. The image entrypoint goes to some length to
#       inject exactly that password; the register step would undo it on restart.
#
#   So failover is owned by Pgpool-II (see conf/pgpool2/), which promotes the
#   standby with `SELECT pg_promote()` — a correct, supported promotion that never
#   touches primary_conninfo. repmgr's job here ends at the initial clone.
#
#   It also lives in bz/scripts/ rather than bz/sql/postgresdb/ because
#   sql/postgresdb IS the /docker-entrypoint-initdb.d mount, and that runner
#   executes every top-level .sh it finds — which would run this at exactly the
#   moment it cannot work. (Learned the hard way: the first attempt failed on
#   contact with "cannot reach the primary at bz-pg-primary:5432".)
set -euo pipefail

REPMGR_CONF="/tmp/bz-repmgr.conf"
REPMGR_DB="${REPMGR_DB:-repmgr}"
PGDATA="/var/lib/postgresql/data"   # read-only mount of the PRIMARY's data dir

NODE_ID="${REPMGR_NODE_ID:-1}"
NODE_NAME="${REPMGR_NODE_NAME:-bz-pg-primary}"
REPL_USER="${BZ_REPL_USER:-replicator}"
REPL_PASSWORD="${BZ_REPL_PASSWORD:?BZ_REPL_PASSWORD must be set}"
PRIMARY_HOST="${REPMGR_PRIMARY_HOST:-bz-pg-primary}"
PRIMARY_PORT="${REPMGR_PRIMARY_PORT:-5432}"

log() { echo "[02_register_primary] $*"; }
die() { echo "[02_register_primary] FATAL: $*" >&2; exit 1; }

# ── Render a minimal repmgr.conf ────────────────────────────────────────────
# The image entrypoint renders /etc/repmgr.conf, but this service overrides the
# entrypoint (see the header), so nothing has rendered it. Writing the few lines
# this command needs is deterministic; depending on a file nobody created would be
# the alternative.
cat > "${REPMGR_CONF}" <<EOF
node_id=${NODE_ID}
node_name=${NODE_NAME}
conninfo='host=${PRIMARY_HOST} port=${PRIMARY_PORT} user=${REPL_USER} dbname=${REPMGR_DB} connect_timeout=5'
data_directory='${PGDATA}'
failover=automatic
promote_command='repmgr standby promote -f ${REPMGR_CONF} --log-to-file'
follow_command='repmgr standby follow -f ${REPMGR_CONF} --log-to-file --upstream-node-id=%n'
log_level=INFO
EOF

# ── Preconditions, checked rather than assumed ──────────────────────────────
[[ -f "${PGDATA}/PG_VERSION" ]] \
  || die "no cluster at ${PGDATA} — is the primary's data directory mounted into this service?"

if ! PGPASSWORD="${REPL_PASSWORD}" psql -h "${PRIMARY_HOST}" -p "${PRIMARY_PORT}" \
       -U "${REPL_USER}" -d "${REPMGR_DB}" -tAc 'SELECT 1' >/dev/null 2>&1; then
  die "cannot reach the primary at ${PRIMARY_HOST}:${PRIMARY_PORT} as ${REPL_USER} (dbname=${REPMGR_DB})"
fi
log "primary reachable at ${PRIMARY_HOST}:${PRIMARY_PORT}; repmgr db '${REPMGR_DB}' present."

# ── Register, unless already registered ─────────────────────────────────────
ALREADY="$(PGPASSWORD="${REPL_PASSWORD}" psql -h "${PRIMARY_HOST}" -p "${PRIMARY_PORT}" \
             -U "${REPL_USER}" -d "${REPMGR_DB}" -tAc \
           "SELECT count(*) FROM repmgr.nodes WHERE node_id = ${NODE_ID}")"

if [[ "${ALREADY}" == "0" ]]; then
  log "registering node ${NODE_ID} (${NODE_NAME})…"
  PGPASSWORD="${REPL_PASSWORD}" repmgr -f "${REPMGR_CONF}" -d "${REPMGR_DB}" \
      primary register \
    || die "repmgr primary register FAILED — the node is unregistered and repmgrd will not start"
else
  log "node ${NODE_ID} already registered — nothing to do."
fi

# ── Verify by query, do not trust the exit code ─────────────────────────────
# "The command succeeded" is not the requirement; "the row is there and it names
# the node we think it does" is.
GOT="$(PGPASSWORD="${REPL_PASSWORD}" psql -h "${PRIMARY_HOST}" -p "${PRIMARY_PORT}" \
         -U "${REPL_USER}" -d "${REPMGR_DB}" -tAc \
       "SELECT node_id || '|' || node_name || '|' || type || '|' || active FROM repmgr.nodes WHERE node_id = ${NODE_ID}")"

[[ -n "${GOT}" ]] || die "node ${NODE_ID} is still absent from repmgr.nodes after registering"

IFS='|' read -r v_id v_name v_type v_active <<<"${GOT}"
log "registered: node_id=${v_id} node_name=${v_name} type=${v_type} active=${v_active}"
[[ "${v_name}"   == "${NODE_NAME}" ]] || die "node ${NODE_ID} is named '${v_name}', expected '${NODE_NAME}'"
[[ "${v_type}"   == "primary" ]]       || die "node ${NODE_ID} is type '${v_type}', expected 'primary'"

# `active` is boolean, and boolean::text is 'true'/'false' — NOT psql's display
# form 't'/'f'. The cast is what produces it: concatenating a boolean into a
# string (as the query above does) yields 'true'. Accept both spellings rather
# than assert one and break on a cosmetic change.
case "${v_active}" in
    t|true|TRUE) ;;
    *) die "node ${NODE_ID} is inactive (active=${v_active})" ;;
esac

log "OK — primary node registered. repmgrd can now start."
