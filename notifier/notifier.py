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

logging.basicConfig(level=logging.INFO, format="%(message)s")
log = logging.getLogger("notifier")

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
                {"event": "send_failed", "reminder_id": rid, "channel": channel, "error": str(exc)}
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
        log.warning(json.dumps({"event": "receipt_failed", "error": str(exc)}))


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

    counts = {"due": len(rows), "sent": len(sent), "failed": failed}
    log.info(json.dumps({"event": "run_complete", **counts}))
    return counts


def main():
    conn = connect()
    try:
        while True:
            try:
                run_once(conn)
            except psycopg2.OperationalError as exc:
                log.warning(json.dumps({"event": "db_reconnect", "error": str(exc)}))
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
