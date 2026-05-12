# How the environment got built

There is no Terraform. This is the written-down version of what someone
clicked to stand the thing up. If the box dies, this is what you'd redo by
hand.

## The VM
- GCP project `wellis-status-prod`, region `europe-west4`.
- One `e2-medium` Compute Engine VM, public IP, Ubuntu 22.04.
- Docker + docker compose installed by hand.
- Firewall: `default-allow-ssh` (0.0.0.0/0) and a rule opening tcp:8080 and
  tcp:5432 to 0.0.0.0/0 so we can reach the portal and the DB from anywhere.

## Database
- Runs as a container on the same VM (see docker-compose.yml).
- Nightly `pg_dump` to `/home/deploy` on the box (see ops/CRONTAB.txt).

## Service account
- One service account, `ops-sa@wellis-status-prod.iam.gserviceaccount.com`,
  role `roles/owner`. The notifier uses its key to write receipts to the
  `wellis-receipts-prod` bucket. The key JSON lives on the box at
  `/opt/wellis-status/sa-key.json` and on a couple of laptops.

## DNS
- `status.wellis.internal` points at the VM's public IP. Set by hand in
  Cloudflare.

## What we know is not great
- It's one box. If it goes, the portal and the DB go with it.
- We've never actually restored from one of the dumps.
