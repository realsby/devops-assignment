#!/usr/bin/env python3
"""
access/team.yaml is the source of truth for who can reach wellis-status
and at what level. This script has two jobs:

  review
      Print what team.yaml says, then diff it against the live systems
      this repo can actually check: GitHub collaborators + pending
      invites (via `gh api`), ops/authorized_keys, and the named tokens
      in the portal's SSM API_TOKENS param (skipped with a warning if
      AWS isn't reachable). Exits non-zero on drift. This is the part
      meant to be run regularly / in CI and actually read by a person.

  offboard <id> [--apply]
      Pull a leaver's access. Dry-run by default (prints the plan, sets
      nothing, writes nothing). On --apply:
        - removes the GitHub repo collaborator and any pending invite
          for them. Only ever removes -- never adds anyone, since a
          github username in this file could belong to a real stranger.
        - removes their key from ops/authorized_keys, if present.
        - removes their named token from the portal's SSM API_TOKENS
          param, if one exists.
        - sets status: left (+ end_date) for them in team.yaml, as a
          targeted text edit that leaves every comment in the file
          alone.
        - writes access/audit/<date>-offboard-<id>.json: who ran it,
          what actually changed, what was already a no-op.
        - prints a manual checklist for the systems with no API here
          (messaging dashboard, Slack, the old GCP project), each with
          an owner.
        - prints "rotate" items: shared secrets this person's access
          level means they could have seen.

No third-party dependencies. team.yaml's shape is small and fixed (a
top-level `people` list, each item flat plus one nested `access`
mapping), so it gets a tiny hand-written parser (see _parse_yaml) rather
than taking on PyYAML for a file this shape-constrained. Everything else
shells out to `gh` and `aws`, which is what's actually installed
everywhere this needs to run (a dev machine, or a CI runner).
"""
import argparse
import json
import os
import re
import subprocess
import sys
from datetime import date, datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TEAM_YAML = ROOT / "access" / "team.yaml"
AUTHORIZED_KEYS = ROOT / "ops" / "authorized_keys"
AUDIT_DIR = ROOT / "access" / "audit"

PORTAL_TOKENS_PARAM = "/wellis/prod/portal/API_TOKENS"
AWS_REGION = "eu-central-1"  # matches every other region pin in this repo (Terraform, Neon)

MANUAL_CHECKLIST = [
    ("messaging dashboard", "remove/revoke access for {name}", "ilya"),
    ("Slack", "remove {name} from #eng and #ops", "ilya"),
    ("old GCP project (wellis-status-prod)", "revoke {name}'s GCP access (currently: {legacy_gcp}), if the project is still live", "ilya"),
]


# --------------------------------------------------------------------------
# A tiny YAML subset, just enough for team.yaml's own shape. Not a general
# parser: no anchors, no flow style, no multi-line scalars, no lists of
# scalars. If team.yaml's shape ever needs more than this, it's time to
# take the PyYAML dependency instead of growing this file into one.
# --------------------------------------------------------------------------
def _scalar(raw):
    raw = raw.strip()
    if raw == "" or raw == "~" or raw == "null":
        return None
    if raw in ("yes", "true", "True"):
        return True
    if raw in ("no", "false", "False"):
        return False
    if len(raw) >= 2 and raw[0] == raw[-1] and raw[0] in ("'", '"'):
        return raw[1:-1]
    return raw


def _parse_yaml(text):
    lines = [line for line in text.split("\n") if not re.match(r"^\s*#", line) and line.strip() != ""]
    people = []
    current = None
    current_access = None
    in_access = False

    for raw_line in lines:
        indent = len(raw_line) - len(raw_line.lstrip(" "))
        stripped = raw_line.strip()

        if stripped == "people:":
            continue

        if stripped.startswith("- "):
            if current is not None:
                people.append(current)
            current = {}
            current_access = None
            in_access = False
            stripped = stripped[2:]
            indent += 2  # the "- " counts as part of this item's own indent

        if ":" not in stripped:
            continue
        key, _, value = stripped.partition(":")
        key = key.strip()
        value = value.strip()

        if key == "access":
            in_access = True
            current_access = {}
            current["access"] = current_access
            continue

        # access.* fields are indented deeper than the person's own
        # top-level fields (id, name, role, ...); once we've seen
        # "access:", anything indented under it belongs there.
        if in_access and indent > 4:
            current_access[key] = _scalar(value)
        else:
            in_access = False
            current[key] = _scalar(value)

    if current is not None:
        people.append(current)
    return {"people": people}


