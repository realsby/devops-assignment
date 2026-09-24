# Agent notes

## Setup

Claude Code, three roles:

- **Me (candidate):** platform decisions and approvals. AWS instead of GCP,
  Lambda instead of Fargate Spot (after comparing cost), Neon for Postgres,
  basic CloudWatch observability instead of a bigger stack, a mocked
  messaging provider, where alerts go. I also approved every `terraform
  apply` and every write to the prod database. Claude Code's auto mode stops
  those and asks.
- **Lead agent (Claude Opus 5.5):** planned the work, wrote every prompt to
  the subagent, reviewed every diff before committing, made all commits, ran
  every plan and apply, and did the cloud-side steps (ECR push, GitHub
  variables, seed, the Tomas offboarding run).
- **One subagent (Claude Sonnet 5):** implementation. It was one continuous
  conversation, continued task by task, so it kept context.

`agent-traces/` holds that lead-to-subagent conversation: raw JSONL plus a
rendered Markdown copy. It is unedited except for masked secret values
(see `agent-traces/README.md`).

## How the work was split

Eleven tasks, in this order, security before plumbing:

1. triage: FINDINGS.md
2. containment and code fixes: SQL injection, auth, notifier correctness, PII
3. containers and `make up`
4. CI
5. migration 003
6. Terraform
7. access as code
8. CD
9. monitoring
10. docs
11. fixes to the access review found on the first live run

Each task went out with the decisions already made, for example "app DB
roles must not be `neon_role`, API-created roles join `neon_superuser`" or
"003 stays broken until CI judges it". Each ended with "don't commit, list
what you guessed". The subagent never had apply rights: plan and validate
only, all live changes went through the lead and my approval.

## Where it ran and where the lead took the wheel

The subagent ran free on app code, tests, Dockerfiles, workflows, scripts
and docs. The lead took over for anything that touches real systems or
carries weight:

- reading each Terraform plan before applying (checking for no destroy and
  no replace on the imported Neon project)
- the bootstrap state move
- the OIDC trust fix
- setting a project-scoped Neon key for CI instead of the personal one
- running the real offboarding so the audit record is genuine

## Output that was rejected or corrected

- **Triage missed things.** The first FINDINGS.md draft did not notice that
  the notifier ignores `send_at` (reminders go out early), that staging uses
  the *live* messaging key, that receipts hold PHI, or the lock risk in
  migration 003. It also proposed a git history rewrite as the fix for the
  leaked key. Sent back: rotation is the fix, and a rewrite un-leaks nothing.
- **"Tests pass" on the wrong runtime.** It pinned `psycopg2-binary==2.9.9`
  and tested on Python 3.11. Lambda runs 3.13, where that version has no
  wheel. Bumped the pins and re-tested on 3.13. Same review: the `pg` Pool
  had no `'error'` listener, which crashes Node when Neon drops idle
  connections.
- **An unverified claim.** It said gitleaks "should exit 0 once committed".
  It didn't, because inline `gitleaks:allow` only covers commits after it.
  Fixed with fingerprints, and asked it to separate what it verified from
  what it reasoned.
- **Confident wrong data.** Its `team.yaml` gave Tomas AWS admin and a
  portal token, neither of which existed when he left. So the offboarding
  "rotate" list pointed at an AWS account he never touched. Rewritten from
  his real access.
- **Too generous with "fixed".** It marked backups (INFRA-02) as fixed, but
  there's only 6h of Neon PITR and no restore drill, so it's now
  guardrailed. It also claimed "per-person deploys via OIDC", which isn't
  true because CI deploys as one role.
- **A miss we both made.** The deploy role trusted the classic OIDC `sub`
  (`repo:owner/repo:ref:...`). GitHub now issues immutable subjects for this
  repo, so the first migrate run failed on AssumeRole. Fixed in `e5ae13e`.
- **CI could cancel a deploy halfway.** The workflow-level
  `cancel-in-progress: true` also applied to runs on main, so a quick
  second push could stop a run between updating the portal and the
  notifier. Now only PR runs get cancelled, and deploys are serialised.

## What I refused to automate blindly

- Prod migrations: manual `workflow_dispatch` plus a Neon branch rehearsal,
  and the deploy refuses to run ahead of the schema.
- `terraform apply`: from a laptop with MFA, not CI.
- The offboarding `--apply`: the subagent only ever ran dry-runs.
- The access script never *adds* a GitHub user, because the names in
  TEAM.md may belong to real strangers.

## What I'd do differently

- Give the subagent a read-only AWS role from the start. MFA-only access
  meant it could validate but never plan, so plan-level mistakes surfaced
  late, on my side.
- Make it check live API shapes (Neon branches, OIDC claims) before writing
  code against them, not after.
- Smaller Terraform tasks. One big task made the review slow.
- Pin actions to SHAs, and add dependency scanning (npm/pip audit) to CI.
