# RUNBOOK.md — on-call

wellis-status: portal (Lambda, Node/Express behind a Function URL) +
notifier (Lambda, Python, on a 15-minute schedule) over one Neon
Postgres database. All commands below assume `AWS_PROFILE=
backendlab-production` and region `eu-central-1`.

## Alarms

All 5 alarms notify the same SNS topic (`wellis-status-alerts`) on both
`ALARM` and `OK`, by email.

### `wellis-status-portal-5xx`
**Means:** the portal's Function URL returned ≥3 5xx responses in 5
minutes — the app itself is erroring on real requests, not just slow.
**First command:**
```
aws logs tail /aws/lambda/wellis-status-portal --since 15m --filter-pattern '{ $.level = "error" }'
```
Or run the saved Logs Insights query `wellis-status/errors` in the
CloudWatch console (covers both log groups at once).
**Likely fix:** usually a bad deploy — roll back (below). If the errors
are all DB-shaped, check whether `portal-down`/`notifier-lambda-errors`
are also firing; that points at Neon, not the portal's own code.

### `wellis-status-error-logs`
**Means:** something logged `"level":"error"` in portal *or* notifier —
the shared "something broke" signal (this is the basic error-tracking
substitute; see `FINDINGS.md` APP-04). Fires on send failures, receipt
failures, DB reconnects, and portal's own error middleware, not just
crashes.
**First command:** same as above — the log line itself says what broke.
**Likely fix:** depends entirely on what's in the line. A `send_failed`
event points at the messaging provider (check `MESSAGING_URL`/
`MESSAGING_KEY` in SSM); `receipt_failed` points at S3 permissions;
anything else, read the message.

### `wellis-status-notifier-lambda-errors`
**Means:** the notifier function itself threw/crashed on invocation —
different from `error-logs`'s `send_failed` (that's caught and logged,
not a function error). This is usually "the function couldn't even run."
**First command:**
```
aws logs tail /aws/lambda/wellis-status-notifier --since 15m
```
**Likely fix:** DB connectivity (wrong/expired URL in
`/wellis/prod/notifier/DATABASE_URL`, Neon branch issue) or a bug from a
recent deploy — roll back.

### `wellis-status-overdue-reminders`
**Means:** `OverdueReminders` (queued, `send_at` >30 min in the past) is
above 0 for two 15-minute checks in a row — **or the notifier has
stopped emitting the metric at all** (missing data counts as breaching,
on purpose: a notifier that stopped running has to alarm too, not go
quiet).
**First command:**
```
aws scheduler get-schedule --name wellis-status-notifier --group-name default --query State
aws lambda get-function --function-name wellis-status-notifier --query 'Configuration.LastUpdateStatus'
```
**Likely fix:** re-enable the schedule if it's `DISABLED`; otherwise
check `notifier-lambda-errors` and the messaging provider — a backlog
usually means sends are failing, not that nothing is running.

### `wellis-status-portal-down`
**Means:** the uptime check's `Uptime` metric was <1 for two 5-minute
checks in a row — **or the uptime check itself stopped running**
(missing = breaching, same reasoning as above). The check runs inside
AWS (see `infra/terraform/prod/uptime/handler.py`), so a full AWS-region
outage is a blind spot here, not a false negative.
**First command:**
```
curl -s -o /dev/null -w '%{http_code}\n' "$PORTAL_URL/healthz"
aws logs tail /aws/lambda/wellis-status-uptime --since 15m
```
**Likely fix:** if the curl above also fails, treat as `portal-5xx` (bad
deploy → roll back). If the curl succeeds but the alarm is still red,
check the uptime Lambda's own logs/schedule — the check itself may be
broken, not the portal.

## Deploy / rollback