def load_team():
    return _parse_yaml(TEAM_YAML.read_text())


def find_person(team, person_id):
    for p in team["people"]:
        if p["id"] == person_id:
            return p
    return None


# --------------------------------------------------------------------------
# Live source: GitHub
# --------------------------------------------------------------------------
def _repo_slug():
    try:
        url = subprocess.run(
            ["git", "remote", "get-url", "origin"], cwd=ROOT, capture_output=True, text=True, check=True
        ).stdout.strip()
    except Exception:
        return None
    m = re.search(r"[:/]([^/:]+/[^/]+?)(\.git)?$", url)
    return m.group(1) if m else None


def _gh(*args):
    """Returns (ok, data_or_error_string)."""
    try:
        result = subprocess.run(
            ["gh", *args], capture_output=True, text=True, timeout=30
        )
    except FileNotFoundError:
        return False, "gh CLI not installed"
    except subprocess.TimeoutExpired:
        return False, "gh CLI timed out"
    if result.returncode != 0:
        return False, (result.stderr or result.stdout).strip()
    return True, result.stdout


def github_state(repo):
    """Returns (ok, collaborators, invitations, error). collaborators is
    {login: role_name}; invitations is {login: invitation_id}."""
    ok, out = _gh("api", "--paginate", f"repos/{repo}/collaborators")
    if not ok:
        return False, {}, {}, out
    collaborators = {c["login"]: c.get("role_name", "unknown") for c in json.loads(out)}

    ok, out = _gh("api", "--paginate", f"repos/{repo}/invitations")
    if not ok:
        return False, collaborators, {}, out
    invitations = {i["invitee"]["login"]: i["id"] for i in json.loads(out) if i.get("invitee")}

    return True, collaborators, invitations, None


def github_remove(repo, username, invitation_id):
    changes = {}
    ok, out = _gh("api", "-X", "DELETE", f"repos/{repo}/collaborators/{username}")
    changes["collaborator_removed"] = bool(ok)
    if not ok:
        changes["collaborator_error"] = out
    if invitation_id is not None:
        ok, out = _gh("api", "-X", "DELETE", f"repos/{repo}/invitations/{invitation_id}")
        changes["invitation_removed"] = bool(ok)
        if not ok:
            changes["invitation_error"] = out
    return changes


# --------------------------------------------------------------------------
# Live source: ops/authorized_keys
# --------------------------------------------------------------------------
def parse_authorized_keys():
    """Returns {label: line_index} for the trailing comment on each key
    line -- that's the only per-person identifier this file has."""
    labels = {}
    if not AUTHORIZED_KEYS.exists():
        return labels
    for i, line in enumerate(AUTHORIZED_KEYS.read_text().splitlines()):
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        parts = stripped.split()
        if len(parts) >= 3:
            labels[parts[-1]] = i
    return labels


def _key_label_for(person):
    """The authorized_keys label doesn't consistently match id or github
    username (see ops/authorized_keys: "ilya" and "rover" are short forms,
    "tomas-ext" is the github handle) -- check both."""
    labels = parse_authorized_keys()
    for candidate in (person["id"], person.get("github")):
        if candidate in labels:
            return candidate
    return None


def authorized_keys_remove(person):
    label = _key_label_for(person)
    if label is None:
        return False
    lines = AUTHORIZED_KEYS.read_text().splitlines()
    kept = [line for line in lines if line.strip().split() == [] or line.strip().split()[-1] != label or line.strip().startswith("#")]
    AUTHORIZED_KEYS.write_text("\n".join(kept) + "\n")
    return True


