-- Speed up the care-team email lookup.
CREATE INDEX idx_patients_email ON patients (email);
CREATE INDEX idx_reminders_status ON reminders (status);
