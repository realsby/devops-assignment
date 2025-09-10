"""
Load synthetic patients and a few queued reminders so the app has something
to show. Deterministic. No real person appears here.

    python3 scripts/seed_db.py
"""
import os
import random
import datetime

import psycopg2

DB = dict(
    host=os.environ.get("DB_HOST", "127.0.0.1"),
    port=int(os.environ.get("DB_PORT", "5432")),
    user=os.environ.get("DB_USER", "postgres"),
    password=os.environ.get("DB_PASSWORD", "postgres"),
    dbname=os.environ.get("DB_NAME", "wellis"),
)

FIRST = ["Sanne", "Jeroen", "Fatima", "Daan", "Emma", "Mohammed", "Sophie",
         "Lucas", "Julia", "Sven", "Noor", "Bram", "Isa", "Thijs", "Yara"]
LAST = ["de Vries", "Jansen", "Bakker", "Visser", "Smit", "Meijer", "Mulder",
        "de Boer", "Bos", "Vos", "Peters", "Hendriks", "Dekker", "Brouwer"]

random.seed(20260731)


def main():
    conn = psycopg2.connect(**DB)
    cur = conn.cursor()
    cur.execute("SELECT count(*) FROM patients")
    if cur.fetchone()[0] > 0:
        print("patients already loaded, skipping")
        return
    rows = []
    for i in range(2600):
        fn = random.choice(FIRST)
        ln = random.choice(LAST)
        name = f"{fn} {ln}"
        email = f"{fn.lower()}.{ln.split()[-1].lower()}{i}@example.com"
        dob = datetime.date(random.randint(1955, 2006), random.randint(1, 12),
                            random.randint(1, 28))
        phone = f"+3161{random.randint(1000000, 9999999)}"
        rows.append((name, email, dob, phone))
    cur.executemany(
        "INSERT INTO patients (full_name, email, dob, phone) VALUES (%s,%s,%s,%s)",
        rows,
    )
    cur.execute("SELECT id FROM patients ORDER BY random() LIMIT 40")
    ids = [r[0] for r in cur.fetchall()]
    now = datetime.datetime.now()
    for pid in ids:
        cur.execute(
            "INSERT INTO reminders (patient_id, channel, send_at, status) "
            "VALUES (%s, 'email', %s, 'queued')",
            (pid, now + datetime.timedelta(hours=random.randint(1, 72))),
        )
    conn.commit()
    print(f"seeded {len(rows)} patients and {len(ids)} queued reminders")


if __name__ == "__main__":
    main()