# --------------------------------------------------------------------------
# Live source: portal SSM API_TOKENS
# --------------------------------------------------------------------------
_CRED_ERROR_HINTS = (
    "unable to locate credentials",
    "expiredtoken",
    "expired token",
    "invalidclienttokenid",
    "assumerole",
    "mfa",
    "could not be found",
    "sso session",
    "requesttokenprovider",
)


def _aws(*args):
    # backendlab-production doesn't carry a default region through its
    # assume-role chain (found this the hard way -- NoRegion errors with
    # no --region passed), so it's explicit on every call rather than
    # relying on AWS_DEFAULT_REGION being set by whoever runs this.
    try:
        result = subprocess.run(
            ["aws", *args, "--region", AWS_REGION], capture_output=True, text=True, timeout=30
        )
    except FileNotFoundError:
        return False, "no-creds", "aws CLI not installed"
    except subprocess.TimeoutExpired:
        return False, "error", "aws CLI timed out"
    if result.returncode == 0:
        return True, "ok", result.stdout
    err = (result.stderr or result.stdout).strip()
    low = err.lower()
    if any(hint in low for hint in _CRED_ERROR_HINTS):
        return False, "no-creds", err
    if "parameternotfound" in low.replace(" ", ""):
        return False, "not-found", err
    return False, "error", err


def portal_tokens_state():
    """Returns (status, token_names, detail).
    status: "ok" | "no-creds" | "not-found" | "error"."""
    ok, status, out = _aws(
        "ssm", "get-parameter", "--name", PORTAL_TOKENS_PARAM, "--with-decryption", "--output", "json"
    )
    if not ok:
        return status, set(), out
    value = json.loads(out)["Parameter"]["Value"]
    names = set()
    for entry in value.split(","):
        entry = entry.strip()
        if ":" in entry:
            names.add(entry.split(":", 1)[0].strip())
    return "ok", names, None


def portal_token_remove(person_id):
    ok, status, out = _aws(
        "ssm", "get-parameter", "--name", PORTAL_TOKENS_PARAM, "--with-decryption", "--output", "json"
    )
    if not ok:
        return False, f"could not read {PORTAL_TOKENS_PARAM}: {out}"
    value = json.loads(out)["Parameter"]["Value"]
    entries = [e.strip() for e in value.split(",") if e.strip()]
    kept = [e for e in entries if not e.startswith(f"{person_id}:")]
    if len(kept) == len(entries):
        return False, "no token for this id in the param"
    ok, status, out = _aws(
        "ssm", "put-parameter", "--name", PORTAL_TOKENS_PARAM, "--type", "SecureString",
        "--value", ",".join(kept), "--overwrite",
    )
    if not ok:
        return False, f"read the token but failed to write it back out: {out}"
    return True, None


# --------------------------------------------------------------------------
# review
# --------------------------------------------------------------------------
def cmd_review(_args):
    team = load_team()
    people = team["people"]
    repo = _repo_slug()

    print(f"# access/team.yaml ({len(people)} people)\n")
    for p in people:
        a = p["access"]
        print(
            f"  {p['id']:<8} {p['name']:<8} {p['role']:<24} status={p['status']:<7} "
            f"github={a['github_repo']:<6} ssh={_yn(a['ssh']):<3} aws={a['aws']:<8} "
            f"legacy_gcp={a.get('legacy_gcp', 'none'):<7} "
            f"portal_token={_yn(a['portal_token']):<3} messaging={_yn(a['messaging_dashboard'])}"
        )

    drift = []

    print(f"\n# checking github ({repo or 'unknown repo'})")
    if repo is None:
        print("  WARNING: could not determine the origin repo (git remote get-url origin failed) -- skipping")
    else:
        ok, collaborators, invitations, err = github_state(repo)
        if not ok:
            print(f"  WARNING: github unavailable ({err}) -- skipping")
        else:
            drift += _diff_github(people, collaborators, invitations)

    print("\n# checking ops/authorized_keys")
    drift += _diff_ssh(people)

    print("\n# checking portal SSM API_TOKENS")
    status, live_names, err = portal_tokens_state()
    if status == "no-creds":
        print(f"  WARNING: AWS not reachable ({err}) -- skipping")
    elif status == "not-found":
        print(f"  WARNING: {PORTAL_TOKENS_PARAM} not found -- has prod been applied yet? -- skipping")
    elif status == "error":
        print(f"  WARNING: could not read {PORTAL_TOKENS_PARAM} ({err}) -- skipping")
    else:
        drift += _diff_portal_tokens(people, live_names)

    if drift:
        print(f"\n# DRIFT ({len(drift)})")
        for line in drift:
            print(f"  - {line}")
        return 1

    print("\n# no drift found")
    return 0


