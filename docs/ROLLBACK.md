# Rollback — 3 environments, one-click revert

A working GitOps rollback story for n8n source control, wired to *this* repo.
Built to be demoed live in about six minutes.

**The thesis you are selling:** every automation platform has "versioning."
Almost all of it is a proprietary list of snapshots inside the vendor's own UI.
n8n's is a git repo, which means rollback is not a feature you wait for — it is
`git checkout`, plus the safety checks that only matter because the platform is
real.

---

## What is in here

```
.github/workflows/
  rollback.yml            one-click rollback: plan -> gated apply -> automatic backport PR
  promote.yml             dev -> staging -> main as a PR, with a workflow diff by name
  tag-prod-deploy.yml     tags every prod deploy prod-YYYY-MM-DD-HHMM (does not pull)
  validate-promotion.yml  lints changed workflow JSON, validates against live dev,
                          auto-merges into staging only
scripts/
  n8n-rollback.sh         the workhorse. Resolves the workflow, runs pre-flight
                          checks, commits, pushes, triggers the pull.
  n8n-pull.sh             POST /api/v1/source-control/pull, with error messages
                          that name the actual cause.
  demo-seed-break.sh      plants a reproducible "bad version" to roll back from.
```

Dependencies: `git`, `curl`, `python3`. No jq, no Node, nothing to install on a
GitHub-hosted runner.

### One pull mechanism, not two

Deploy pulls are **not** done from Actions. Merging a PR fires GitHub's
`pull_request` webhook into the promotion pipeline
([workflows/VjZ8UMkT85Bp2mZX.json](../workflows/VjZ8UMkT85Bp2mZX.json)), which
calls the target instance's pull API. `tag-prod-deploy.yml` deliberately only
tags — if it also pulled, every prod merge would fire two pulls at the same
instance.

Rollback is the exception: `n8n-rollback.sh` calls the pull API itself, because
it pushes straight to the environment branch rather than going through a PR, so
there is no merge webhook to ride on.

`n8n-pull.sh` sends `force: true, autoPublish: "all"` — the same pair the
promotion pipeline sends. `autoPublish` matters: without it the pull updates the
*saved* version and leaves the *published* version alone, so a rollback looks
applied in the editor while the active version is still broken. That is a
mid-demo failure that looks like the product is lying.

## Branch and environment model

| Branch | Instance | Gate on the merge | n8n-side setting |
|---|---|---|---|
| `dev` | dev n8n | none — this is where people build | — |
| `staging` | staging n8n | CI lints + validates, then auto-merges | — |
| `main` | prod n8n | a human merges the PR | *branch is protected* → workflows read-only in the UI |

Each branch is connected to exactly one n8n instance. The branch is the source
of truth; the instance is a projection of it.

**Two different things are both called "protected," and only one of them is
safe here.** n8n's *branch is protected* setting makes workflows read-only in
that instance's UI — that is the Beat 1 story, and you want it on for prod.
GitHub *branch protection* requiring a PR on `main` is a different setting, and
it will reject the rollback push, because rollback pushes a commit directly to
the branch on purpose. If you want both, give the rollback actor a bypass. The
approval gate for rollback is the GitHub Environment reviewer, not a PR.

## Setup

**GitHub side.** Two separate pieces: where the credentials live, and where the
gate lives.

*Credentials — repository level, keyed by environment* (Settings → Secrets and
variables → Actions):

| Kind | Names |
|---|---|
| Variables | `N8N_BASE_URL_DEV`, `N8N_BASE_URL_STAGING`, `N8N_BASE_URL_PROD` |
| Secrets | `N8N_DEV_API_KEY`, `N8N_STAGING_API_KEY`, `N8N_PROD_API_KEY` |

Each key is a public API key from an owner/admin user on that instance — source
control endpoints are owner-scoped.

These are deliberately **not** environment-scoped secrets. GitHub only exposes
environment secrets to a job that declares `environment:`, and the plan job must
not declare one — binding it to `prod` would make the plan wait for the same
approval you are trying to inform. Environment-scoped secrets mean the plan job
reads no URL and no key, and silently skips the drift check, which is the single
most valuable line in the plan. Keying them at repo level is what lets plan and
apply read the same instance and never disagree.

