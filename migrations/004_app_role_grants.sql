-- Least-privilege grants for the two app roles. Run as the owner.
--
-- This migration does NOT create portal_app / notifier_app — see
-- db/init/01_roles.sql (local) or Terraform (prod, later task). If the
-- roles don't exist yet when this runs, it fails loudly, which is the
-- point: grants to a role that doesn't exist yet is a sequencing bug,
-- not something to paper over here.

-- portal: looks patients up by email, reads/queues reminders.
GRANT SELECT (id, full_name, email, dob) ON patients TO portal_app;
GRANT SELECT ON reminders TO portal_app;
GRANT INSERT ON reminders TO portal_app;
GRANT USAGE ON SEQUENCE reminders_id_seq TO portal_app;

-- notifier: only ever needs the patient's id/email to send, reads
-- reminders to find due ones, and flips status to 'sent' — nothing else.
GRANT SELECT (id, email) ON patients TO notifier_app;
GRANT SELECT ON reminders TO notifier_app;
GRANT UPDATE (status) ON reminders TO notifier_app;