def _yn(v):
    return "yes" if v else "no"


def _diff_github(people, collaborators, invitations):
    drift = []
    seen = set()
    for p in people:
        gh_user = p.get("github")
        seen.add(gh_user)
        wants_access = p["access"]["github_repo"] != "none"
        role = collaborators.get(gh_user)
        invited = gh_user in invitations
        if wants_access and role is None and not invited:
            drift.append(f"[github] {p['id']}: yaml={p['access']['github_repo']}, github=not a collaborator, no pending invite")
        elif wants_access and role is not None and role != p["access"]["github_repo"]:
            drift.append(f"[github] {p['id']}: yaml={p['access']['github_repo']}, github={role}")
        elif not wants_access and (role is not None or invited):
            state = role or "invited"
            drift.append(f"[github] {p['id']}: yaml=none, github={state}")
    for login, role in collaborators.items():
        if login not in seen:
            drift.append(f"[github] {login}: not in team.yaml, github={role} (unexpected collaborator)")
    return drift


def _diff_ssh(people):
    drift = []
    labels = parse_authorized_keys()
    for p in people:
        wants = p["access"]["ssh"]
        label = _key_label_for(p)
        has = label is not None
        if wants != has:
            drift.append(
                f"[ssh] {p['id']}: yaml={_yn(wants)}, authorized_keys={'present' if has else 'absent'}"
            )
    known_labels = set()
    for p in people:
        known_labels.add(p["id"])
        if p.get("github"):
            known_labels.add(p["github"])
    for label in labels:
        if label not in known_labels:
            drift.append(f"[ssh] {label}: key in authorized_keys, no matching id/github in team.yaml")
    return drift


def _diff_portal_tokens(people, live_names):
    drift = []
    for p in people:
        wants = p["access"]["portal_token"]
        has = p["id"] in live_names
        if wants != has:
            drift.append(
                f"[portal_token] {p['id']}: yaml={_yn(wants)}, API_TOKENS={'present' if has else 'absent'}"
            )
    known_ids = {p["id"] for p in people}
    for name in live_names:
        if name not in known_ids:
            drift.append(f"[portal_token] {name}: token in API_TOKENS, no matching id in team.yaml (may be a service token, e.g. ci-smoke)")
    return drift


# --------------------------------------------------------------------------
# offboard
# --------------------------------------------------------------------------
def build_plan(person, repo):
    plan = {}

    if repo is None:
        plan["github"] = {"action": "skip", "reason": "could not determine origin repo"}
    else:
        ok, collaborators, invitations, err = github_state(repo)
        if not ok:
            plan["github"] = {"action": "skip", "reason": err}
        else:
            login = person.get("github")
            is_collab = login in collaborators
            invitation_id = invitations.get(login)
            if is_collab or invitation_id is not None:
                plan["github"] = {
                    "action": "remove",
                    "login": login,
                    "collaborator": is_collab,
                    "invitation_id": invitation_id,
                }
            else:
                plan["github"] = {"action": "noop", "reason": "not a collaborator, no pending invite"}

    label = _key_label_for(person)
    if label is not None:
        plan["ssh"] = {"action": "remove", "label": label}
    else:
        plan["ssh"] = {"action": "noop", "reason": "no key in ops/authorized_keys"}

    status, live_names, err = portal_tokens_state()
    if status in ("no-creds", "error"):
        plan["portal_token"] = {"action": "skip", "reason": err}
    elif status == "not-found":
        plan["portal_token"] = {"action": "skip", "reason": f"{PORTAL_TOKENS_PARAM} not found"}
    elif person["id"] in live_names:
        plan["portal_token"] = {"action": "remove", "name": person["id"]}
    else:
        plan["portal_token"] = {"action": "noop", "reason": "no named token found"}

    return plan


