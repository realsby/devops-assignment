"""
Reminder notifier.

Sends each due reminder through the messaging provider, then (optionally)
writes a no-PII receipt to S3. Two entry points:

  - main()             loop for local/dev use; reconnects if the DB drops
  - handler(event, ctx) single pass for AWS Lambda: connect, run once, close
"""
import json
import logging
import os
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone

import boto3
import psycopg2

from load_ssm_params import load_ssm_params

logging.basicConfig(level=logging.INFO, format="%(message)s")
log = logging.getLogger("notifier")

# No-op locally (SSM_PARAMETER_PATH unset); on Lambda this has to run
# before the os.environ.get() calls below, not just before main()/
# handler() — those calls happen once, at import time.
load_ssm_params()

DATABASE_URL = os.environ.get(
    "DATABASE_URL", "postgresql://postgres:postgres@127.0.0.1:5432/wellis"
)

# Empty MESSAGING_URL means dry-run: log instead of calling a real provider.
MESSAGING_URL = os.environ.get("MESSAGING_URL", "")
MESSAGING_KEY = os.environ.get("MESSAGING_KEY", "")

# No default bucket — a missing var must skip the receipt, never fall back
# to a real one.
RECEIPT_BUCKET = os.environ.get("RECEIPT_BUCKET", "")


def connect():
    return psycopg2.connect(DATABASE_URL)


def fetch_due(conn):
    cur = conn.cursor()
    cur.execute(
        "SELECT r.id, r.channel, p.email "
        "FROM reminders r JOIN patients p ON p.id = r.patient_id "
        "WHERE r.status = 'queued' AND r.send_at <= now() "
        "ORDER BY r.send_at LIMIT 50"
    )
    return cur.fetchall()


def count_overdue(conn):
    """queued reminders whose send_at is more than 30 minutes in the
    past -- the "patients aren't getting reminders" signal. Due-but-not-
    yet-late reminders don't count; this is specifically about the ones
    sitting there."""
    cur = conn.cursor()
    cur.execute(
        "SELECT count(*) FROM reminders "
        "WHERE status = 'queued' AND send_at < now() - interval '30 minutes'"
    )
    return cur.fetchone()[0]


def emf_log(due, sent, failed, overdue):
    """One Embedded Metric Format log line. CloudWatch Logs parses any
    line with an `_aws` key like this into custom metrics on its own --
    no PutMetricData call, no library. Outside Lambda (local/dev, or
    anywhere logs aren't shipped to CloudWatch) this is just a JSON log
    line; nothing else treats `_aws` as special.

    flush=True on purpose: stdout is block-buffered (not line-buffered)
    once it's not attached to a terminal, which is exactly the case
    inside a container or Lambda. Without this, the line can sit in
    Python's internal buffer indefinitely -- confirmed locally: without
    the flush, this line never showed up in `docker logs` even after
    several 30-second loop iterations, while the plain log.info() calls
    elsewhere always appeared immediately (logging's StreamHandler
    flushes on every emit by default; a bare print() does not)."""
    print(
        json.dumps(
            {
                "_aws": {
                    "Timestamp": int(time.time() * 1000),
                    "CloudWatchMetrics": [
                        {
                            "Namespace": "WellisStatus",
                            "Dimensions": [[]],
                            "Metrics": [
                                {"Name": "RemindersDue", "Unit": "Count"},
                                {"Name": "RemindersSent", "Unit": "Count"},
                                {"Name": "RemindersFailed", "Unit": "Count"},
                                {"Name": "OverdueReminders", "Unit": "Count"},
                            ],
                        }
                    ],
                },
                "RemindersDue": due,
                "RemindersSent": sent,
                "RemindersFailed": failed,
                "OverdueReminders": overdue,
            }
        ),
        flush=True,
    )


def send_one(rid, channel, email):
    """Returns True if the send succeeded (dry-run counts as success)."""
    if not MESSAGING_URL:
        log.info(json.dumps({"event": "send_dry_run", "reminder_id": rid, "channel": channel}))
        return True

    payload = json.dumps({"to": email, "channel": channel}).encode()
    req = urllib.request.Request(
        MESSAGING_URL,
        data=payload,
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {MESSAGING_KEY}",
        },
    )
    try:
        urllib.request.urlopen(req, timeout=5)
        return True
    except Exception as exc:  # noqa: BLE001 - one bad send must not stop the batch
        log.warning(
            json.dumps(
                {
                    "level": "error",
                    "event": "send_failed",
                    "reminder_id": rid,
                    "channel": channel,
                    "error": str(exc),
                }
            )
        )
        return False


def write_receipt(sent):
    """sent: list of (id, channel). No PII — ids and channel only."""
    if not RECEIPT_BUCKET:
        return
    body = json.dumps(
        {
            "generated_at": datetime.now(timezone.utc).isoformat(),
            "reminders": [
                {"id": rid, "channel": channel, "status": "sent"} for rid, channel in sent
            ],
        }
    )
    try:
        client = boto3.client("s3")
        client.put_object(
            Bucket=RECEIPT_BUCKET, Key=f"receipts/{int(time.time())}.json", Body=body.encode()
        )
    except Exception as exc:  # noqa: BLE001 - a receipt failure must not crash the run
        log.warning(json.dumps({"level": "error", "event": "receipt_failed", "error": str(exc)}))


def run_once(conn):
    """Processes due reminders. Returns {"due", "sent", "failed"} counts."""
    rows = fetch_due(conn)
    sent = []
    failed = 0
    for rid, channel, email in rows:
        if send_one(rid, channel, email):
            cur = conn.cursor()
            cur.execute("UPDATE reminders SET status = 'sent' WHERE id = %s", (rid,))
            conn.commit()
            sent.append((rid, channel))
            log.info(json.dumps({"event": "sent", "reminder_id": rid, "channel": channel}))
        else:
            # Left as 'queued' on purpose — the next run retries it.
            failed += 1

    if sent:
        write_receipt(sent)

    overdue = count_overdue(conn)
    counts = {"due": len(rows), "sent": len(sent), "failed": failed, "overdue": overdue}
    log.info(json.dumps({"event": "run_complete", **counts}))
    emf_log(len(rows), len(sent), failed, overdue)
    return counts


def main():
    conn = connect()
    try:
        while True:
            try:
                run_once(conn)
            except psycopg2.OperationalError as exc:
                log.warning(json.dumps({"level": "error", "event": "db_reconnect", "error": str(exc)}))
                try:
                    conn.close()
                except Exception:  # noqa: BLE001
                    pass
                conn = connect()
            time.sleep(30)
    finally:
        conn.close()


def handler(event, context):  # noqa: ARG001 - Lambda calling convention
    conn = connect()
    try:
        return run_once(conn)
    finally:
        conn.close()


if __name__ == "__main__":
    main()
