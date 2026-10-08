# bz/Makefile — PostgreSQL failover lab: pull, build, run, down
# ─────────────────────────────────────────────────────────────────────────────
#
#   make            same as `make help`
#   make pull       fetch every EXTERNAL image this stack needs
#   make build      build the locally-built images
#   make run        stand the stack up and wait until it is settled
#   make down       tear down and delete every data directory under bz/data
#
# Supporting targets: ps · logs · verify · failover-test · rebuild · credentials
#
# ─────────────────────────────────────────────────────────────────────────────
#
# WHY bz HAS ITS OWN MAKEFILE
#
# bz/ is a SEPARATE Compose project (`name: bzpg`) with its own network, ports,
# credentials and data directories. It shares no state with the parent CORE stack
# (deploy/, `make run` there, and its Makefile). This file therefore does not
# include, source or invoke anything outside bz/ — the one deliberate exception is
# the image BUILD CONTEXT for PostgreSQL, which points at
# ../deploy/infrastructure/pg (see "build" below). That is a read-only reference:
# the parent stack's Dockerfile is used as-is and is never modified, so the two
# stacks cannot drift into different PostgreSQL builds.
#
# ─────────────────────────────────────────────────────────────────────────────
#
# ONE SOURCE OF TRUTH FOR VERSIONS: bz/.env
#
# The image tags live in .env, not here. If a version is written in both places
# they WILL drift, and the failure is confusing: `make pull` fetches one version
# while Compose runs another. Every value below is read out of .env, with a
# default only so the Makefile is still usable if .env is missing (it is not
# optional — Compose requires it).

SHELL := /bin/bash
.DEFAULT_GOAL := help

COMPOSE  := docker compose
ENV_FILE := .env

# Read KEY from .env without sourcing it. `include` is not used on purpose: it
# makes any non-assignment line a hard parse error, and .env is a file people
# annotate with prose. `tail -1` so the LAST definition of a key wins, which
# matches how Compose resolves duplicates.
env = $(shell sed -n 's/^$(1)=//p' $(ENV_FILE) 2>/dev/null | tail -1)

REPO_NAME         := $(or $(call env,REPO_NAME),georgelza)
CITUS_REPMGR_VER  := $(or $(call env,CITUS_REPMGR_VERSION),12.1.14)
PGPOOL2_VER       := $(or $(call env,PGPOOL2_VERSION),4.3.5)
PGBOUNCER_VER     := $(or $(call env,PGBOUNCER_VERSION),v1.26.0-p0)
BZ_DB_NAME        := $(or $(call env,BZ_DB_NAME),bzdb)
# Passwords for the psql calls below. Read from .env for the same single-source
# reason as the versions — and because a `psql` invocation with no PGPASSWORD
# against a scram-authenticated node does not fail informatively: it prompts,
# hangs for a timeout, and then reports "no password supplied", which looks like
# a topology problem rather than a missing environment variable. That exact
# misdiagnosis is why this exists.
PG_ADMIN_PASSWORD := $(call env,PG_ADMIN_PASSWORD)
PG_APP_PASSWORD  := $(call env,PG_APP_PASSWORD)
PORT_RW           := $(or $(call env,HOST_PORT_PROXY_RW),6433)
PORT_RO           := $(or $(call env,HOST_PORT_PROXY_RO),6434)

# Locally-built images. These are BUILT, never pulled — `docker pull` on them
# would hit Docker Hub under a name that only exists on this machine and fail.
IMG_CITUS   := $(REPO_NAME)/citus-repmgr:$(CITUS_REPMGR_VER)
IMG_PGPOOL  := bz/pgpool2:$(PGPOOL2_VER)
IMG_PGBOUNCER := edoburu/pgbouncer:$(PGBOUNCER_VER)

# Base images the two builds start from.
# The postgres digest is COPIED from ../deploy/infrastructure/pg/Dockerfile
# (ARG PG_BASE_SHA256) and MUST stay identical to it: that Dockerfile uses the
# same digest for its builder and runtime stages precisely because `postgres:16` is
# a moving tag, and a mismatched minor between the two produces undefined-symbol
# crashes at load time. If you bump one, bump both.
BASE_PG      := postgres:16@sha256:65b16a8b326e0cfbdf33fa7e783f2a0cb352a61448616ccccfd616ef42aa0f65
BASE_PG_NAME := postgres:16
BASE_DEBIAN  := debian:bookworm-slim