The trade-off, stated plainly because a security reviewer will find it: any job
in this repo can read the prod key, including the ungated plan job. If your
threat model needs the prod key gated behind the approval, move it to an
environment secret and accept that the plan can no longer do the drift check —
you would find out about instance drift after approving rather than before.

*The gate — environment level.* Create three Environments (Settings →
Environments): `dev`, `staging`, `prod`. They need no variables or secrets. On
`prod`, add yourself as a **required reviewer**. That is what makes the apply job
pause for approval, which is the single best thirty seconds of this demo.

Note that environment protection rules need a public repo, or GitHub Pro/Team on
a private one. On GitHub Free, making this repo private silently deletes the
required-reviewer rule and the gate stops pausing, with no error.

**n8n side.** On each instance, Settings → Source Control: connect the repo, set
the branch, and on prod tick *branch is protected*.

**Repo visibility.** This repo is currently public. Workflow logic, credential
stub names, and data table schemas are all readable in it. Make it private
before you point a customer at it.

**Repo layout.** The scripts default to what this repo actually contains:
`workflows/<id>.json`, `credential_stubs/<id>.json`, `datatables/<id>.json`.
There is no `variable_stubs.json` here and no workflow uses `$vars`, so the
variable check reports "no `$vars` references" and moves on — it wakes up on its
own if that changes. Override with `WORKFLOWS_DIR`, `CREDENTIALS_DIR`,
`DATATABLES_DIR`, `VARIABLES_FILE` if a future n8n version writes a different
layout; that layout has shifted across versions, so re-check before you assert
it on a call.

---

## The demo — six minutes

**Setup before the call.**

1. Three browser tabs: prod n8n, the GitHub Actions tab, the repo's commit history.
2. Seed the break, so there is a bad version in prod to roll back *from* and a
   good version in history to roll back *to*:

   ```bash
   ./scripts/demo-seed-break.sh --workflow "DevOps — GitHub PR Review (multi-agent)" --branch main --push
   ```

   That swaps the `Get PR diff` GitHub node for a no-op and commits it. Push
   propagates it to prod, so you start from a broken prod rather than building
   up to one. `--list` shows the other integration nodes if you want a different
   one.

   Without this step `--to last-good` correctly refuses: 15 of the 16 workflow
   files have exactly one commit in their history, and there is no earlier
   version to restore.

**Beat 1 — establish the break (45s).** Show prod. The `Get PR diff` step is
gone, replaced by a no-op that was never tested against their GitHub. Then show
the n8n UI: the workflow is read-only, because prod is a protected branch.

> "Notice I can't fix this here. That's deliberate. On a protected instance
> nobody hand-patches prod at 2am — which is exactly the property your change
> management policy is asking for, and exactly the property that makes rollback
> feel scary on most platforms."

**Beat 2 — the plan (90s).** Actions tab → *Rollback workflow* → Run workflow.
Type the workflow name, pick `prod`, leave target as `last-good`, tick *plan
only* on the first pass.

Let the plan job finish and open the summary. Walk it line by line:

- which commit is live, which one is being restored, who authored each and when
- the **node-level diff** — "Get PR diff (BROKEN) removed, Get PR diff
  restored." Not a JSON blob. The thing the reviewer actually needs to know.
- the **pre-flight checks**. This is the part to slow down on.

> "Git restores the workflow definition. It does not restore four things, and
> every one of them is a real outage I've seen. Credentials: the secret was
> never in the repo — only a reference to it. If someone deleted that credential
> last week, this rollback succeeds and then fails at runtime. Variables, same
> logic. Data tables: schemas sync, rows never do, and a forced pull deletes a
> table that isn't in git. And drift — we ask the instance what version it is
> actually running and compare it to what the repo thinks. If someone got around
> the protection, you find out now."

This repo gives you a genuine, unstaged hit here: the workflow's GitHub nodes
reference credential `NVmbTZ3qsmlwk6Ls` ("GitHub account"), which has no stub
file in `credential_stubs/`. The plan warns about it on its own. Use it — an
unscripted warning firing on a real repo lands better than a clean green wall.

**Beat 3 — the gate (30s).** Re-run without *plan only*. The apply job goes to
`Waiting`. Show the approval prompt.

