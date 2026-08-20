# n8n Environments Demo — Dev → Staging → Prod

This repo demonstrates n8n's Enterprise **Source Control & Environments** feature: promoting workflows across three separate n8n instances (Dev, Staging, Prod) using Git as the transport layer. Push is manual (from Dev); pull into Staging and Prod is automated — a merged PR triggers the target instance to pull itself, with no one logging in to click Pull.

## What this shows

- A single workflow change made in Dev, pushed to Git, and automatically pulled into Staging and then Prod on PR merge — no manual re-import, copy/paste, or logging in to click Pull.
- Environment-specific values (credentials, variables) staying isolated per instance while workflow logic promotes cleanly.
- A realistic branch/PR gate between environments, so promotion isn't just a button — it's reviewable, and the review (the merge) is what actually fires the deploy.

## Architecture

```
┌──────────┐   push    ┌─────────────┐   PR + merge   ┌─────────┐
│   Dev    │ ────────► │  (feature/  │ ─────────────► │ staging │
│ instance │           │  dev branch)│  ─── webhook ─►│ branch  │
└──────────┘           └─────────────┘        │       └─────────┘
                                │             │
                                              ▼             │ auto
                                    GitHub PR Merge Webhook  │ pull
                                     (promotion pipeline)    ▼
                                               │      ┌──────────────┐
                                               │      │   Staging    │
                                               │      │   instance   │
                                               │      └──────────────┘
                                               │
                                               │   PR + merge   ┌──────┐
                                               └──────────────► │ main │
                                                    webhook ───►│branch│
                                                        │       └──────┘
                                                        ▼ auto
                                                        pull
                                                        │
                                                        ▼
                                                 ┌──────────────┐
                                                 │     Prod     │
                                                 │   instance   │
                                                 └──────────────┘
```

Each n8n instance connects to **one branch** of this repo (multi-instance, multi-branch pattern): Staging tracks `staging`, Prod tracks `main`. The review/approval gate is still the GitHub PR — merging is what matters. What's different from the vanilla setup is what happens *after* merge: a GitHub webhook fires a promotion-pipeline workflow (`workflows/github-to-n8n-environment-promotion.json` in this repo) that calls the target instance's Source Control pull API automatically, so nobody has to log into Staging or Prod and click Pull.

## Repo structure

```
.
├── workflows/
│   ├── github-to-n8n-environment-promotion.json   # the promotion pipeline itself
│   └── ...                                        # demo workflows pushed from Dev
├── credential_stubs/    # ID, name, type only — no secret values
├── variable_stubs/      # names only — no values
├── tags/
└── README.md
```

Note: the promotion pipeline workflow lives in Git like any other workflow, but it doesn't run on Dev, Staging, or Prod. It runs on a separate orchestrator/automation instance (or wherever your GitHub webhooks land) that has network access to the Staging and Prod internal API endpoints and holds its own `Staging API` / `Prod API` header-auth credentials. Keep that instance out of the Dev→Staging→Prod promotion chain — it's infrastructure, not an environment.

## Prerequisites

- n8n Enterprise license active on all three instances (Source Control is an Enterprise-only feature)
- A private Git repo (public exposes workflow logic, credential stubs, and variable names)
- One deploy key / SSH key pair per instance, or a shared key with write access
- Instance owner/admin access on Dev, Staging, and Prod to configure Source Control

## Setup

1. **Create the repo** with an initial README (so branches can be created against it), then create `staging` and `main` branches. Dev can push to a feature or working branch that gets PR'd into `staging`.
2. **On the Dev, Staging, and Prod n8n instances**, go to Settings → Environments (Source Control), connect the repo URL, add the SSH key, and select that instance's branch (Staging → `staging`, Prod → `main`).
3. **Populate credentials and variables locally on each instance.** These are never synced by value — only stubs (ID/name/type for credentials, name for variables) travel through Git. After every pull that introduces a new stub, you'll need to fill in the real value on that instance before the workflow will run.
4. Do an initial push from Dev to establish baseline state in Git.
5. **Import and activate the promotion pipeline** (`workflows/github-to-n8n-environment-promotion.json`) on your orchestrator instance. Configure a GitHub webhook on the repo for `pull_request` events pointing at that workflow's webhook URL, and set the `Staging API` / `Prod API` credentials to valid n8n API keys for each target instance.

## Promotion flow (what to run in a demo)

1. Make a visible change to a workflow in the **Dev** instance.
2. In Dev, open the Push dialog, select the workflow, write a commit message, and push. Note: n8n pushes the *saved* version, not the *published* version — call this out if the demo includes activation state.
3. In your Git provider, open a PR into `staging`, merge it. **Don't touch Staging.** Within seconds the merge webhook fires, the pipeline calls Staging's pull API, and the workflow shows up on its own — this is the "automatic reflection" moment worth pausing on.
4. If Staging introduces new credential/variable stubs, populate their real values on the Staging instance before running the workflow.
5. Open a PR into `main`, merge it. Same thing happens against Prod — no login, no manual pull.
6. Pull up the pipeline's own execution log (or the webhook response) to show the branch, PR number, and pulled files it acted on — good evidence the promotion was driven by the merge, not a person clicking around.

## Automated promotion pipeline

`workflows/github-to-n8n-environment-promotion.json` is what makes pulls automatic. It's a webhook-triggered n8n workflow:

1. **GitHub PR Merge Webhook** — receives GitHub's `pull_request` event payload.
2. **Was PR Merged?** — filters out closed-but-not-merged PRs (those get logged and get a no-op response).
3. **Route by Target Branch** — switches on `pull_request.base.ref`: `staging` → pull Staging, `main` → pull Prod, anything else → logged and ignored.
4. **Pull Staging / Pull Prod Instance** — calls that instance's `POST /api/v1/source-control/pull` (the public API endpoint, header-auth'd with a per-instance API key) with `force: true` and `autoPublish: "all"`. Both parameters are legitimate documented options on this endpoint — `force` skips the local-changes confirmation prompt (needed for unattended runs), and `autoPublish: "all"` republishes affected workflows after pulling instead of leaving that as a separate manual step.
5. **Format Result / Respond** — returns environment, branch, PR number, and pulled files back to GitHub as the webhook response; a failed pull returns a 502 with the upstream error instead of failing silently.

This is the same pattern n8n's own docs point to for hands-off production pulls (a GitHub Action or webhook calling the API on merge) — this repo just implements the webhook receiver as an n8n workflow instead of a GitHub Action.

## Things to call out when demoing this

- **Credentials and variables never sync by value** — only stubs. This is by design (security), not a gap. Each environment holds its own secrets.
- **No in-app review step.** The approval gate is your Git provider's PR process — the merge is the trigger, n8n never asks "are you sure" once the pipeline is live.
- **`force: true` means no confirmation prompt.** If a data table exists on the target instance but not in Git, a forced pull deletes it (including row data) without asking first. Worth a caveat in the demo, not just a footnote.
- **One-directional flow only.** Don't push and pull on the same instance in the same cycle — it can overwrite local changes. Content should move Dev → Staging → Prod, never backward.
- **Data table schemas sync, row data does not.**
- Tags sync automatically with workflow pushes.

## Reference

- [n8n Docs: Source control and environments](https://docs.n8n.io/source-control-environments/)
- [n8n Docs: Push and pull — what gets committed](https://docs.n8n.io/source-control-environments/using/push-pull/)
- [n8n Docs: Tutorial — create environments with source control](https://docs.n8n.io/administer/use-source-control-and-environments/tutorial-create-environments-with-source-control)