Normal deploy is automatic: merge to `main`, CI runs `scripts/deploy.sh`
after every other check passes, smoke-tests, and rolls back on its own
if the smoke test fails. To run it by hand:
```
AWS_PROFILE=backendlab-production PORTAL_URL=<function url> ./scripts/deploy.sh <git-sha>
```
Manual rollback to a specific known-good image (find the SHA in ECR or
a past deploy's logs):
```
aws lambda update-function-code --function-name wellis-status-portal \
  --image-uri <account>.dkr.ecr.eu-central-1.amazonaws.com/wellis-status/portal:<sha>
aws lambda wait function-updated --function-name wellis-status-portal
```
Same for `wellis-status-notifier`.

## Running a migration

GitHub → Actions → **Migrate** → Run workflow → type `migrate-prod` in
the `confirm` field. It lints the pending migration, rehearses it on a
throwaway Neon branch, and only touches prod if the rehearsal passes —
see `README.md`. There's no other way to apply a migration to prod;
`scripts/deploy.sh` refuses to ship code while one is pending instead of
running it for you.

## Offboarding someone

```
python3 scripts/access/access.py offboard <id>            # dry run — read the plan first
python3 scripts/access/access.py offboard <id> --apply
```
`--apply` pulls their GitHub access, SSH key, and portal token; flips
`access/team.yaml` to `status: left`; writes an audit record to
`access/audit/`; and prints a manual checklist (messaging dashboard,
Slack, the old GCP project) with an owner for each — do those too, the
script can't reach any of them.

## Restoring the database

Neon keeps continuous point-in-time history — **6 hours on the free
plan**, not a nightly snapshot. To restore: Neon console → the project →
**Branches** → **Create branch** → pick a timestamp within that window
as the parent. This creates a new branch, not a destructive restore of
the main one — verify the data on the branch first, then decide whether
to point the app at it or copy specific rows back. There's no
Terraform/CLI automation for this on purpose; a restore is rare enough,
and consequential enough, to want a human looking at the branch before
anything is repointed.

---

## Original handover (2026-09)

This is what one of us can tell you about the system before you take it
over. It is honest but incomplete. We wrote down what we know is rough; we
almost certainly missed things, because if we'd seen everything we'd have
fixed it.

### What it is

A small internal tool the care team uses to look patients up and queue
appointment reminders. Two moving parts:

- **portal** — a Node/Express API (`portal/`). The care team hits it to see a
  summary and to look patients up by email. Serves on port 8080.
- **notifier** — a Python loop (`notifier/`) that reads queued reminders and
  sends them through our messaging provider, then writes a receipt to a
  cloud bucket.

Both talk to one **Postgres** database. Schema is in `migrations/`, applied
by hand in order. Reminder rows move `queued -> sent`.

### How it runs today

One VM on GCP. Docker Compose on the box. We deploy with
`scripts/deploy.sh`, which rsyncs the working tree up and restarts compose.
There is no CI and no staging. `infra/PROVISIONING.md` is the only record of
how the environment was built, because it was all done by hand in consoles.

### What we already know is rough

- **Secrets are in the repo.** The `.env` is committed. We know that's wrong;
  it was convenient and we never undid it. Assume anything in there needs
  rotating, not just moving.
- **Migration 003 is pending.** It renames the patient name column. It runs
  instantly on our dev copy. It has never run on the full table with the
  notifier live. We are nervous about it and haven't pulled the trigger.
- **No visibility.** If the portal started throwing errors right now, we'd
  find out when the care team messaged us. No metrics, no alerts, no error
  tracking. We don't actually know our uptime.
- **Access is by hand.** `ops/TEAM.md` is the whole access-management system.
  Onboarding and offboarding are a checklist someone runs from memory.
- **One box.** DB and app share a VM. Backups are a nightly dump onto the
  same box. We have never restored one.

### The data

Synthetic. No real patient appears in it. The seed loads ~2,600 patients and
some queued reminders so the app has something to show.

### What we want from you

Bring order to this. We are not expecting all of it fixed in a week — we are
expecting to see how you decide what comes first when it's infrastructure,
security, and plumbing all at once, and someone's health data is sitting in
that database. Tell us what you'd do even where you didn't do it.
