# PostgreSQL: Primary + Replica, with a failover-aware write endpoint and a read fleet

A highly available/scalable **PostgreSQL** estate.  

It exists to answer one question properly: *how do you put a replica behind a pooler
so reads come off the primary, writes never touch a standby, and the write endpoint
survives the primary dying without anyone touching anything?*

> **Non-technical audience:** see [`docs/Overview.md`](docs/Overview.md) — the
> business-level view of what this design does, why it is built this way, and what
> it deliberately does **not** yet do. This document is the technical build and
> operating manual; that one is the executive summary.

```
   ALL DML ──────────▶ ┌────────────────────────────────────────────────┐
   (bz_app, :6433)     │  pgpool_rw   Pgpool-II                         │
                       │    • one endpoint, always the current primary  │
                       │    • health check + SR check ⇒ knows who writes│
                       │    • primary dies ⇒ promotes a standby itself  │
                       └──────────┬──────────────────────────┬──────────┘
                                  │                          │
                      ┌───────────▼──────────┐   ┌───────────▼───────────┐
                      │  pg_primary   :5432  │   │  pg_replica   :5432   │
                      │  WRITABLE            │   │  hot standby, READS   │
                      │  PG16 Citus repmgr   │──▶│  until promoted       │
                      └──────────────────────┘   └───────────────────────┘
                            streaming replication

   ALL READS ─────────▶ ┌──────────────────────────────────────────────┐
   (bz_app, :6434)      │  pgbouncer_ro   PgBouncer                    │
                        │    • host LIST = every node, round-robin     │
                        │    • user=bz_ro ⇒ server side is read-only   │
                        └──────────────────────────────────────────────┘
```

### Scaling

- To scale reads,
  - increase the replica's

- To scale writes, 
  - First increase shards. 
  - Second have each shard configured as a primary (read/writer) with 1 or more read replica's.


## The Application uses ONE credential set

`bz_app` / `bz_app_dev_pw` works on **both** endpoints. Only the port differs.
That is deliberate: an earlier design gave the read proxy a *different* role, so
every caller had to know it had one identity per endpoint — exactly the sort of
thing that breaks silently when someone copies a DSN.

How the read side stays read-only, if the login is the same:

| | mechanism |
|:--|:--|
| PgBouncer `[databases]` entry | `user=bz_ro` — every **server-side** connection runs as `bz_ro`, whatever the client authenticated as |
| Database | `bz_ro` holds `SELECT` and no `INSERT/UPDATE/DELETE` on anything |
| Database | `ALTER ROLE bz_ro SET default_transaction_read_only = on` |

Two independent locks in the database, which is where a read-only guarantee
belongs — not in an auth file. Verified: `current_user` is `bz_ro` when `bz_app`
connects to `:6434`, and a write there returns
`ERROR: cannot execute INSERT in a read-only transaction`.

## Quick Start

```bash
cd bz
make run          # pull-less build, stand up, WAIT until settled
make ps           # all six services healthy
make verify       # assert topology, routing and the read-only guarantee
```

The four targets you asked for:

