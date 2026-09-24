# wellis-status

Internal tool for the Wellis care team: look patients up, queue appointment
reminders.

**If you're here for the take-home, start with [ASSIGNMENT.md](ASSIGNMENT.md).**
Then read [RUNBOOK.md](RUNBOOK.md), the handover memo from the people who have
been running this system.

All data in this repository is synthetic. No real person appears in it.

## Run it locally

```
make up
```

One command, no `.env` file needed. Builds the images, brings up Postgres,
runs migrations as the owner, seeds demo data, then starts `portal` and
`notifier` connected as their own least-privilege roles. Prints the URL and
a couple of `curl` examples (portal requires `Authorization: Bearer
<token>` on everything under `/api` — a fixed, local-only dev token is
printed with it).

`make down` tears the stack down, `make logs` tails it, `make test` runs
both test suites in containers against the compose DB — as the app roles,
not the owner, so the grants in `migrations/004_app_role_grants.sql` are
actually exercised.

Note: `migrations/003_add_first_last_name.sql` adds `first_name`/
`last_name` alongside `full_name` (expand-only — nothing renamed, nothing
made `NOT NULL`, nothing dropped) and backfills/triggers them from
`full_name`. `full_name` stays the source of truth for now; `004` and the
app code keep reading/writing it unchanged. The original in-place-rename
version of 003 is gone — it was never applied anywhere (see git history
and `FINDINGS.md` DATA-01/DATA-02/DATA-03 for what was wrong with it).

## Layout

- `portal/` — Node/Express API (port 8080)
- `notifier/` — Python reminder sender; same image runs as a Lambda
  handler or, locally, as a polling loop
- `migrations/` — SQL, applied in order by `scripts/migrate.sh`
- `db/init/` — local-only: creates the app DB roles (Terraform does this
  in prod)
- `infra/` — how the environment was built (no IaC yet)
- `scripts/` — deploy, migrate, seed, test
- `ops/` — crontab, team/access notes
- `Makefile` — `up` / `down` / `test` / `logs`
