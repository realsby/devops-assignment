# Integration tests against a real Postgres. Reads DATABASE_URL; falls
# back to the throwaway container used for local/CI runs:
#   docker run -d -p 127.0.0.1:55432:5432 \
#     -e POSTGRES_PASSWORD=postgres -e POSTGRES_DB=wellis postgres:18-alpine
# with migrations/001_init.sql and 002_add_index.sql applied.
import os
import urllib.error
import uuid
from datetime import datetime, timedelta, timezone

import psycopg2
import pytest

import notifier

DATABASE_URL = os.environ.get(
    "DATABASE_URL", "postgresql://postgres:postgres@127.0.0.1:55432/wellis"
)


@pytest.fixture()
def conn():
    connection = psycopg2.connect(DATABASE_URL)
    yield connection
    connection.close()


@pytest.fixture()
def patient(conn):
    cur = conn.cursor()
    email = f"test.{uuid.uuid4().hex}@example.com"
    cur.execute(
        "INSERT INTO patients (full_name, email, dob) VALUES (%s, %s, %s) RETURNING id",
        ("Test Patient", email, "1990-01-01"),
    )
    patient_id = cur.fetchone()[0]
    conn.commit()
    yield patient_id, email
    cur.execute("DELETE FROM reminders WHERE patient_id = %s", (patient_id,))
    cur.execute("DELETE FROM patients WHERE id = %s", (patient_id,))
    conn.commit()


def queue_reminder(conn, patient_id, send_at, channel="email"):
    cur = conn.cursor()
    cur.execute(
        "INSERT INTO reminders (patient_id, channel, send_at, status) "
        "VALUES (%s, %s, %s, 'queued') RETURNING id",
        (patient_id, channel, send_at),
    )
    rid = cur.fetchone()[0]
    conn.commit()
    return rid


def reminder_status(conn, rid):
    cur = conn.cursor()
    cur.execute("SELECT status FROM reminders WHERE id = %s", (rid,))
    return cur.fetchone()[0]


# --- send_one: monkeypatches the actual HTTP call ---


def test_send_one_true_when_http_call_succeeds(monkeypatch):
    monkeypatch.setattr(notifier, "MESSAGING_URL", "https://example.invalid/send")
    monkeypatch.setattr(notifier.urllib.request, "urlopen", lambda *a, **k: None)

    assert notifier.send_one(1, "email", "patient@example.com") is True


def test_send_one_false_when_http_call_raises(monkeypatch):
    monkeypatch.setattr(notifier, "MESSAGING_URL", "https://example.invalid/send")

    def boom(*args, **kwargs):
        raise urllib.error.URLError("boom")

    monkeypatch.setattr(notifier.urllib.request, "urlopen", boom)

    assert notifier.send_one(1, "email", "patient@example.com") is False


def test_send_one_true_in_dry_run_with_no_messaging_url(monkeypatch):
    monkeypatch.setattr(notifier, "MESSAGING_URL", "")

    assert notifier.send_one(1, "email", "patient@example.com") is True


# --- fetch_due: due vs future reminders ---


def test_fetch_due_only_returns_due_reminders(conn, patient):
    patient_id, _ = patient
    now = datetime.now(timezone.utc)
    due_id = queue_reminder(conn, patient_id, now - timedelta(minutes=1))
    future_id = queue_reminder(conn, patient_id, now + timedelta(days=1))

    ids = {row[0] for row in notifier.fetch_due(conn)}

    assert due_id in ids
    assert future_id not in ids


# --- run_once: DB state transitions, HTTP layer monkeypatched out ---


def test_failed_send_leaves_reminder_queued(conn, patient, monkeypatch):
    patient_id, _ = patient
    rid = queue_reminder(conn, patient_id, datetime.now(timezone.utc) - timedelta(minutes=1))
    monkeypatch.setattr(notifier, "send_one", lambda rid, channel, email: False)

    counts = notifier.run_once(conn)

    assert counts["failed"] == 1
    assert counts["sent"] == 0
    assert reminder_status(conn, rid) == "queued"


def test_successful_send_marks_reminder_sent(conn, patient, monkeypatch):
    patient_id, _ = patient
    rid = queue_reminder(conn, patient_id, datetime.now(timezone.utc) - timedelta(minutes=1))
    monkeypatch.setattr(notifier, "send_one", lambda rid, channel, email: True)
    monkeypatch.setattr(notifier, "write_receipt", lambda sent: None)

    counts = notifier.run_once(conn)

    assert counts["sent"] == 1
    assert counts["failed"] == 0
    assert reminder_status(conn, rid) == "sent"
