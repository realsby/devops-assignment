# FINDINGS.md — Part A triage

Read: `ASSIGNMENT.md`, `RUNBOOK.md`, every tracked file, and `git log -p` on
`main` (all 12 commits). Data is synthetic but ranked as if it were real
patient health data, per the brief.

Severity: **critical** (data breach / patient-safety / total compromise, low
effort to trigger) · **high** (serious but needs one more condition, or
degrades safety/reliability badly) · **medium** · **low**.

Status is **TBD** for every row until we agree the fix plan.

## Top 10 overall (cross-area), ranked

1. SEC-01 — SQL injection in patient lookup
2. SEC-02 — No auth on any endpoint
3. SEC-03 — Postgres port open to the internet
4. SEC-04/05/06 — Leaked & over-privileged credentials (env secrets in git + GCP owner-level key in history)
5. APP-02/APP-02b — notifier sends reminders early and marks failed sends as delivered
6. SEC-10 — Staging runs on the live messaging key, sends real messages
7. SEC-08 — Offboarded contractor still has SSH + GCP editor access
8. DATA-01 — Migration 003 breaks both services on apply (see DATA-02 for the locking risk on top of that)
9. INFRA-02 — Backups: plausibly broken, unencrypted, same disk as the DB, no retention, no offsite copy
10. APP-04/APP-10 — PHI in plaintext logs and in GCS receipts with no retention

---

## Secrets & credentials

| ID | Title | Where | Why it matters | Severity | Status |
|---|---|---|---|---|---|
| SEC-04 | Live secrets committed to git, never rotated | `.env:6-8`, `.env.staging:6-8`; introduced commit `90c1d36`, `7ddfec0` | Real-shaped DB password + a `live_`-prefixed messaging API key sit in plaintext in the repo history; staging reuses the exact same DB password and key as prod — one leak compromises both | critical | TBD |
| SEC-05 | GCP service-account key was committed to git history | `sa-key.json` added in `03873fd`, untracked (not deleted from history) in `15a128a` | The key is already present in every existing clone; deleting the file from the tip and adding it to `.gitignore` doesn't revoke exposure. **Rotating the key is the actual fix.** A history rewrite is optional and, on its own, un-leaks nothing for anyone who already has a clone | critical | TBD |
| SEC-06 | The leaked service-account key is `roles/owner` on the whole GCP project | `infra/PROVISIONING.md` (`ops-sa@...`, `roles/owner`) | It's provisioned only to write to one GCS bucket. A leaked key (see SEC-05) hands over the entire project — compute, IAM, billing, everything — not just the receipts bucket | critical | TBD |
| SEC-07 | App and notifier both connect to Postgres as the `postgres` superuser | `portal/src/db.js:3-9`; `notifier/notifier.py` DB dict | No least privilege at the DB layer; the SQL injection in SEC-01 (or any future bug) has full superuser reach, not just `patients`/`reminders` | high | TBD |
| SEC-10 | Staging runs on the live/production messaging key | `.env.staging:8` (`MESSAGING_KEY=live_…`, same value as `.env:8`) | This is separate from "the secrets are reused" (SEC-04): because the key is live, anything sent from staging is a **real message through the real provider account** to whatever address is in the staging DB — testing against staging can actually page/text real people | critical | TBD |
| SEC-15 | `RECEIPT_BUCKET` defaults to the prod bucket name in code | `notifier/notifier.py:26` (`RECEIPT_BUCKET = os.environ.get("RECEIPT_BUCKET", "wellis-receipts-prod")`) | Any environment where this var is missing or misconfigured — a future local run, a new environment, a typo'd env file — silently writes real receipt data (PHI, see APP-10) into the **production** bucket instead of failing loudly or writing nowhere | high | TBD |

## Application security (authn/authz/injection/access)