> "This is a GitHub Environment gate. Your existing approvers, your existing
> audit log. We didn't build an approval system — we inherited yours."

Approve it.

**Beat 4 — the apply (60s).** Watch it run. Then switch to the repo's commit
history and open the rollback commit:

```
rollback(prod): DevOps — GitHub PR Review (multi-agent) → ca6bc02

workflow-name: DevOps — GitHub PR Review (multi-agent)
workflow-id:   IFb3KgtlXlj8VUK0
rolled-back-from: 56b3516
restored-to:      ca6bc02
requested-by:     jlemieux
warnings:         1
```

> "That's the audit artifact. Who, what, when, from what to what, and whether it
> shipped with known warnings — in the same system your engineers already review,
> retained as long as your repo is."

**Beat 5 — the payoff (45s).** Refresh prod n8n. The GitHub step is back, and
it is back in the *published* version, not just the editor. One file changed;
nothing else in the promotion was disturbed.

> "One workflow. That commit last Tuesday bundled nine workflows — a full revert
> would have taken the other eight down with it. Git-native means file-level
> granularity for free."

**Beat 6 — the thing nobody demos (60s).** Point at the third job: a backport PR
to `dev` opened automatically.

> "Here's the failure I actually care about. You roll back prod, everyone
> relaxes, and two weeks later someone promotes from dev — which still has the
> broken version — and the same outage happens again. Everyone hits this. So the
> rollback isn't finished until dev agrees with prod, and we open that PR for
> you."

---

## Questions you will get

**"What if two people roll back at once?"** The `concurrency` group in
`rollback.yml` serializes per environment. Second run queues behind the first.

**"What if the instance was edited directly?"** The drift check catches it and
warns before the pull. Pull is a force-overwrite, so the instance edit is lost —
which is the correct behavior on a protected instance, but you want to know first.

**"Can we roll back to an arbitrary point in time?"** Yes — pass a SHA or a tag.
`tag-prod-deploy.yml` tags every prod deploy `prod-YYYY-MM-DD-HHMM`, so `--to
prod-2026-08-14-1132` works. Note that tags only exist from the first prod
deploy *after* that workflow lands; before then, use SHAs. `git fetch --tags`
if a tag will not resolve locally.

**"Does this need the enterprise tier?"** Source control and environments are
enterprise features; the public API and protected instances come with them. Be
straight about this rather than letting them discover it in procurement.

**"What about credentials?"** Values never enter the repo. Only stubs. That is a
selling point — say it before they ask, because the alternative reading is that
rollback is incomplete.

**"Why does rollback skip the PR when promotion doesn't?"** Because the point of
rollback is that it is one action during an incident. The review still happens —
it is the Environment approval on the apply job, before anything is pushed.
Promotion is planned work and gets a PR; rollback is unplanned and gets a gate.

## Running it locally

```bash
export N8N_BASE_URL=https://n8n-prod.example.com
export N8N_API_KEY=...

git checkout main
./scripts/n8n-rollback.sh --workflow "DevOps — GitHub PR Review (multi-agent)" --env prod --dry-run
./scripts/n8n-rollback.sh --workflow "DevOps — GitHub PR Review (multi-agent)" --env prod
./scripts/n8n-rollback.sh -w IFb3KgtlXlj8VUK0 -t prod-2026-08-14-1132 -e prod --no-pull
```

`--dry-run` touches nothing — safe to run live in front of anyone. It refuses
`--branch`, on purpose: a plan computed against a branch you are not on would
report the wrong diff. Check the branch out first.

With `N8N_BASE_URL` / `N8N_API_KEY` unset, the drift check and the pull are
skipped and the run says so — you still get the full plan, which is what makes
this safe to rehearse offline.

## A note on `last-good`

`--to last-good` means: the most recent version that differs from what is
currently deployed **and** has not already been rejected by a previous rollback.
The second half matters. Naive "previous version" logic re-deploys the exact
thing you just rolled back from the moment you run it twice. The script reads its
own `rolled-back-from:` trailers to avoid the yo-yo, and refuses with a clear
message rather than guessing when nothing is eligible.

Worth mentioning out loud if you get a git-literate reviewer in the room. It is
the detail that signals this was built by someone who has actually done it.