| Target | What it does |
|:--|:--|
| `make pull` | Fetches every **external** image: `postgres:16` (digest-pinned), `debian:bookworm-slim`, `edoburu/pgbouncer`. Deliberately does **not** pull the two locally-built images — those exist only on this machine, so pulling them would fail against Docker Hub. |
| `make build` | Builds `citus-repmgr` (context `../deploy/infrastructure/pg`, the parent stack's Dockerfile, unmodified) and `bz/pgpool2` (context `./infrastructure/pgpool2`). |
| `make run` | Creates the bind-mount dirs, brings the stack up, then **waits** until nothing is starting or unhealthy. Retries a cold start twice — Docker Desktop fails `initdb` with a `pg_wal` bind-mount race on a first run, and a retry is the correct response to that specific race rather than a way to hide a misconfiguration. |
| `make down` | `compose down -v --remove-orphans` **and deletes every data directory under `bz/data`**. |

`down` removing the data is not cosmetic. `docker compose down -v` removes named
volumes but **not** bind mounts, so on its own it leaves the cluster on disk — and
after a failover test the next `make run` silently brings back a cluster whose node
roles are the other way round.

Also available: `make verify` · `make failover-test` · `make credentials` ·
`make rebuild` · `make ps` · `make logs SERVICE=<name>`. Run `make` for the list.

Version tags live in `.env`, not in the Makefile — it reads them out, so there is
one source of truth.

```
# write — pool name bzdb_rw
psql "host=127.0.0.1 port=6433 dbname=bzdb_rw user=bz_app"
# read  — pool name bzdb_ro, SAME user and password
psql "host=127.0.0.1 port=6434 dbname=bzdb_ro user=bz_app"
```

> `dbname` is the **pool** name, not the database name. The database is `bzdb`.
> Connecting to `bzdb` on a proxy port fails with `FATAL: no such database: bzdb`,
> which reads like a missing database and is not.

Credentials are in [`.env`](.env) — local development values, committed on purpose
so the stack runs with no setup.

## Services

| # | Service | Role |
|:--|:--|:--|
| 1 | `pg_primary` | The writer. PG16 · Citus 12.1 · repmgr 5.5. Citus coordinator+worker (single node). |
| 2 | `pg_replica` | Streaming standby. **Re-enabled** (commented out in `deploy/` since 2026-08-26). |
| 3 | `pgpool_rw` | **Write endpoint**, failover-aware. Host port 6433. |
| 4 | `pgbouncer_ro` | **Read endpoint**, spread across nodes. Host port 6434. |
| 5 | `repmgr_register` | One-shot: registers the primary in `repmgr.nodes`, exits 0. |
| 6 | `repmgrd_primary` | repmgrd metadata/monitoring. Does **not** fail over. |

Ports are 6433/6434 because the parent stack's PgBouncer owns 6432 on this host.

## Automatic Failover — measured, not asserted

Kill the primary and writes continue on the standby **with no intervention**:

```
$ docker stop -t 0 bz-pg-primary
t=5s   ✅ WRITE OK through the unchanged connection string
       write now on 172.18.0.3/32  in_recovery=false
       read  endpoint : bz_ro sees 2 rows
       pre-failover row: 1          ← nothing committed was lost
       health: healthy
```

It works because Pgpool-II health-checks each backend **and** runs a streaming
replication check, so it knows which node is the writer. When that node fails it
runs `failover_command`, which promotes the standby with `SELECT pg_promote()`.
Recovery measured at **5–10s** (5s health period × 3 retries × 2s delay, plus SR
check).

### The one thing that will silently break this

`failover_command` placeholders are **not** what they look like. Measured on this
stack by recording every one:

| placeholder | value | meaning |
|:--|:--|:--|
| `%d` | `0` | the **detached (old primary)** node id |
| `%h` | `bz-pg-primary` | the **detached (old primary)** host |
| `%H` | `bz-pg-replica` | **the new primary's host** ← the promotion target |
| `%p` | `5432` | detached node's port |
| `%D` | `/var/lib/postgresql/data` | detached node's data directory |

So the correct line is `failover_command = '/etc/pgpool2/failover.sh %H %h'`.
The version used `%d %h`, which compiled, ran, exited **0**, and promoted nothing —
because it asked Pgpool-II to promote the node that had just died. There is no
error and no log line; writes simply keep failing with `cannot execute INSERT in
a read-only transaction` while the standby sits there perfectly promotable. If
this line is ever changed, the only proof is a failover test, not a zero exit code.

## The read endpoint

```ini
bzdb_ro = host=bz-pg-primary,bz-pg-replica port=5432 dbname=bzdb \
          user=bz_ro pool_mode=transaction load_balance_hosts=round-robin
```

* **Round-robin is per server connection, not per query.** 8 concurrent readers →
  4 primary / 4 replica. 8 sequential readers → all 8 on one node, because serial
  traffic reuses the single warm connection and never advances the rotation.
  `server_round_robin = 1` is set so that once several connections exist they
  share traffic rather than one LIFO connection taking almost all of it.
* **`min_pool_size` is 0.** It was briefly 2 on the theory that two warm
  connections would sit on two nodes; measured, `SHOW POOLS` still reported
  `sv_idle = 1` and sequential reads all landed on the primary. Not carrying a
  value that does not do what its comment would claim.
* **A host list is NOT a failover list.** PgBouncer's own docs: *"in a list, all
  hosts must be available at all times: there are no mechanisms to skip unreachable
  hosts"*. Measured here: with one node dead, 32 reads (20 serial + 12 concurrent)
  all succeeded — but that is an observation, not a promise, and clients should
  still retry a read error. An earlier version of this file (and of
  `docker-compose.yml`) claimed PgBouncer "fails over to the next host", which is
  wrong; both have been corrected.
* Scaling to six read nodes = append six hosts to that one line.

## Health Checking (and two traps)

`pgpool_rw`'s healthcheck asserts **exactly one node whose `pg_role` is primary**.
Zero means writes have no target; two means split-brain with diverged data.

Two versions of this check were wrong, and both are recorded in
`docker-compose.yml`:

1. It once also **required a standby** — so after a *successful* failover it
   reported unhealthy while the write path was working perfectly. A check that
   cries wolf on a healthy system is a check nobody reads.
2. It counted `|primary|primary|`, which matches the pair (`role`, `pg_role`).
   When the old primary was restarted after a failover it returned believing it
   was primary, giving `primary|primary` and `standby|primary` — exactly **one**
   match, so the check passed while two primaries held divergent history. It now
   counts column 8 (`pg_role`), which catches it. Verified: that state → `unhealthy`.

Note the node healthchecks also assert role rather than inferring it: the primary
requires `pg_is_in_recovery() = false`, the replica `= true`. **After a failover
the replica's own healthcheck correctly fails**, because it is no longer a
replica. That is right, not a bug.

## Schema — 4 tables, 1 schema

All in schema **`biz`**. Each table demonstrates a different placement strategy,
and the split is forced by Citus's foreign-key rules (a distributed table may not
reference a local one), not chosen for variety.

