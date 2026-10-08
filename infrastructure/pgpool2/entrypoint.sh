#!/usr/bin/env bash
# bz/infrastructure/pgpool2/entrypoint.sh — start Pgpool-II in the foreground.
#
# Deliberately minimal. The stock pgpool2 images ship a large entrypoint that
# generates config from environment variables; here the configuration is a real,
# readable file (conf/pgpool2/pgpool.conf) that is bind-mounted, because the
# failover semantics in it are the whole point of this service and they must be
# reviewable rather than assembled from env vars at boot.
#
# The one job beyond exec: create the runtime directories and make sure the
# config the operator thinks is running is the config that parsed. A config
# syntax error in pgpool2 is silent in the worst way — the process starts, the
# port listens, and the backends are simply absent — so it is checked explicitly
# with `pgpool -n` (parse only, no listen) before starting for real.
set -euo pipefail

# Debian installs the binary under /usr/sbin, which is not on a non-root PATH.
export PATH="/usr/sbin:/usr/bin:/sbin:/bin:${PATH}"

CONF="${PGPOOL_CONF:-/etc/pgpool2/pgpool.conf}"

log() { echo "[entrypoint-pgpool2] $*"; }
die() { echo "[entrypoint-pgpool2] FATAL: $*" >&2; exit 1; }

[[ -r "$CONF" ]] || die "no pgpool config at ${CONF}"

# THE PID FILE MUST BE CLEARED FIRST — `pgpool -n` IS NOT SIDE-EFFECT-FREE.
#
# "parse only" still opens the compiled-in pid file
# (/var/run/postgresql/pgpool.pid — Pgpool-II 4.3.5 IGNORES the pid_file setting
# in pgpool.conf; verified by setting it to /tmp/probe.pid and watching the path
# in the error stay unchanged). On a FRESH container that file does not exist and
# the check works. On `docker restart` the filesystem is preserved, the dead pid
# file survives, and the parse check fails with:
#     ERROR: pid file found. is another pgpool(7) is running?
#     [entrypoint-pgpool2] FATAL: pgpool.conf failed to parse
# turning an ordinary restart into a crash loop whose only visible symptom is a
# message blaming a config file that is in fact perfectly valid.
#
# Removing it is safe here precisely BECAUSE this code only runs at container
# start: if a live pgpool held that pid, this container would not be starting.
rm -f /var/run/postgresql/pgpool.pid

# `pgpool -n -f <conf>` parses and exits. It must succeed BEFORE we bind the
# port, otherwise a typo surfaces as "the proxy is up but every query fails".
if ! pgpool -n -f "$CONF" >/tmp/pgpool-parse.log 2>&1; then
    cat /tmp/pgpool-parse.log >&2
    die "pgpool.conf failed to parse — refusing to start a listener that cannot serve"
fi
log "config parsed OK: ${CONF}"

mkdir -p /var/run/pgpool /var/log/pgpool

# `pgpool -f <conf>` without -n forks into the background; with -n it stays in the
# foreground, which is what a container entrypoint needs so Docker supervises the
# real process instead of a shell that exited.
#
# stdbuf -oL -eL IS LOAD-BEARING. pgpool2 buffers stdout when it is a pipe (which
# it is under Docker), so without this its log output sits in a 4KB block and
# `docker compose logs` shows NOTHING while the process runs — the only reason any
# output was ever visible here was that those runs crashed and flushed on exit.
# For a component whose job is to make a decision in a few seconds during a
# failover, a log you cannot read until after the fact is not a log.
log "starting pgpool-II (foreground, line-buffered)"
exec stdbuf -oL -eL pgpool -f "$CONF" -n