| ID | Title | Where | Why it matters | Severity | Status |
|---|---|---|---|---|---|
| SEC-01 | SQL injection in patient lookup | `portal/src/index.js:27-33` (`GET /api/patients`, string-built query) | Unauthenticated, single request, full read (and via Postgres's multi-statement simple-query protocol, potential write/DROP) access to every patient record | critical | TBD |
| SEC-02 | No authentication or authorization on any route | `portal/src/index.js` — all 3 routes | Patient PHI lookup and reminder creation are open to anyone who can reach port 8080, which (see SEC-03) is the whole internet | critical | TBD |
| SEC-03 | Postgres port exposed to 0.0.0.0/0 | `docker-compose.yml:13` (`0.0.0.0:5432:5432`) + `infra/PROVISIONING.md` firewall rule opening tcp:5432 | The database is reachable directly from the internet with the same password that's sitting in git (SEC-04) — a bypass of the app layer entirely | critical | TBD |
| SEC-08 | Offboarded contractor still has live access | `ops/TEAM.md` (Tomas row: "contract ended, offboarding TODO"); `ops/authorized_keys:5` (`tomas-ext`) | Contract ended Apr 2026; SSH key and GCP `editor` role are still active — a real, present insider-risk path to patient data, not a hypothetical | high | TBD |
| SEC-09 | SSH open to 0.0.0.0/0, authorized_keys "never pruned" | `infra/PROVISIONING.md` (`default-allow-ssh`); `ops/authorized_keys:2` | World-reachable SSH plus a key list nobody prunes widens the box's attack surface beyond what's needed | medium | TBD |
| SEC-11 | Access is broader than roles need | `ops/TEAM.md`: Rover (Web) has prod SSH + GCP editor; Hossam (Payments) has GCP viewer on the project holding patient data | Neither role has an obvious reason to reach the patient-data project at all, let alone with SSH/editor — access was handed out ad hoc rather than scoped to what each role actually needs | medium | TBD |
| SEC-12 | No audit trail of who accessed which patient; one shared SSH user | No per-user attribution anywhere: lookups aren't logged against a user (see SEC-02, no auth); `ops/TEAM.md` + `scripts/deploy.sh` — everyone SSHes in as one shared `deploy@` account | No individual accountability for who looked up or touched a given patient's record. Relevant under **NEN 7513** (the Dutch standard for audit logging of access to patient data), not just general good practice | high | TBD |
| SEC-13 | Patient email travels in the URL query string | `portal/src/index.js:27-29` (`GET /api/patients?email=...`) | Independent of the app's own logging (APP-04), the email lands in any intermediary's access logs — load balancer, proxy, CDN — plus browser history and Referer headers wherever this URL is used from a browser context | low | TBD |
| SEC-14 | `status.wellis.internal` is a public DNS record pointing at a public IP | `infra/PROVISIONING.md` ("Set by hand in Cloudflare") | The name implies restricted/internal-only reachability but it's a normal public A record — misleading naming aside, it also just publicly advertises the hostname for a system that shouldn't be internet-facing at all (see SEC-02/SEC-03) | low | TBD |
| APP-05 | Messaging provider key sent inside the request body, not a header | `notifier/notifier.py:49` | Non-standard; more likely to be captured by logging/proxying on either side than an `Authorization` header would be | low | TBD |
| APP-08 | No input validation on `POST /api/reminders` | `portal/src/index.js:36-43` — `patient_id`, `channel`, `send_at` taken straight from the request body into the `INSERT` | An invalid `patient_id` trips the FK constraint and (per APP-01) crashes the whole portal; `channel` and `send_at` are otherwise unconstrained strings/values, so a reminder can be queued for a bogus channel or an already-past time | medium | TBD |

## Runtime & reliability bugs (code-level, not just config)

| ID | Title | Where | Why it matters | Severity | Status |
|---|---|---|---|---|---|
| APP-02 | Reminders are marked `sent` even when the send failed | `notifier/notifier.py`: `send_one` swallows the HTTP exception (`except Exception: print`) and `run_once` unconditionally runs `UPDATE reminders SET status='sent'` right after | For a medical reminder system this is silent data loss: a patient can miss an appointment because the send failed, and the DB says it went out. No retry, no dead-letter, no alert | critical | TBD |
| APP-02b | notifier ignores `send_at` — every queued reminder goes out on the very next loop, not at its scheduled time | `notifier/notifier.py`: `fetch_queued`'s query has no `send_at <= now()` filter, only `WHERE r.status = 'queued' ORDER BY r.send_at LIMIT 50` | A reminder scheduled for 3 days from now is sent within the next 30-second loop tick instead. This is a patient-facing correctness bug, not just an ops risk — ranked together with APP-02 since both mean "the patient did not get what the system believes it sent" | critical | TBD |
| APP-01 | Unhandled DB/query errors crash the whole portal process | `portal/src/index.js` — every route `await`s `pool.query` with no try/catch, no error middleware; Express 4 does not catch async-handler rejections, so it becomes an unhandled promise rejection | Any transient DB hiccup, malformed request, or a schema mismatch (see DATA-01) takes down the *entire* service, and `docker-compose.yml` has no `restart:` policy on `portal` — it stays down until someone notices manually | critical | TBD |
| APP-06 | Unhandled exception in `write_receipt` can crash the notifier after reminders are already marked sent | `notifier/notifier.py`: `write_receipt(rows)` call in `run_once` has no try/except, unlike `send_one`'s HTTP call | GCS auth/network failure kills the process mid-batch; the per-row `UPDATE ... status='sent'` + `commit()` already happened, so a crash here loses the receipt with no retry, while the reminders are already (possibly wrongly, see APP-02) marked sent | high | TBD |
| APP-07 | notifier opens one DB connection for the life of the process, never reconnects | `notifier/notifier.py`: `main()` calls `psycopg2.connect(**DB)` once, outside the `while True` loop | Any DB restart or network blip after that point raises on the next query and is unhandled — the process dies and depends entirely on the 5-minute cron restart (`ops/CRONTAB.txt`) to come back, extending the reminder-delivery gap | medium | TBD |
| APP-03 | Unbounded in-memory list, never cleared | `notifier/notifier.py:29` (`sent_this_process`), appended every send in the infinite `while True` loop | Long-running process leaks memory indefinitely (holding email/DOB — PII — in RAM) until OOM-killed; comment literally says "Never cleared" | high | TBD |
| APP-04 | PHI written to plaintext logs | `notifier/notifier.py:44-48` (full name, email, DOB per send); `portal/src/index.js:9` (whole request body), `:31` (looked-up email) | Health-adjacent PII in stdout with no redaction, no access control, no retention policy — gets worse the moment any log shipping/observability is added | high | TBD |
| APP-10 | Receipts written to GCS contain full patient rows in plaintext, kept indefinitely | `notifier/notifier.py`: `write_receipt` uploads `json.dumps([list(r) for r in rows])` — includes `full_name`, `email`, `dob` per reminder | PHI at rest in object storage with no encryption-at-rest policy called out and no lifecycle/retention rule on the bucket — and per SEC-15, a misconfigured env can send it to the wrong (prod) bucket entirely | high | TBD |

## Data & migrations

| ID | Title | Where | Why it matters | Severity | Status |
|---|---|---|---|---|---|
| DATA-01 | Migration 003 renames the exact column both services query by name | `migrations/003_rename_name_column.sql:7` (`full_name` → `last_name`) vs. `portal/src/index.js:29` and `notifier/notifier.py:35` (both `SELECT ... full_name ...`) | RUNBOOK only says the team is "nervous"; the concrete effect isn't mentioned there — applying it as-is instantly breaks patient lookup (500s) and crashes the notifier's query (unhandled, see APP-01-style failure) the moment it runs, with no coordinated app deploy. See DATA-02 for the locking risk on top of this | critical | TBD |
| DATA-02 | Migration 003 takes an `ACCESS EXCLUSIVE` lock with no `lock_timeout`, and isn't wrapped in a transaction | `migrations/003_rename_name_column.sql` — all 4 statements, no `BEGIN`/`COMMIT`, no `SET lock_timeout` | `RENAME COLUMN` and, especially, `ALTER COLUMN ... SET NOT NULL` both require `ACCESS EXCLUSIVE`; the `NOT NULL` step additionally does a full-table scan while holding it (no existing `CHECK` constraint to skip the scan). With no `lock_timeout`, if the notifier is mid-transaction on `patients` when this runs, the `ALTER` queues — and once queued, it blocks every other query, reads included, behind it. **This is the real shape of "we're nervous about it,"** not just "untested at scale." On top of that, a failure partway (e.g. at the `NOT NULL` step) leaves the table half-migrated with no down-migration | critical | TBD |
| DATA-03 | The name-split logic is wrong, independent of the coordination and locking problems | `migrations/003_rename_name_column.sql:9` (`first_name = split_part(last_name, ' ', 1)`) | `last_name` keeps the *entire* original full name (never actually reduced to a surname); only `first_name` is correctly extracted. E.g. "Sanne de Vries" → `first_name="Sanne"`, `last_name="Sanne de Vries"` — a real data-quality bug, not just an ops risk | medium | TBD |
| DATA-04 | No migration tooling or version tracking | `migrations/`, README | "Applied by hand in order," no schema_version table, no checksums — nothing stops a skipped, reordered, or double-applied migration across dev/staging/prod | medium | TBD |

## Infrastructure & build

| ID | Title | Where | Why it matters | Severity | Status |
|---|---|---|---|---|---|
| INFRA-01 | Single VM runs DB + both app services, click-ops provisioned | `infra/PROVISIONING.md` | No IaC, no redundancy; the box is a SPOF for the whole system (RUNBOOK already flags this — carried into inventory for completeness) | high | TBD |
| INFRA-02 | Backups are plausibly a silent no-op, and even if they run they're unsafe | `ops/CRONTAB.txt:7` (`pg_dump wellis > /home/deploy/wellis-$(date +\%F).sql`, run from host cron) vs. `infra/PROVISIONING.md` (Postgres only exists *inside* the `db` container; nothing documents installing `postgresql-client` on the host or setting `PGUSER`/`PGPASSWORD`/`PGHOST` in cron's environment) | Two stacked problems: (1) as written this almost certainly fails every night (`pg_dump: command not found`, or auth failure for a `deploy` role that doesn't exist in Postgres) — inferred, unverified, I couldn't execute anything to confirm; (2) even when it does write, the dump is **unencrypted PHI sitting on the same disk as the live DB** (same blast radius if the box is lost or compromised), with no retention/rotation (the disk fills up over time) and no offsite copy. Lines up with RUNBOOK's "we've never restored one" | high | TBD |
| INFRA-03 | No `.dockerignore`; `COPY . .` copies whatever is in the service dir | `portal/Dockerfile:6`, `notifier/Dockerfile:6` | Build context is the service subdir (`build: ./portal`), so the root `.env` is *not* baked in today. But any `node_modules`, local `.env` or key file dropped into a service dir would ship in the image layers | low | TBD |
| INFRA-04 | Containers run as root on unpinned, mutable base images | `portal/Dockerfile:1,8` (`node:latest`, root, called out in comment); `notifier/Dockerfile:1` (`python:3.11` full image, no `USER`) | Larger attack surface, no least privilege inside the container, and `node:latest` can silently jump major Node versions on a rebuild — non-reproducible builds | medium | TBD |
| INFRA-05 | No restart/health policy on any container | `docker-compose.yml` — no `restart:` key anywhere | `db` and `portal` have zero auto-recovery if they crash; `notifier` gets a partial fix from the 5-min cron restart (`ops/CRONTAB.txt:4`), which still means up to 5 minutes of silent downtime with no monitoring to notice it | high | TBD |
| INFRA-06 | No CI, no real staging, no tests | `scripts/deploy.sh`; `portal/src/index.test.js` (placeholder only); `.env.staging` exists but nothing in the repo deploys to it | No test gate, no review gate, no audit trail of what shipped when — the deploy mechanics themselves are covered separately in INFRA-08 | high | TBD |
| INFRA-07 | No dependency pinning / lockfile | `portal/package.json` (no `package-lock.json`, Dockerfile runs `npm install` not `npm ci`); `notifier/requirements.txt` (both deps fully unpinned) | Builds aren't reproducible; a routine rebuild can silently pull a different (or compromised) dependency version | medium | TBD |
| INFRA-08 | Deploy ships whatever is on the laptop's disk, not what's committed | `scripts/deploy.sh:12` (`rsync -az --exclude node_modules --exclude .git ./ "$BOX:/opt/wellis-status/"` — no git-clean check, no commit/tag actually deployed) | Prod can run code that was never committed, reviewed, or pushed anywhere — there's no artifact or commit SHA that corresponds to "what's actually running," and rollback means guessing. The same rsync also re-ships `.env` to the box on every deploy | high | TBD |
| OBS-01 | No monitoring, logging pipeline, error tracking, or alerting at all | whole repo — no such config exists | Confirmed by absence, already flagged in RUNBOOK. If the portal or notifier is down or silently misbehaving (see APP-01/APP-02/APP-02b), the care team finds out before the team does | high | TBD |
