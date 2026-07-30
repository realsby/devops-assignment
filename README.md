# wellis-status

Internal tool for the Wellis care team: look patients up, queue appointment
reminders.

**If you're here for the take-home, start with [ASSIGNMENT.md](ASSIGNMENT.md).**
Then read [RUNBOOK.md](RUNBOOK.md), the handover memo from the people who have
been running this system.

All data in this repository is synthetic. No real person appears in it.

## Run it locally

```
docker compose up -d db
psql "postgresql://postgres:postgres@127.0.0.1:5432/wellis" < migrations/001_init.sql
psql "postgresql://postgres:postgres@127.0.0.1:5432/wellis" < migrations/002_add_index.sql
python3 scripts/seed_db.py
docker compose up -d --build portal notifier
curl http://127.0.0.1:8080/api/summary
```

## Layout

- `portal/` — Node/Express API (port 8080)
- `notifier/` — Python reminder sender
- `migrations/` — SQL, applied by hand in order
- `infra/` — how the environment was built (no IaC yet)
- `scripts/` — deploy and seed
- `ops/` — crontab, team/access notes