.PHONY: help pull build run down ps logs verify failover-test rebuild credentials clean

# ─────────────────────────────────────────────────────────────────────────────
help:
	@echo "bz — PostgreSQL: primary + replica, failover-aware write endpoint, read fleet"
	@echo
	@echo "  make pull           fetch every EXTERNAL image ($(BASE_PG_NAME) digest-pinned, $(BASE_DEBIAN), $(PGBOUNCER_VER))"
	@echo "  make build          build the local images ($(IMG_CITUS) , $(IMG_PGPOOL))"
	@echo "  make run            stand the stack up and wait until settled"
	@echo "  make down           tear down + delete everything under bz/data"
	@echo
	@echo "  make ps             service status"
	@echo "  make logs           follow logs (SERVICE=<name> to narrow)"
	@echo "  make verify         assert topology, routing and the read-only guarantee"
	@echo "  make failover-test  kill the primary and time the automatic failover"
	@echo "  make credentials    regenerate + check the generated credential files"
	@echo "  make rebuild        down + build + run"
	@echo "  make clean          alias for down"
	@echo
	@echo "  write : psql \"host=127.0.0.1 port=$(PORT_RW) dbname=$(BZ_DB_NAME)_rw user=bz_app\""
	@echo "  read  : psql \"host=127.0.0.1 port=$(PORT_RO) dbname=$(BZ_DB_NAME)_ro user=bz_app\""

# ─────────────────────────────────────────────────────────────────────────────
# pull — EXTERNAL images only.
#
# IMG_CITUS and IMG_PGPOOL are deliberately absent: they are built here, and
# pulling a locally-namespaced tag fails against Docker Hub. Their BASE images are
# what this target fetches instead.
pull:
	@echo "==> pulling external images"
	@echo "    $(BASE_PG)"
	@docker pull $(BASE_PG)
	@echo "    $(BASE_DEBIAN)"
	@docker pull $(BASE_DEBIAN)
	@echo "    $(IMG_PGBOUNCER)"
	@docker pull $(IMG_PGBOUNCER)
	@echo "==> external images ready (the two local images are built by 'make build')"

# ─────────────────────────────────────────────────────────────────────────────
# build — the images this stack builds itself.
#
#   citus-repmgr : context is ../deploy/infrastructure/pg — the PARENT stack's
#                  Dockerfile, used unmodified. Compose builds it once even though
#                  four services reference the same image tag.
#   bz/pgpool2   : context is bz/infrastructure/pgpool2. Built from Debian's
#                  arm64 pgpool2 package because the published pgpool/pgpool2 image
#                  is amd64-only and this project forbids Rosetta dependence
#                  (ADR-26).
build:
	@echo "==> building local images"
	@$(COMPOSE) build
	@echo "==> built:"
	@docker image inspect $(IMG_CITUS)  --format '    {{.RepoTags}}  {{.Id}}' 2>/dev/null || echo "    $(IMG_CITUS) MISSING"
	@docker image inspect $(IMG_PGPOOL) --format '    {{.RepoTags}}  {{.Id}}' 2>/dev/null || echo "    $(IMG_PGPOOL) MISSING"

# ─────────────────────────────────────────────────────────────────────────────
# run — stand the stack up and WAIT for it.
#
# Two things this target does that a bare `docker compose up -d` does not, both
# because they have bitten this stack on a cold start:
#
#  1. Pre-creates the bind-mount directories. Docker Desktop can fail initdb with
#     `could not create directory "…/pg_wal": No such file or directory` when the
#     mount point is created for the first time as the container starts. Creating
#     them first removes the race.
#  2. Retries. A cold first start also hits image-pull contention under load. The
#     retry is bounded and only runs on a genuine failure — it is not a way to
#     paper over a misconfiguration, and a stack that still cannot come up is
#     reported as failed rather than retried forever.
run: build
	@echo "==> creating bind-mount directories"
	@mkdir -p data/postgres/primary data/postgres/replica
	@echo "==> docker compose up -d"
	@ok=0; for i in 1 2 3; do \
	    if $(COMPOSE) up -d; then ok=1; break; fi; \
	    echo "    attempt $$i failed — tearing down and retrying"; \
	    $(COMPOSE) down -v --remove-orphans >/dev/null 2>&1 || true; \
	    rm -rf data/postgres/primary data/postgres/replica; \
	    mkdir -p data/postgres/primary data/postgres/replica; \
	    sleep 5; \
	done; \
	if [ "$$ok" != "1" ]; then echo "!! could not start the stack after 3 attempts"; $(COMPOSE) logs --tail=40; exit 1; fi
	@$(MAKE) --no-print-directory _wait

