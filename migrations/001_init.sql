-- Applied by hand on the box: psql wellis < migrations/001_init.sql
CREATE TABLE patients (
    id SERIAL PRIMARY KEY,
    full_name TEXT NOT NULL,
    email TEXT NOT NULL,
    dob DATE,
    phone TEXT,
    created_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE reminders (
    id SERIAL PRIMARY KEY,
    patient_id INTEGER REFERENCES patients(id),
    channel TEXT NOT NULL,
    send_at TIMESTAMPTZ NOT NULL,
    status TEXT NOT NULL DEFAULT 'queued',
    created_at TIMESTAMPTZ DEFAULT now()
);
