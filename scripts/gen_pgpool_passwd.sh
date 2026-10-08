#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════════
#  gen_pgpool_passwd.sh — write conf/pgpool2/pool_passwd from bz/.env
# ══════════════════════════════════════════════════════════════════════════════
#
#  The Pgpool-II counterpart of gen_pgbouncer_userlist.sh. Same job, DIFFERENT
#  FILE FORMAT — and this is not a cosmetic difference:
#
#    PgBouncer userlist.txt :  "user" "password"      (space separated, quoted)
#    Pgpool-II pool_passwd  :  user:password         (colon separated, unquoted)
#
#  Writing PgBouncer's format here does not fail loudly. Pgpool-II parses the
#  whole first field as the user name, so it looks for a user literally called
#  `"pgbouncer"` (quotes included) and every login fails with:
#    FATAL:  pool_passwd file does not contain an entry for "pgbouncer"
#  while the proxy is otherwise healthy and listening. Verified on this stack.
#
#  pool_passwd IS A SECRET. With plain-text passwords it holds every database
#  credential the write endpoint will accept, and Pgpool-II uses it to
#  authenticate to the backends as well as to authenticate clients. It is
#  generated from .env and must never be hand-edited — hand-edits are silently
#  overwritten and, worse, can drift from .env exactly the way the parent stack's
#  hand-maintained userlist did.
#
#  WHY THIS FILE IS SEPARATE FROM THE PGBOUNCER ONE
#  Pgpool-II and PgBouncer have different formats and different escape rules, and
#  one shared writer would have to branch on the target format for no benefit.
#  Two writers, two formats, one source of truth (.env).
#
#  Usage:  scripts/gen_pgpool_passwd.sh [--check] [--quiet]
#            --check   report drift and exit 1 if the file is stale
#            --quiet   suppress change/summary lines
#  Exit 0  present, matches .env, parses
#  Exit 1  a required .env field is missing, or --check found drift

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BZ="$(cd "$HERE/.." && pwd)"
ENV_FILE="$BZ/.env"
OUT="$BZ/conf/pgpool2/pool_passwd"

CHECK=0
QUIET=0
while (( $# )); do
  case "$1" in
    --check) CHECK=1; shift ;;
    --quiet) QUIET=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

say() { (( QUIET )) || printf '%s\n' "$*"; }
die() { printf 'gen_pgpool_passwd: %s\n' "$*" >&2; exit 1; }

[[ -f "$ENV_FILE" ]] || die "no .env at $ENV_FILE — cannot source credentials"

# Read .env WITHOUT executing it: parse KEY=VALUE only, which is the file's
# actual contract. `set -a; . ./.env` would run any line in it.
env_get() {
  local key="$1" val=""
  [[ -f "$ENV_FILE" ]] || return 1
  val="$(sed -n "s/^[[:space:]]*${key}=//p" "$ENV_FILE" | tail -1)"
  printf '%s' "$val"
}

require() {
  local key="$1" v
  v="$(env_get "$key")"
  [[ -n "$v" ]] || die "${key} is missing or empty in .env — refusing to write a partial credential file"
  printf '%s' "$v"
}

APP_U="$(require PG_APP_USER)";        APP_P="$(require PG_APP_PASSWORD)"
RO_U="$(require PG_RO_USER)";          RO_P="$(require PG_RO_PASSWORD)"
ADM_U="$(require PG_ADMIN_USER)";      ADM_P="$(require PG_ADMIN_PASSWORD)"
# PGPOOL_ADMIN_USER is deliberately NOT read here. `pgbouncer` is a
# PgBouncer-only identity with no PostgreSQL role; Pgpool-II's admin console
# authenticates as a real role (bz_admin), so a `pgbouncer` entry would be a
# credential for a user that can never connect to anything.

# Pgpool-II parses pool_passwd itself. A quote or backslash in a password breaks
# that parser exactly as it breaks PgBouncer's — refuse rather than emit a file
# that starts and rejects every connection.
for pair in "app=$APP_P" "ro=$RO_P" "admin=$ADM_P"; do
  name="${pair%%=*}"; pw="${pair#*=}"
  case "$pw" in
    *'"'*|*'\'*) die "password for ${name} contains a quote or backslash, which the pool_passwd format cannot represent" ;;
  esac
done

# ── Render. Three lines, colon separated, no quotes, no header. ─────────────
# bz_ro is included because the READ proxy (PgBouncer) authenticates bz_ro
# against its own userlist — but Pgpool-II may also be asked for it, and a role
# missing here fails with "pool_passwd file does not contain an entry for user" at
# connect time rather than at boot.
#
# A colon or newline in a password cannot be represented in this format. That is
# checked for below rather than discovered at connect time.
for pair in "app=$APP_P" "ro=$RO_P" "admin=$ADM_P"; do
  name="${pair%%=*}"; pw="${pair#*=}"
  case "$pw" in
    *:*) die "password for ${name} contains a colon, which the pool_passwd format cannot represent" ;;
  esac
done

RENDERED="$(printf '%s:%s\n%s:%s\n%s:%s\n' \
  "$APP_U" "$APP_P" "$RO_U" "$RO_P" "$ADM_U" "$ADM_P")"

current=""
[[ -f "$OUT" ]] && current="$(cat "$OUT")"

if [[ "$current" == "$RENDERED" ]]; then
  say "  · pool_passwd already matches .env — unchanged"
else
  if (( CHECK )); then
    die "pool_passwd does not match .env (run: ./scripts/gen_pgpool_passwd.sh)"
  fi
  printf '%s\n' "$RENDERED" > "$OUT"
  chmod 0600 "$OUT"   # it is every database password, in plain text
  say "  · pool_passwd written from .env (mode 0600)"
fi

# ── Verify by re-parsing, do not trust the write ────────────────────────────
# A file that exists and is non-empty is NOT the requirement — the requirement is
# that Pgpool-II can parse it. This is the check that would catch a comment line,
# a blank line, or a stray quote, all of which make Pgpool-II load zero users
# while the proxy still listens and answers every connection with
# "password authentication failed".
verify() {
  [[ -s "$OUT" ]] || die "pool_passwd is empty after writing"
  local n total
  n="$(grep -cE '^[^:]+:[^:]+$' "$OUT" || true)"
  total="$(wc -l < "$OUT" | tr -d ' ')"
  [[ "$n" == "3" ]] || die "pool_passwd has ${n} valid entries, expected 3 — refusing to report success"
  [[ "$n" == "$total" ]] || die "pool_passwd has ${total} lines but only ${n} are valid entries; a comment or blank line is what makes Pgpool-II load ZERO users"
  say "  · verified ${n} entries parse as user:password — no comments, no stray lines"
}
verify