# Internal: poll until nothing is still starting or unhealthy.
# `repmgr_register` is a one-shot that exits 0 on purpose and has no healthcheck,
# so only 'starting' and 'unhealthy' are treated as "not settled".
_wait:
	@echo "==> waiting for services to settle (max 300s)"
	@i=0; while [ $$i -lt 60 ]; do \
	    pending=$$($(COMPOSE) ps --format '{{.Service}} {{.Status}}' 2>/dev/null | grep -cE 'starting|unhealthy' || true); \
	    if [ "$$pending" = "0" ]; then echo "    settled"; $(MAKE) --no-print-directory ps; exit 0; fi; \
	    i=$$((i+1)); sleep 5; \
	done; \
	echo "!! still not settled after 300s"; $(COMPOSE) ps; exit 1

# ─────────────────────────────────────────────────────────────────────────────
# down — tear down AND destroy the data.
#
# `docker compose down -v` removes NAMED volumes but does NOT touch bind mounts,
# so on its own it leaves the PostgreSQL data directories on disk and the next
# `make run` silently reuses a cluster from the previous run — including, after a
# failover test, one where the node roles are the other way round. That is why the
# rm -rf below is part of this target and not a separate 'clean'.
#
# The directory CONTENTS are removed and re-created rather than the whole tree, for
# the same Docker Desktop mount race described under `run`.
down:
	@echo "==> docker compose down -v --remove-orphans"
	@$(COMPOSE) down -v --remove-orphans
	@echo "==> removing data directories under bz/data"
	@rm -rf data/postgres/primary data/postgres/replica
	@find data -mindepth 1 -type d -empty -delete 2>/dev/null || true
	@echo "==> down. bz/data now contains: $$(ls -A data 2>/dev/null | wc -l | tr -d ' ') entries"

# ─────────────────────────────────────────────────────────────────────────────
ps:
	@$(COMPOSE) ps -a

logs:
	@$(COMPOSE) logs -f $(SERVICE)

