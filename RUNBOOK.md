# wellis-status — the handover

This is what one of us can tell you about the system before you take it
over. It is honest but incomplete. We wrote down what we know is rough; we
almost certainly missed things, because if we'd seen everything we'd have
fixed it.

## What it is

A small internal tool the care team uses to look patients up and queue
appointment reminders. Two moving parts:

- **portal** — a Node/Express API (`portal/`). The care team hits it to see a
  summary and to look patients up by email. Serves on port 8080.
- **notifier** — a Python loop (`notifier/`) that reads queued reminders and
  sends them through our messaging provider, then writes a receipt to a
  cloud bucket.

Both talk to one **Postgres** database. Schema is in `migrations/`, applied
by hand in order. Reminder rows move `queued -> sent`.

## How it runs today

One VM on GCP. Docker Compose on the box. We deploy with
`scripts/deploy.sh`, which rsyncs the working tree up and restarts compose.
There is no CI and no staging. `infra/PROVISIONING.md` is the only record of
how the environment was built, because it was all done by hand in consoles.

## What we already know is rough

- **Secrets are in the repo.** The `.env` is committed. We know that's wrong;
  it was convenient and we never undid it. Assume anything in there needs
  rotating, not just moving.
- **Migration 003 is pending.** It renames the patient name column. It runs
  instantly on our dev copy. It has never run on the full table with the
  notifier live. We are nervous about it and haven't pulled the trigger.
- **No visibility.** If the portal started throwing errors right now, we'd
  find out when the care team messaged us. No metrics, no alerts, no error
  tracking. We don't actually know our uptime.
- **Access is by hand.** `ops/TEAM.md` is the whole access-management system.
  Onboarding and offboarding are a checklist someone runs from memory.
- **One box.** DB and app share a VM. Backups are a nightly dump onto the
  same box. We have never restored one.

## The data

Synthetic. No real patient appears in it. The seed loads ~2,600 patients and
some queued reminders so the app has something to show.

## What we want from you

Bring order to this. We are not expecting all of it fixed in a week — we are
expecting to see how you decide what comes first when it's infrastructure,
security, and plumbing all at once, and someone's health data is sitting in
that database. Tell us what you'd do even where you didn't do it.
