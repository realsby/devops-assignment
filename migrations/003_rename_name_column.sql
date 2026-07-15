-- Product wants first/last split instead of one name field.
-- This is the next migration to run in prod. It has not been applied yet.
--
-- On the ~2,600-row dev copy it finishes instantly. Nobody has run it
-- against the full table with the notifier writing at the same time.

ALTER TABLE patients RENAME COLUMN full_name TO last_name;
ALTER TABLE patients ADD COLUMN first_name TEXT;
UPDATE patients SET first_name = split_part(last_name, ' ', 1);
ALTER TABLE patients ALTER COLUMN first_name SET NOT NULL;