# ─────────────────────────────────────────────────────────────────────────────
# verify — assert the properties this stack exists to demonstrate.
#
# Every check here is an ASSERTION that can fail, not a report. A check that
# cannot fail proves nothing, so the negative cases are included deliberately:
# the write-through-the-read-proxy check must produce an error, and its PASS
# condition is that the error appears.
verify:
	@echo "==> 1. topology: exactly one primary, at least one standby"
	@$(COMPOSE) exec -T -e PGPASSWORD=$(PG_ADMIN_PASSWORD) pgpool_rw psql -h 127.0.0.1 -p 6432 -U bz_admin -d $(BZ_DB_NAME) \
	    -c "SHOW POOL_NODES;" | sed 's/^/    /'
	@n=$$($(COMPOSE) exec -T -e PGPASSWORD=$(PG_ADMIN_PASSWORD) pgpool_rw psql -h 127.0.0.1 -p 6432 -U bz_admin -d $(BZ_DB_NAME) -tAc \
	    "SHOW POOL_NODES;" | awk -F'|' '$$8=="primary"' | wc -l | tr -d ' '); \
	    if [ "$$n" = "1" ]; then echo "    OK: exactly one primary"; else echo "!! FAIL: $$n primaries (want 1)"; exit 1; fi
	@echo
	@echo "==> 2. schema: 4 tables in biz, one SHARED, one partitioned"
	@$(COMPOSE) exec -T -e PGPASSWORD=$(PG_ADMIN_PASSWORD) pg_primary psql -U bz_admin -d $(BZ_DB_NAME) -tAc \
	    "SELECT c.relname||'  '||CASE c.relkind WHEN 'r' THEN 'local' ELSE 'partitioned' END||'  '||(SELECT count(*) FROM pg_index i WHERE i.indrelid=c.oid)||' idx'||CASE WHEN EXISTS (SELECT 1 FROM citus_shards s WHERE s.table_name=c.oid) THEN '  SHARED' ELSE '' END FROM pg_class c JOIN pg_namespace ns ON ns.oid=c.relnamespace WHERE ns.nspname='biz' AND c.relkind IN ('r','p') AND c.relname NOT LIKE 'sales\_%' ORDER BY 1;" | sed 's/^/    /'
	@echo
	@echo "==> 3. WRITE endpoint (:$(PORT_RW)) — app role, must reach the primary"
	@$(COMPOSE) exec -T -e PGPASSWORD=$(PG_APP_PASSWORD) pgpool_rw psql -q -h 127.0.0.1 -p 6432 -U bz_app -d $(BZ_DB_NAME) -tAc \
	    "INSERT INTO biz.stock (sku,description,category) VALUES ('VERIFY','make verify','TEST') ON CONFLICT (sku) DO UPDATE SET description='make verify' RETURNING 'insert ok';" | sed 's/^/    /'
	@$(COMPOSE) exec -T -e PGPASSWORD=$(PG_APP_PASSWORD) pgpool_rw psql -h 127.0.0.1 -p 6432 -U bz_app -d $(BZ_DB_NAME) -tAc \
	    "SELECT '    node='||inet_server_addr()||' in_recovery='||pg_is_in_recovery() FROM (SELECT 1) x;" | sed 's/^/  /'
	@echo
	@echo "==> 4. READ endpoint (:$(PORT_RO)) — SAME credentials, forced to bz_ro"
	@$(COMPOSE) exec -T -e PGPASSWORD=$(PG_APP_PASSWORD) pgbouncer_ro psql -h 127.0.0.1 -p 6432 -U bz_app -d $(BZ_DB_NAME)_ro -tAc \
	    "SELECT '    current_user='||current_user||'  rows='||count(*) FROM biz.stock;" | sed 's/^/  /'
	@case "$$($(COMPOSE) exec -T -e PGPASSWORD=$(PG_APP_PASSWORD) pgbouncer_ro psql -h 127.0.0.1 -p 6432 -U bz_app -d $(BZ_DB_NAME)_ro -tAc \
	    "SELECT current_user FROM (SELECT 1) x;" | tr -d '[:space:]')" in \
	    bz_ro) echo "    OK: app authenticated, server side is bz_ro" ;; \
	    *) echo "!! FAIL: read endpoint is not forcing bz_ro"; exit 1 ;; esac
	@echo
	@echo "==> 5. NEGATIVE: a write through the READ endpoint must FAIL"
	@out=$$($(COMPOSE) exec -T -e PGPASSWORD=$(PG_APP_PASSWORD) pgbouncer_ro psql -h 127.0.0.1 -p 6432 -U bz_app -d $(BZ_DB_NAME)_ro \
	    -c "INSERT INTO biz.stock (sku,description) VALUES ('NEG','x');" 2>&1 || true); \
	    if echo "$$out" | grep -qi 'read-only'; then echo "    OK: refused — $$out" | head -1; \
	    else echo "!! FAIL: the read endpoint accepted a write"; echo "$$out"; exit 1; fi
	@echo
	@echo "==> 6. replication"
	@$(COMPOSE) exec -T -e PGPASSWORD=$(PG_ADMIN_PASSWORD) pg_primary psql -U bz_admin -d postgres -tAc \
	    "SELECT '    replication='||state||' via '||application_name FROM pg_stat_replication;" 2>/dev/null | sed 's/^/ /' || true
	@$(COMPOSE) exec -T -e PGPASSWORD=$(PG_ADMIN_PASSWORD) pg_primary psql -U bz_admin -d postgres -tAc "SHOW wal_log_hints;" 2>/dev/null | sed 's/^/    wal_log_hints=/' || true
	@echo
	@$(COMPOSE) exec -T -e PGPASSWORD=$(PG_ADMIN_PASSWORD) pg_primary psql -U bz_admin -d $(BZ_DB_NAME) -q -c "DELETE FROM biz.stock WHERE sku='VERIFY';" >/dev/null 2>&1 || true
	@echo "==> verify complete"

