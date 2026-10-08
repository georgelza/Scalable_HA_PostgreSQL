#!/usr/bin/env bash
# bz/conf/pgpool2/failover.sh — promote a standby. Called by pgpool2's
# failover_command as:  failover.sh <new-primary-host> <old-primary-host>
#
# THIS IS THE AUTOMATIC FAILOVER. When the write endpoint's primary stops
# answering health checks, Pgpool-II runs this, and the promoted node becomes the
# writer with no operator action.
#
# WHY A SQL CALL AND NOT `pg_ctl promote`
#   pg_ctl promote has to run ON the node being promoted, with that node's data
#   directory. This container has neither. `SELECT pg_promote()` is the supported
#   in-band equivalent: it is what pg_ctl promote issues internally, and it
#   returns true only if this node actually left recovery.
#
# IDEMPOTENT, DELIBERATELY. pg_promote() returns false when the node is already a
# primary. pgpool2 may invoke failover_command more than once (failover_retries),
# and a second promotion of an already-promoted node must be a no-op, not an
# error that leaves pgpool2 believing the failover failed.
set -uo pipefail

NEW_PRIMARY="${1:?new primary hostname required}"
OLD_PRIMARY="${2:-unknown}"

PGHOST="$NEW_PRIMARY" PGPORT=5432 PGUSER="${BZ_PROMOTE_USER:?}" PGPASSWORD="${BZ_PROMOTE_PASSWORD:?}" \
PGCONNECT_TIMEOUT=5 \
psql -d postgres -v ON_ERROR_STOP=1 -tAc \
  "SELECT CASE WHEN pg_is_in_recovery() THEN pg_promote() ELSE false END;" \
  >/tmp/promote.out 2>/tmp/promote.err
rc=$?

echo "[failover.sh] new_primary=${NEW_PRIMARY} old_primary=${OLD_PRIMARY} rc=${rc}"
echo "[failover.sh] pg_promote -> $(cat /tmp/promote.out 2>/dev/null)"
if [[ -s /tmp/promote.err ]]; then echo "[failover.sh] stderr: $(cat /tmp/promote.err)"; fi

# Exit 0 on success OR on "already a primary". Anything else is a real failure and
# must be reported as one, so pgpool2 retries and an operator eventually sees it.
if [[ $rc -ne 0 ]]; then
  echo "[failover.sh] FATAL: could not reach ${NEW_PRIMARY} to promote it"
  exit 1
fi
if grep -qi 'error' /tmp/promote.err 2>/dev/null; then
  echo "[failover.sh] FATAL: pg_promote() errored on ${NEW_PRIMARY}"
  exit 1
fi
exit 0
