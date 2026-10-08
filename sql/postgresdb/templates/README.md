# templates/

`schema.sql` — the `biz` schema: **4 tables** (`customer`, `address`, `stock`,
`sales`), one shared/distributed, one partitioned, 16 indexes.

It is database- and role-name-agnostic on purpose (`current_database()`, and
`app_user` / `ro_user` / `admin_user` arriving as psql variables), so the same
template works against any database name without editing.

**Applied by `../01_bootstrap.sh` with `psql` in autocommit mode — no
`-1`/`--single-transaction`.** `create_distributed_table()` cannot run inside a
transaction block, so wrapping this call in one fails. It is applied once, at
first init; the template is not re-runnable against a populated database.

The file's own header documents the design, including the Citus foreign-key rule
that dictates which table may be distributed and why `address.customer_id` carries
no constraint.
