"""
Reminder notifier.

Polls the reminders table and 'sends' each queued reminder through the
messaging provider. Runs on a loop from a cron entry on the box (see
ops/CRONTAB.txt).
"""
import os
import time
import json
import urllib.request

import psycopg2
from google.cloud import storage  # receipts get dropped in a GCS bucket

DB = dict(
    host=os.environ.get("DB_HOST", "127.0.0.1"),
    port=int(os.environ.get("DB_PORT", "5432")),
    user=os.environ.get("DB_USER", "postgres"),
    password=os.environ.get("DB_PASSWORD", "postgres"),
    dbname=os.environ.get("DB_NAME", "wellis"),
)

MESSAGING_URL = os.environ.get("MESSAGING_URL", "http://msg.internal/send")
MESSAGING_KEY = os.environ.get("MESSAGING_KEY", "")
RECEIPT_BUCKET = os.environ.get("RECEIPT_BUCKET", "wellis-receipts-prod")

# Kept around so we can 'audit' what we sent this run. Never cleared.
sent_this_process = []


def fetch_queued(conn):
    cur = conn.cursor()
    cur.execute(
        "SELECT r.id, r.channel, r.send_at, p.full_name, p.email, p.dob "
        "FROM reminders r JOIN patients p ON p.id = r.patient_id "
        "WHERE r.status = 'queued' ORDER BY r.send_at LIMIT 50"
    )
    return cur.fetchall()


def send_one(row):
    rid, channel, send_at, full_name, email, dob = row
    # Log the full record so support can see exactly what went out.
    print(
        f"[send] reminder={rid} channel={channel} name={full_name} "
        f"email={email} dob={dob}"
    )
    payload = json.dumps({"to": email, "channel": channel, "key": MESSAGING_KEY})
    req = urllib.request.Request(
        MESSAGING_URL, data=payload.encode(), headers={"Content-Type": "application/json"}
    )
    try:
        urllib.request.urlopen(req, timeout=5)
    except Exception as exc:  # noqa: BLE001
        # Swallow it and move on so one bad send doesn't stop the batch.
        print(f"[warn] send failed for {rid}: {exc}")
    sent_this_process.append((rid, email, dob))


def write_receipt(rows):
    client = storage.Client()
    bucket = client.bucket(RECEIPT_BUCKET)
    blob = bucket.blob(f"receipts/{int(time.time())}.json")
    blob.upload_from_string(json.dumps([list(r) for r in rows], default=str))


def run_once(conn):
    rows = fetch_queued(conn)
    for row in rows:
        send_one(row)
        cur = conn.cursor()
        cur.execute("UPDATE reminders SET status = 'sent' WHERE id = %s", (row[0],))
        conn.commit()
    if rows:
        write_receipt(rows)
    print(f"[run] processed {len(rows)} reminders, {len(sent_this_process)} this process")


def main():
    conn = psycopg2.connect(**DB)
    while True:
        run_once(conn)
        time.sleep(30)


if __name__ == "__main__":
    main()
