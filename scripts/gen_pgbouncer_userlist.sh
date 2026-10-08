#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════════
#  gen_pgbouncer_userlist.sh — write conf/pgbouncer/ro/userlist.txt from .env
# ══════════════════════════════════════════════════════════════════════════════
#
#  Project : bz PostgreSQL stack
#  Purpose : Keep both PgBouncer auth files in step with bz/.env.
#
#  ─────────────────────────────────────────────────────────────────────────────
#  WHY THIS EXISTS
#
#  `pgbouncer.ini` sets `auth_type = plain` and `auth_file =
#  /etc/pgbouncer/userlist.txt`, and docker-compose.yml mounts each proxy's
#  directory read-only into its container. With `auth_type = plain` the password
#  column in that file IS the credential, so the file is not a convenience list —
#  it is a secret, and a SECOND place a database password lives.
#
#  One writer per credential, the same rule as the parent stack: `make secrets-pg`
#  owns that file there, this script owns it here.
#
#  ─────────────────────────────────────────────────────────────────────────────
#  THE APP ROLE IS IN THIS LIST, AND THAT IS THE POINT
#
#  The application uses ONE role and ONE password against BOTH endpoints; only the
#  port differs, and this read proxy authenticates that same role. An earlier
#  version withheld the app role from this file, on the theory that not handing out
#  a writable credential was the cleanest read-only guarantee. It is a bad trade: it
#  forces every caller to know it has a different identity per endpoint, and that is
#  exactly the sort of thing that breaks silently when someone copies a DSN.
#
#  The read-only guarantee is enforced in the DATABASE instead — PgBouncer's
#  `user = bz_ro` on the pool makes every server-side connection run as a role that
#  holds no write privilege. See conf/pgbouncer/ro/pgbouncer.ini.
#
#  The read-only guarantee lives where it belongs — in the DATABASE, not in an
#  auth file. PgBouncer's `force_user = bz_ro` on the read pool means every
#  server-side connection there runs as a role holding no write privilege, no
#  matter who authenticated. Same login, different port, writes impossible.
#
#  ─────────────────────────────────────────────────────────────────────────────
#  THE OUTPUT CONTAINS `"user" "password"` LINES AND NOTHING ELSE
#
#  No comments, no blank lines, no header. PgBouncer's auth_file parser does NOT
#  accept comments: it fails on the first non-entry line and loads ZERO users,
#  while the container still reports `Up` and `healthy`, and the only symptom is
#  `no such user` at connect time. Hence the explicit verification below.
#
#  Usage:  scripts/gen_pgbouncer_userlist.sh [--check] [--quiet]
#            --check   report drift and exit 1 if the file is stale (CI / testpack)
#            --quiet   suppress the change/summary lines
#  Exit 0  file is present and matches .env
#  Exit 1  a required .env field is missing, or --check found drift

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BZ="$(cd "$HERE/.." && pwd)"
ENV_FILE="$BZ/.env"
# ONE output file. PgBouncer no longer fronts the WRITE path — Pgpool-II does,
# and its credential file is conf/pgpool2/pool_passwd (different format, different
# generator: gen_pgpool_passwd.sh). The old conf/pgbouncer/rw/ directory was
# removed rather than left behind, because a credential file that nothing reads is
# a file that silently drifts and then gets "fixed" by hand.
OUT_RO="$BZ/conf/pgbouncer/ro/userlist.txt"

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
die() { printf 'gen_pgbouncer_userlist: %s\n' "$*" >&2; exit 1; }

[[ -f "$ENV_FILE" ]] || die "no .env at $ENV_FILE — cannot source credentials"

# Read .env WITHOUT executing it. `set -a; . ./.env` would run any line in it;
# this parses KEY=VALUE only, which is the actual contract of the file.
env_get() {
  local key="$1" val=""
  [[ -f "$ENV_FILE" ]] || return 1
  val="$(sed -n "s/^[[:space:]]*${key}=//p" "$ENV_FILE" | tail -1)"
  printf '%s' "$val"
}

