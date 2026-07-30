# Wellis Take-Home — Replatform & Harden `wellis-status`

**Role:** DevOps / Platform Engineer
**Deadline:** 7 days from receipt · **Follow-up:** 90-minute deep-dive on your submission

---

## 1. The scenario

Wellis runs a medically supervised weight-care programme in the Netherlands. A
handful of engineers keep the whole stack alive between them. One of the tools
they keep alive is `wellis-status`: a small internal service the care team uses
to look patients up and queue appointment reminders.

It works. It is also held together by hand. It runs on a single VM someone
built by clicking through a console, it deploys by copying files off a laptop,
secrets are sitting in the repo, and if it started failing right now nobody
would know until the care team complained. There is a real database with real
(synthetic) patient records behind it.

You are the first infrastructure hire. Your job is to turn this from something
that runs by luck into something that runs on purpose, and to make it safer
while you do it.

All patient data in this repo is synthetic. No real person appears in it.

---

## 2. What you're given

The `wellis-status/` repo, with its real commit history. Start with its
`RUNBOOK.md` — the handover memo from the people who have been running it. It is
honest about a few things they know are rough. It is not a complete list.
Part of this assignment is finding what the memo didn't mention. Assume
nothing; check everything.

The repo runs locally today (see its README). Two services over one Postgres
database: a Node/Express `portal` and a Python `notifier`.

---

## 3. What to do

You will not finish all of this in a week, and we are not asking you to. We are
asking to see **how you decide what comes first** when it's infrastructure,
security, and plumbing at once, with patient data in the middle. Do the work
that matters most, and write up the rest.

### Part A — Read the system and triage it

Before you change anything, understand what you inherited. Produce a
**`FINDINGS.md`**: everything you found wrong or risky, each one marked as
one of **fixed / guardrailed / documented-only**, with a one-line reason. This
is the spine of your submission and the thing we read first. We care more about
what you *noticed* and how you *ranked* it than about how many you fixed.

### Part B — Infrastructure as code & portability

Bring the environment under version control. Provision it with Terraform,
OpenTofu, or Pulumi so it is reproducible, not click-ops. Containerise the
workloads and standardise how they deploy. Keep an eye on lock-in: where are we
welded to one provider, and what would it take to move? You don't have to make
it multi-cloud; you have to make the coupling a choice instead of an accident.

### Part C — CI/CD & release engineering

Build the pipeline that takes a merge to production safely: automated checks, a
build, a deploy, and the guardrails that let a small team ship often without
breaking things. There is a migration sitting in `migrations/` that has not
been run against production. Decide what your pipeline does with a change like
that.

### Part D — Observability & reliability

There is no monitoring today. Stand up the visibility layer from scratch:
metrics, logs, error tracking, at least one alert that would actually fire on a
real problem, and an uptime check. Enough that you'd catch an incident before
the care team does.

### Part E — Security, access & IT admin

Own access the way a company holding patient data has to. That means least
privilege for people and services, secrets managed properly, the database
hardened, and access that is reviewable rather than handed out ad hoc. Look at
who and what can reach this system today. And because onboarding/offboarding is
currently a checklist someone runs from memory, build at least one access
workflow as automation rather than a ticket: a joiner or a leaver handled end
to end by a script or agent.

---

## 4. How you work here

We're an AI-native engineering team. Agentic coding tools are how we work, and
infrastructure is no exception: Terraform written and reviewed with an agent,
runbooks that are actually scripts, an access request a workflow fulfils on its
own. Build this the way you'd build it here.

You must submit, alongside the work:

1. **Your full agent traces / session logs**, unedited. We read them.
2. A short **`AGENT-NOTES.md`** (~1 page): how you decomposed the work for the
   agent, where you let it run versus where you took the wheel, at least one
   concrete case where you rejected or corrected its output, and what you'd do
   differently.

We are not checking whether you used an agent. We are evaluating how you direct
one through decisions that carry weight: what to provision, what to lock down
first, what to refuse to automate blindly. An agent pointed at infrastructure
with no one steering produces confident, plausible, wrong systems. Your traces
should show us you were steering.

---

## 5. Deployment & evidence

Deploy it to a real cloud. Free tier is the target and should cost you nothing:
GCP Cloud Run, a free-tier Postgres (Supabase, Neon, or similar), GitHub
Actions for CI, and a free observability tier (Grafana Cloud, or self-hosted)
all fit. If you somehow incur a small charge, tell us and we'll cover it.

Right-sizing is part of the test. You do not need a Kubernetes cluster to run
two small services; reaching for one tells us something too.

Your submission is judged on evidence it actually runs, not prose:

- [ ] **A deployed URL** we can hit.
- [ ] **Repo access** with real commit history (don't squash it into one).
- [ ] **Visible CI runs.** We want to see the pipeline has actually executed,
      including at least one failure it caught and how it recovered.
- [ ] **`FINDINGS.md`** (Part A).
- [ ] **One-command local bring-up.** `git clone` then a single command
      (`make up` or equivalent) brings the whole stack up on our machine. For a
      DevOps role, your environment reproducing is itself part of the grade.
- [ ] **`README.md`** covering architecture, your IaC, and your key decisions
      with the reasoning behind them.
- [ ] **Agent traces + `AGENT-NOTES.md`** (§4).

If you can't or won't open a cloud account, the fallback is full local
reproduction plus a clean `terraform plan` against a real provider config. The
deployed path is preferred and shows more.

An optional 5–10 minute screen recording of the dashboards live and the
pipeline running is welcome. It covers anything awkward to re-run.

---

## 6. Scope judgment

There is no hour cap. Our calibration: a focused day of your attention,
amplified by agents, should produce something substantial. Use agents to go
further, not longer.

Cut scope deliberately and say so in `FINDINGS.md` ("I documented X instead of
fixing it because Y"). Choosing what *not* to do in week one is a senior skill
and we grade it as one. A smaller change set where every fix is trustworthy
beats a sprawling one that loosened a control to make something work.

---

## 7. What the 90-minute follow-up looks like

You walk us through it live: the deployed app, your pipeline, your dashboards.
Then we go deep on your `FINDINGS.md` and the order you worked in, look at a
couple of your fixes together, review parts of your agent traces with you, and
make one or two small change requests to discuss or implement. Nothing is a
trick. All of it is about choices you already made.

If anything is unclear before you start, ask. Sharp questions count in your
favour.