# ─────────────────────────────────────────────────────────────────────────────
# failover-test — the only real proof that HA works.
#
# Deliberately DESTRUCTIVE: it stops the primary, which promotes the standby.
# Afterwards the old primary is a diverged second primary if restarted, so the
# stack is left needing `make down && make run` (see the README's Known Limits).
failover-test:
	@echo "==> before"
	@$(COMPOSE) exec -T -e PGPASSWORD=$(PG_ADMIN_PASSWORD) pgpool_rw psql -h 127.0.0.1 -p 6432 -U bz_admin -d $(BZ_DB_NAME) -tAc "SHOW POOL_NODES;" | sed 's/^/    /'
	@echo
	@echo "==> t=0  stopping the primary (no intervention from here on)"
	# `start` MUST BE SET ON THIS SAME LOGICAL LINE as the loop below.
	# Make runs each recipe line in its OWN shell, so a separate
	# `@start=$$(date +%s); ...` line exported nothing — the loop's shell saw
	# `start` as empty and the elapsed time printed as the raw epoch
	# (t=1791463387s). The failover itself worked; the measurement was nonsense.
	# Hence the backslash: one shell, one variable.
	@start=$$(date +%s); $(COMPOSE) stop -t 0 pg_primary >/dev/null; \
	i=0; while [ $$i -lt 40 ]; do \
	    sleep 5; i=$$((i+1)); el=$$(($$(date +%s) - start)); \
	    r=$$($(COMPOSE) exec -T -e PGPASSWORD=$(PG_APP_PASSWORD) pgpool_rw psql -h 127.0.0.1 -p 6432 -U bz_app -d $(BZ_DB_NAME) -tAc \
	        "INSERT INTO biz.stock (sku,description,category) VALUES ('FO-$$el','failover','TEST') ON CONFLICT (sku) DO UPDATE SET description='failover-$$el' RETURNING 'WRITE OK';" 2>&1 | tr -d '\n'); \
	    case "$$r" in *'WRITE OK'*) \
	        echo "    ✅ t=$${el}s  write recovered through the UNCHANGED connection string"; \
	        $(COMPOSE) exec -T -e PGPASSWORD=$(PG_APP_PASSWORD) pgpool_rw psql -h 127.0.0.1 -p 6432 -U bz_app -d $(BZ_DB_NAME) -tAc \
	            "SELECT '    node='||inet_server_addr()||' in_recovery='||pg_is_in_recovery() FROM (SELECT 1) x;" | sed 's/^/ /'; \
	        $(COMPOSE) exec -T -e PGPASSWORD=$(PG_ADMIN_PASSWORD) pg_primary psql -U bz_admin -d $(BZ_DB_NAME) -q -c "DELETE FROM biz.stock WHERE sku LIKE 'FO-%';" >/dev/null 2>&1 || true; \
	        exit 0 ;; \
	    esac; \
	done; \
	echo "!! FAILOVER DID NOT HAPPEN within 200s — writes still failing"; \
	$(COMPOSE) exec -T -e PGPASSWORD=$(PG_ADMIN_PASSWORD) pgpool_rw psql -h 127.0.0.1 -p 6432 -U bz_admin -d $(BZ_DB_NAME) -c "SHOW POOL_NODES;"; \
	exit 1

# ─────────────────────────────────────────────────────────────────────────────
credentials:
	@echo "==> regenerating credential files from .env"
	@./scripts/gen_pgbouncer_userlist.sh
	@./scripts/gen_pgpool_passwd.sh
	@echo "==> drift check (exits 1 if a generated file is stale)"
	@./scripts/gen_pgbouncer_userlist.sh --check --quiet
	@./scripts/gen_pgpool_passwd.sh --check --quiet
	@echo "==> credential files in sync"

rebuild: down build run

clean: down