require() {
  local key="$1" v
  v="$(env_get "$key")"
  [[ -n "$v" ]] || die "${key} is missing or empty in .env — refusing to write a partial auth file"
  printf '%s' "$v"
}

# ── Required fields, and the role each one becomes ───────────────────────────
APP_U="$(require PG_APP_USER)";        APP_P="$(require PG_APP_PASSWORD)"
RO_U="$(require PG_RO_USER)";          RO_P="$(require PG_RO_PASSWORD)"
ADM_U="$(require PG_ADMIN_USER)";      ADM_P="$(require PG_ADMIN_PASSWORD)"
PGB_U="$(require PGPOOL_ADMIN_USER)";  PGB_P="$(require PGPOOL_ADMIN_PASSWORD)"

# PgBouncer must be able to reach each user. A password containing a `"` or a
# backslash would break the quoting of the auth file, so refuse rather than emit
# a file that silently fails to parse.
for pair in "app=$APP_P" "ro=$RO_P" "admin=$ADM_P" "pgbouncer=$PGB_P"; do
  name="${pair%%=*}"; pw="${pair#*=}"
  case "$pw" in
    *'"'*|*'\'*) die "password for ${name} contains a quote or backslash, which the auth_file format cannot represent" ;;
  esac
done

# ── Render. FOUR LINES. NO COMMENTS. See the warning at the top of the file. ──
RENDERED="$(printf '"%s" "%s"\n"%s" "%s"\n"%s" "%s"\n"%s" "%s"\n' \
  "$APP_U" "$APP_P" "$RO_U" "$RO_P" "$ADM_U" "$ADM_P" "$PGB_U" "$PGB_P")"

# A proxy whose userlist silently drifts from .env is a proxy that rejects every
# connection with "no such user" while still reporting healthy.
sync_one() {
  local out="$1" label="$2" current=""
  [[ -f "$out" ]] && current="$(cat "$out")"

  if [[ "$current" == "$RENDERED" ]]; then
    say "  · ${label}/userlist.txt already matches .env — unchanged"
    return 0
  fi
  if (( CHECK )); then
    die "${label}/userlist.txt does not match .env (run: ./scripts/gen_pgbouncer_userlist.sh)"
  fi
  printf '%s\n' "$RENDERED" > "$out"
  # Mounted read-only as root; keep it world-readable so the PgBouncer user can
  # read it, and note the exposure rather than pretend a tighter mode exists.
  chmod 0644 "$out"
  say "  · ${label}/userlist.txt written from .env"
}

sync_one "$OUT_RO" ro

# ── Verify by round-trip, do not trust the write ─────────────────────────────
# A file that is present, non-empty, and parseable is the actual requirement.
# Anything less and we are back to "the generator reports success and wrote
# something PgBouncer cannot read".
#
# $3 = expected entry count. There is deliberately no "forbidden role" check any
# more: both proxies must know the app role, so there is no role left to forbid.
# The read-only guarantee is enforced in the database via force_user (see
# conf/pgbouncer/ro/pgbouncer.ini), which is a stronger place to enforce it than a
# credential list.
verify() {
  local out="$1" label="$2" expect="$3" n total
  [[ -s "$out" ]] || die "${label}/userlist.txt is empty after writing"
  n="$(grep -cE '^"[^"]+" "[^"]+"$' "$out" || true)"
  total="$(wc -l < "$out" | tr -d ' ')"
  [[ "$n" == "$expect" ]] || die "${label}/userlist.txt has ${n} valid entries, expected ${expect} — refusing to report success"
  [[ "$n" == "$total" ]] || die "${label}/userlist.txt has ${total} lines but only ${n} are valid entries; a comment or blank line is what makes PgBouncer load ZERO users"
  say "  · verified ${n} entries parse as \"user\" \"password\" in ${label}/userlist.txt — no comments, no stray lines"
}
verify "$OUT_RO" ro 4
