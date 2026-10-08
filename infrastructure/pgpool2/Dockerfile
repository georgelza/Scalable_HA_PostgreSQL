# syntax=docker/dockerfile:1.5
# bz/infrastructure/pgpool2/Dockerfile — Pgpool-II, the failover-aware write proxy
# ─────────────────────────────────────────────────────────────────────────────
# WHY A LOCAL IMAGE AND NOT THE PUBLISHED ONE
#
# The obvious choice is `pgpool/pgpool2` on Docker Hub. It is amd64-only
# (single manifest; on Apple silicon `docker run` fails with
# "exec /bin/sh: exec format error"). The parent stack's ADR-26 is explicit that
# no component may depend on amd64 emulation / Rosetta, so that image cannot be
# used here at all.
#
# Debian bookworm ships pgpool2 4.3.5 for every architecture, including arm64, so
# this installs the distribution package instead. The result is a genuine
# multi-arch (linux/amd64 + linux/arm64) build with no emulation — the same
# approach as ../pg/Dockerfile.
#
# Version note: pinned to the Debian package, currently 4.3.5. pgpool2 4.3 is the
# first line with PostgreSQL 16 support, which is what these nodes run — the same
# version-coupling trap as Citus in ../pg/Dockerfile, so pgpool2 and PG move
# together.
#
# WHAT THIS IS FOR
#   It is the WRITE endpoint's failover brain. See ../../README.md §4.
#   PgBouncer is deliberately NOT used for writes: it cannot tell a primary from
#   a standby, so a host list over both nodes round-robins writes onto a
#   read-only node, and a single-host PgBouncer has no way to move when that host
#   dies. Neither satisfies "writes always reach the writer, and follow it".
# ─────────────────────────────────────────────────────────────────────────────
FROM debian:bookworm-slim

ARG PGPOOL2_PKG=pgpool2=4.3.5-1+deb12u1

# postgresql-client-15 gives psql/libpq — the failover_command shells out to
# psql to promote a node. procps for process management, gosu to drop privileges.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      "${PGPOOL2_PKG}" \
      postgresql-client-15 \
      procps \
      gosu \
      ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# Debian's pgpool2 package ships NO service account — it installs the binary as
# /usr/sbin/pgpool owned by root and expects the distro's own postgres user. In a
# container there is no such user, so one is created here. It exists so pgpool2
# does not run as root: the failover command this service exists to perform
# promotes a database, and that is not something to hand to a root process.
#
# /var/run/postgresql IS NOT OPTIONAL. pgpool2 4.3.5 IGNORES the `pid_file`
# setting in pgpool.conf — verified on this image by rewriting the line to
# /tmp/probe.pid and watching it still fail with:
#     FATAL: could not open pid file "/var/run/postgresql/pgpool.pid"
# It always uses that compiled-in path. The directory is created by the
# postgresql-client package and is owned by postgres, so the pgpool user cannot
# write there and pgpool2 exits 1 before it ever listens. Hand the directory to
# pgpool instead of chasing a config knob that does nothing.
RUN useradd --system --create-home --home-dir /var/lib/pgpool --shell /usr/sbin/nologin pgpool \
 && mkdir -p /var/run/pgpool /var/log/pgpool /etc/pgpool2 /var/lib/pgpool \
 && chown -R pgpool:pgpool /var/run/pgpool /var/log/pgpool /var/lib/pgpool /var/run/postgresql

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

USER pgpool
WORKDIR /etc/pgpool2

EXPOSE 6432
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