| Table | Strategy | Why |
|:--|:--|:--|
| `biz.customer` | **local** | real FKs point at it |
| `biz.address` | **shared** — Citus distributed on `customer_id`, 4 shards | grows forever; co-located per customer |
| `biz.stock` | plain reference table | small, stable, hot |
| `biz.sales` | **partitioned** `RANGE (sold_at)`, monthly + default | prune; detach closed months |

`biz.address` is distributed on **`customer_id`, not `address_id`**: every UNIQUE
index on a distributed table must include the distribution column, and the partial
unique index below (`one primary address per customer per type`) is on
`(customer_id, address_type)`. With `address_id` as the distribution column
`create_distributed_table()` rejects the table outright. Choosing `customer_id`
makes that index legal *and* puts a customer's addresses on one node.

16 indexes across the four tables; the three `sales_*` indexes are declared on the
**parent** so PostgreSQL also creates them on every partition added later. Details
and the reasoning for each are in
[`sql/postgresdb/templates/schema.sql`](sql/postgresdb/templates/schema.sql).

## Replication

| Piece | Where | Why |
|:--|:--|:--|
| `wal_level=replica`, `max_wal_senders=10`, `hot_standby=on` | inherited | |
| `wal_keep_size = 1GB` | bz addition | a downed replica can still catch up by streaming |
| `bz_replica_slot` | created in `01_bootstrap.sh` | primary retains WAL for a *named* slot |
| `primary_slot_name=bz_replica_slot` | `pg_replica`'s **command line** | one conf file is mounted into both nodes |
| `hot_standby_feedback = on` | bz addition | the replica serves real reads |
| `wal_log_hints = on` | bz addition | **required for the rejoin path** — see below |

## Known Limits — read before relying on this

1. **`pgpool_rw` is a single point of failure for writes.** If that one container
   dies, writes stop even though the database is perfectly healthy. The usual
   remedy is two or more Pgpool-II instances behind a TCP load balancer with
   `use_watchdog = on` and `delegate_IP`. **Not built here**.
2. **Rebuilding the old primary needs `pg_rewind`, and it needed a config change
   to become possible.** After a failover the old primary has *diverged* — it was
   the writer when it died, the standby was promoted and took writes, and its
   timeline is a dead branch. `pg_rewind` (which `repmgr standby follow` uses)
   refuses to run without `wal_log_hints` or data checksums; **both were off**,
   so there was no way to rejoin a diverged node at all. `wal_log_hints = on` is
   now set, which is the cheap half of that choice (no initdb-time decision).
   Enabling it does not retroactively help a cluster that already diverged.
   Until the rejoin procedure is exercised end to end, **assume re-clone**.