def rotate_items(person):
    """Driven by real access only -- e.g. aws: none means the AWS account
    genuinely never existed for this person (didn't just get reduced to
    none), so nothing about it belongs on their rotate list."""
    a = person["access"]
    items = []

    if a["ssh"]:
        items.append(
            "Old box .env: DB_PASSWORD -- already burned/rotated per FINDINGS.md SEC-04, "
            "listed because they had shell access to read it"
        )

    # Same key, don't list it twice if both paths to it apply.
    messaging_key_reason = None
    if a["ssh"]:
        messaging_key_reason = "readable in the old box's .env, shell access"
    elif a["messaging_dashboard"]:
        messaging_key_reason = "visible from the messaging provider's dashboard"
    if messaging_key_reason:
        items.append(f"Messaging provider API key (MESSAGING_KEY) -- already burned per FINDINGS.md SEC-04, {messaging_key_reason}")

    if a.get("legacy_gcp") in ("editor", "owner"):
        items.append(
            f"GCP service-account key (sa-key.json) -- already burned per FINDINGS.md SEC-05, "
            f"readable at {a['legacy_gcp']} level on the old project"
        )

    if a["aws"] in ("admin", "readonly"):
        items.append(f"AWS backendlab-production ({a['aws']}): review/rotate anything reachable via that account's SSM SecureStrings")

    if a["portal_token"]:
        items.append("(Their own portal token is being revoked as part of this offboarding -- not a rotate item for anyone else)")

    return items


def print_plan(person, plan):
    print(f"# offboard plan: {person['id']} ({person['name']}, {person['role']})")
    for system, entry in plan.items():
        action = entry["action"]
        if action == "remove":
            detail = {k: v for k, v in entry.items() if k != "action"}
            print(f"  [{system}] REMOVE  {detail}")
        elif action == "noop":
            print(f"  [{system}] no-op   ({entry['reason']})")
        else:
            print(f"  [{system}] SKIP    ({entry['reason']})")

    print("\n  manual checklist:")
    legacy_gcp = person["access"].get("legacy_gcp", "none")
    for system, todo, owner in MANUAL_CHECKLIST:
        print(f"    - [{system}] {todo.format(name=person['name'], legacy_gcp=legacy_gcp)}  (owner: {owner})")

    items = rotate_items(person)
    print("\n  rotate:")
    if items:
        for item in items:
            print(f"    - {item}")
    else:
        print("    (none -- this person's access level doesn't reach any shared secret)")


def _who_ran_this():
    for var in ("GITHUB_ACTOR", "USER", "USERNAME"):
        if os.environ.get(var):
            return os.environ[var]
    try:
        out = subprocess.run(
            ["git", "config", "user.email"], cwd=ROOT, capture_output=True, text=True, check=True
        ).stdout.strip()
        if out:
            return out
    except Exception:
        pass
    return "unknown"


