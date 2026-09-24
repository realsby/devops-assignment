-- Local-only: creates the two least-privilege login roles the app
-- containers connect as. Dev passwords, not secrets — this only ever
-- runs against the throwaway local/dev Postgres, via
-- docker-entrypoint-initdb.d, which only fires once, on first init of an
-- empty data directory.
--
-- In prod these roles are created by Terraform (a later task).
-- migrations/004_app_role_grants.sql only grants privileges to roles
-- that already exist — it never creates them, on purpose, so the same
-- migration works whether the roles came from this script or from
-- Terraform.
CREATE ROLE portal_app LOGIN PASSWORD 'portal_app_dev_password';
CREATE ROLE notifier_app LOGIN PASSWORD 'notifier_app_dev_password';