3. **No automated rejoin.** Nothing rebuilds the old primary after a failover; it
   stays stopped until an operator acts.
4. **Asynchronous replication.** A failover can lose the last few transactions
   that were not yet replayed. This is a lab; a bank wants synchronous
   replication and `synchronous_standby_names`, and must then decide what a
   starved primary does.
5. **Citus is single-node** here. The distributed table has 4 shards on one node.

## Verify it yourself

```bash
cd bz
make verify         # the automated version of everything below
make failover-test  # kill the primary and time the recovery
```

Or by hand:

```bash

# 1. who is primary, who is a standby  (this is the failover view)
docker compose exec pgpool_rw \
  psql -h 127.0.0.1 -p 6432 -U bz_admin -d bzdb -c "SHOW POOL_NODES;"

# 2. writes work, and go to the primary
docker compose exec pgpool_rw \
  psql -h 127.0.0.1 -p 6432 -U bz_app -d bzdb \
  -c "INSERT INTO biz.stock (sku,description,category) VALUES ('T1','t','T');"

# 3. reads work with the SAME credentials, and are read-only
docker compose exec pgbouncer_ro \
  psql -h 127.0.0.1 -p 6432 -U bz_app -d bzdb_ro \
  -c "SELECT current_user, count(*) FROM biz.stock;"

# 4. a write on the read endpoint must FAIL
docker compose exec pgbouncer_ro \
  psql -h 127.0.0.1 -p 6432 -U bz_app -d bzdb_ro \
  -c "INSERT INTO biz.stock (sku,description) VALUES ('X','x');"

# 5. THE FAILOVER TEST — the only real proof
docker stop -t 0 bz-pg-primary
docker compose exec pgpool_rw \
  psql -h 127.0.0.1 -p 6432 -U bz_app -d bzdb \
  -c "INSERT INTO biz.stock (sku,description,category) VALUES ('T2','t','T');"
docker compose exec pgpool_rw \
  psql -h 127.0.0.1 -p 6432 -U bz_admin -d bzdb -c "SHOW POOL_NODES;"
docker compose start bz-pg-primary        # NB: comes back as a SECOND primary
```

Step 5's last line is deliberate: restarting the old primary brings it back
believing it is the writer, which is split-brain. `pgpool_rw` correctly goes
`unhealthy`. Recover by destroying and re-cloning it (see limit 2), not by
starting it and hoping.

Full rebuild:

```bash
docker compose down -v
find data -mindepth 2 -delete      # delete CONTENTS, not the dirs — see below
docker compose up -d --build
```

## Traps found the hard way, all recorded in-file

| Symptom | Cause |
|:--|:--|
| Writes succeeded, reads never spread | round-robin is per *connection*; serial traffic reuses one |
| `unrecognized connection parameter: force_user` | PgBouncer has no `force_user`; the key is `user=` |
| `unrecognized connection parameter: options` | not a `[databases]` key in 1.26 |
| `pool_passwd file does not contain an entry for "pgbouncer"` | Pgpool-II's format is `user:password`, not `"user" "password"` — and `pgbouncer` is not a PostgreSQL role |
| `backend authentication failed … kind 'E' when expecting 'R'` | `auth_type` must be `scram-sha-256`, not `md5`, against scram backends |
| Both nodes reported `role=standby, pg_role=unknown` | primary/standby comes from the **SR check**, not the health check |
| `unrecognized configuration parameter "sr_check_max_retries"` | pgpool2 4.3.5 has no such setting |
| `could not open pid file "/var/run/postgresql/pgpool.pid"` | pgpool2 4.3.5 **ignores** `pid_file`; chown that directory instead |
| No logs at all, while serving fine | setting `log_directory` switches logging **off** in this build; leave it unset |
| `ERROR: pid file found. is another pgpool(7) is running?` | `pgpool -n` is not side-effect-free; clear the stale pid file first |
| failover promoted nothing, writes `read-only transaction` | `%d %h` is the **old** primary; use `%H` |
| `pg_stat_replication` empty as `bz_admin` | pg_stat_* needs superuser or `pg_read_all_stats`; `bz_admin` is granted `pg_monitor` for this |
| `make verify` reported 0 primaries on a healthy cluster | `psql` with no `PGPASSWORD` against a scram node — prompts, times out, says "no password supplied", and looks like a topology fault |
| `relation "repmgr.nodes" does not exist` | `CREATE DATABASE repmgr` does not install the extension |
| `permission denied for schema repmgr` | the extension is owned by the superuser; hand the schema to the repl role |
| repmgrd exits 1, invisible in `docker logs` | `shared_preload_libraries` needs `repmgr`, and repmgrd redirects to its own log file first |
| `initdb: could not create directory …/pg_wal` | Docker Desktop bind-mount race; retry, and clear dir *contents* rather than removing the dirs |
| `syntax error at or near ":"` in schema.sql | psql does not substitute `:'var'` inside a `$$` body |