def _set_status_left(person_id, end_date):
    """Targeted text edit, not a full parse+reserialize -- team.yaml's
    comments are the point of the file, and a generic YAML dump would
    throw every one of them away."""
    lines = TEAM_YAML.read_text().split("\n")
    start = None
    for i, line in enumerate(lines):
        if line.strip() == f"- id: {person_id}":
            start = i
            break
    if start is None:
        raise ValueError(f"could not find '- id: {person_id}' in {TEAM_YAML}")

    end = len(lines)
    for i in range(start + 1, len(lines)):
        if re.match(r"^\s{2}- id:\s", lines[i]):
            end = i
            break

    found_status = found_end_date = False
    for i in range(start, end):
        if re.match(r"^\s*status:\s*\S", lines[i]):
            lines[i] = re.sub(r"status:\s*\S+", "status: left", lines[i])
            found_status = True
        elif re.match(r"^\s*end_date:", lines[i]):
            indent = lines[i][: len(lines[i]) - len(lines[i].lstrip(" "))]
            lines[i] = f"{indent}end_date: {end_date}"
            found_end_date = True

    if not found_status:
        raise ValueError(f"no 'status:' line found in {person_id}'s block")
    if not found_end_date:
        # Insert right after status if team.yaml never had a placeholder.
        for i in range(start, end):
            if re.match(r"^\s*status:\s*\S", lines[i]):
                indent = lines[i][: len(lines[i]) - len(lines[i].lstrip(" "))]
                lines.insert(i + 1, f"{indent}end_date: {end_date}")
                break

    TEAM_YAML.write_text("\n".join(lines))


def cmd_offboard(args):
    team = load_team()
    person = find_person(team, args.id)
    if person is None:
        print(f"error: no such person in team.yaml: {args.id}", file=sys.stderr)
        return 2
    if person["status"] == "left":
        print(f"error: {args.id} is already marked left (end_date={person.get('end_date')})", file=sys.stderr)
        return 2

    repo = _repo_slug()
    plan = build_plan(person, repo)
    print_plan(person, plan)

    if not args.apply:
        print("\n(dry run -- pass --apply to actually make these changes)")
        return 0

    changes = {}
    if plan["github"]["action"] == "remove":
        changes["github"] = {**plan["github"], **github_remove(repo, plan["github"]["login"], plan["github"]["invitation_id"])}
    else:
        changes["github"] = plan["github"]

    if plan["ssh"]["action"] == "remove":
        removed = authorized_keys_remove(person)
        changes["ssh"] = {**plan["ssh"], "removed": removed}
    else:
        changes["ssh"] = plan["ssh"]

    if plan["portal_token"]["action"] == "remove":
        ok, err = portal_token_remove(person["id"])
        changes["portal_token"] = {**plan["portal_token"], "removed": ok, "error": err}
    else:
        changes["portal_token"] = plan["portal_token"]

    end_date = date.today().isoformat()
    _set_status_left(person["id"], end_date)
    changes["team_yaml"] = {"action": "status_set_left", "end_date": end_date}

    audit = {
        "date": datetime.now(timezone.utc).isoformat(),
        "offboarded": person["id"],
        "name": person["name"],
        "run_by": _who_ran_this(),
        "changes": changes,
        "manual_checklist": [
            {
                "system": s,
                "todo": t.format(name=person["name"], legacy_gcp=person["access"].get("legacy_gcp", "none")),
                "owner": o,
            }
            for s, t, o in MANUAL_CHECKLIST
        ],
        "rotate": rotate_items(person),
    }
    AUDIT_DIR.mkdir(parents=True, exist_ok=True)
    audit_path = AUDIT_DIR / f"{date.today().isoformat()}-offboard-{person['id']}.json"
    audit_path.write_text(json.dumps(audit, indent=2) + "\n")

    print(f"\napplied. audit record: {audit_path.relative_to(ROOT)}")
    return 0


def main():
    parser = argparse.ArgumentParser(prog="access.py")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("review")
    p_off = sub.add_parser("offboard")
    p_off.add_argument("id")
    p_off.add_argument("--apply", action="store_true")

    args = parser.parse_args()
    if args.command == "review":
        sys.exit(cmd_review(args))
    elif args.command == "offboard":
        sys.exit(cmd_offboard(args))


if __name__ == "__main__":
    main()
