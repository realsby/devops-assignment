-- Product wants first/last split instead of one name field. Replaces the
-- original 003 (see git history / FINDINGS.md DATA-01/DATA-02/DATA-03),
-- which renamed full_name in place and broke every reader of it, wasn't
-- transactional, and mis-split the data. Never applied anywhere — 001
-- and 002 are the only migrations that have run against real data, so
-- there was nothing to migrate away from.
--
-- This version is expand-only: full_name stays, unchanged, as the
-- source of truth. Nothing here can break an existing reader. 004 and
-- the app code keep using full_name — that doesn't change in this
-- migration.
--
-- Contract plan (future migrations, not this one):
--   005: app code switches to reading first_name/last_name instead of
--        full_name, deployed and verified first.
--   006: ADD CONSTRAINT ... CHECK (first_name IS NOT NULL) NOT VALID,
--        then VALIDATE CONSTRAINT in a separate statement/transaction —
--        not a plain SET NOT NULL, which takes ACCESS EXCLUSIVE for a
--        full-table scan (see squawk's adding-not-nullable-field, and
--        the old 003's own DATA-02 finding).
--   much later: drop full_name, once nothing reads it.
--
-- Backfill note: this runs the split against every existing row in one
-- UPDATE. Fine at today's ~2,600 rows; on a real-sized table this would
-- need to be batched (e.g. by id range) and run outside this migration,
-- because scripts/migrate.sh sets a 60s statement_timeout on purpose —
-- it's there to fail fast instead of queueing behind the notifier, not
-- a budget to design a backfill around.

ALTER TABLE patients ADD COLUMN first_name TEXT;
ALTER TABLE patients ADD COLUMN last_name TEXT;

-- Nothing in the app writes patients (only scripts/seed_db.py does, and
-- it runs after this migration, as the owner) — but without this,
-- every row inserted from here on would have first_name/last_name stuck
-- NULL until someone remembered to backfill it again. Keeps the split in
-- sync with full_name for any future insert/update, not just today's.
CREATE OR REPLACE FUNCTION patients_set_first_last_name() RETURNS trigger AS $$
BEGIN
    NEW.first_name := split_part(NEW.full_name, ' ', 1);
    IF position(' ' IN NEW.full_name) = 0 THEN
        NEW.last_name := NULL;
    ELSE
        NEW.last_name := substring(NEW.full_name FROM position(' ' IN NEW.full_name) + 1);
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER patients_first_last_name_trigger
    BEFORE INSERT OR UPDATE OF full_name ON patients
    FOR EACH ROW
    EXECUTE FUNCTION patients_set_first_last_name();

-- Backfill: first word -> first_name, the rest -> last_name.
-- "Sanne de Vries" -> first_name "Sanne", last_name "de Vries".
-- "Bram" (no space) -> first_name "Bram", last_name NULL.
-- WHERE guard makes this idempotent/resumable, not just a one-shot.
UPDATE patients
SET first_name = split_part(full_name, ' ', 1),
    last_name = CASE
        WHEN position(' ' IN full_name) = 0 THEN NULL
        ELSE substring(full_name FROM position(' ' IN full_name) + 1)
    END
WHERE first_name IS NULL;