## THE END

And like that we’re done with our little trip down another Rabbit Hole, Till next time. 

Thanks for following. 


### The Rabbit Hole

<img src="blog-doc/diagrams/rabbithole.jpg" alt="Our Build" width="450" height="350">


### ABOUT ME

I’m a techie, a technologist, always curious, love data, have for as long as I can remember always worked with data in one form or the other, Database admin, Database product lead, data platforms architect, infrastructure architect hosting databases, backing it up, optimizing performance, accessing it. Data data data… it makes the world go round.
In recent years, pivoted into a more generic Technology Architect role, capable of full stack architecture.

### By: George Leonard

- georgelza@gmail.com
- https://www.linkedin.com/in/george-leonard-945b502/
- https://medium.com/@georgelza



<img src="blog-doc/diagrams/TechCentralFeb2020-george-leonard.jpg" alt="Me" width="400" height="400">





## Layout

```
bz/
├── Makefile                  # pull / build / run / down (+ verify, failover-test)
├── docker-compose.yml
├── .env                      # dev credentials — local only
├── conf/
│   ├── pg/                   # copied from deploy/; bz additions marked in-file
│   ├── pgpool2/              # pgpool.conf, pool_hba.conf, pool_passwd (generated), failover.sh
│   └── pgbouncer/ro/         # the read endpoint (userlist.txt is generated)
├── infrastructure/pgpool2/   # arm64 pgpool2 image (Debian package — the published one is amd64-only)
├── scripts/                  # credential generators + the repmgr one-shot
├── sql/postgresdb/           # mounted at /docker-entrypoint-initdb.d on the PRIMARY only
│   ├── 01_bootstrap.sh
│   └── templates/schema.sql  # the 4-table biz schema
├── docs/
│   ├── Overview.md           # business-level overview — start here for non-technical readers
│   └── diagrams/             # graphics for Overview.md (PlantUML source + rendered PNG/SVG)
│       ├── 01-business-context.puml / .png / .svg
│       ├── 02-two-door-model.puml / .png / .svg
│       ├── 03-failover-journey.puml / .png / .svg
│       ├── 04-integrity-controls.puml / .png / .svg
│       ├── 05-growth-capacity.puml / .png / .svg
│       └── 06-data-families.puml / .png / .svg
└── data/postgres/{primary,replica}/
```

### Diagrams

`docs/diagrams/` holds the source for every graphic in
[`docs/Overview.md`](docs/Overview.md) as `.puml`, alongside the rendered
`.png` and `.svg`. The images are committed so the business document renders
without a toolchain; regenerate them with:

```bash
cd docs/diagrams
for f in *.puml; do
  curl -s -X POST https://kroki.io/plantuml/png \
    -H "Content-Type: text/plain" --data-binary "@$f" -o "${f%.puml}.png"
done
```

> Rendering notes, in case you extend them: this PlantUML build rejects
> multi-lane swimlanes and `legend` inside activity diagrams, prints
> `<<#COLOR>>` reset tokens literally, and mis-colours an activity whose reset
> is mishandled. The activity diagram was therefore reworked as a component
> flow, which renders reliably — see `03-failover-journey.puml`.

---
*End of Document*