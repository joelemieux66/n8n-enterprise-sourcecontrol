#!/usr/bin/env bash
#
# n8n-rollback.sh — surgical, auditable rollback of a single n8n workflow.
#
# The instance is not the source of truth; the branch is. This script rewinds
# ONE workflow file to a known-good commit, runs pre-flight checks for the
# things git cannot restore (credentials, variables, data tables, out-of-band
# edits), commits, pushes, and triggers a pull on the target n8n instance.
#
# Dependencies: git, curl, python3  (all present on GitHub-hosted runners)
#
set -euo pipefail

# ---------------------------------------------------------------- defaults --
WORKFLOW=""
TARGET="last-good"
ENV_NAME="${ENV_NAME:-prod}"
BRANCH=""
DO_PULL=1
DRY_RUN=0
ASSUME_YES=0
WFDIR="${WORKFLOWS_DIR:-workflows}"
CREDDIR="${CREDENTIALS_DIR:-credential_stubs}"
DTDIR="${DATATABLES_DIR:-datatables}"
VARFILE="${VARIABLES_FILE:-variable_stubs.json}"

C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
C_DIM=$'\033[2m';  C_BLD=$'\033[1m'; C_OFF=$'\033[0m'
[[ -t 1 ]] || { C_RED=""; C_GRN=""; C_YEL=""; C_DIM=""; C_BLD=""; C_OFF=""; }

say()  { printf '%s\n' "$*"; }
info() { printf '%s→%s %s\n' "$C_DIM" "$C_OFF" "$*"; }
ok()   { printf '%s✓%s %s\n' "$C_GRN" "$C_OFF" "$*"; }
warn() { printf '%s!%s %s\n' "$C_YEL" "$C_OFF" "$*"; WARNINGS=$((WARNINGS+1)); }
die()  { printf '%s✗ %s%s\n' "$C_RED" "$*" "$C_OFF" >&2; exit 1; }
rule() { printf '%s%s%s\n' "$C_DIM" "────────────────────────────────────────────────────────" "$C_OFF"; }
WARNINGS=0

usage() {
  cat <<'EOF'
Usage: n8n-rollback.sh --workflow <name|id> [options]

  -w, --workflow <name|id>  Workflow to roll back. Accepts the display name
                            ("Customer Onboarding") or the n8n workflow ID.
  -t, --to <ref>            Target to restore. A commit SHA, a tag
                            (prod-2026-08-14), or "last-good" (default) which
                            means "the commit before the most recent change
                            to this workflow".
  -e, --env <name>          Environment label used in the commit message and
                            for choosing the pull target. Default: prod.
  -b, --branch <name>       Branch to operate on. Default: current branch.
                            Not valid with --dry-run — check the branch out
                            first, so the plan is computed against the same
                            tree the apply will act on.
      --no-pull             Commit and push, but do not trigger the n8n pull.
      --dry-run             Show the full plan and all checks. Touches nothing.
  -y, --yes                 Skip the confirmation prompt (CI mode).
  -h, --help                This.

Environment:
  N8N_BASE_URL     e.g. https://n8n.prod.example.com   (for drift check + pull)
  N8N_API_KEY      public API key for that instance
  WORKFLOWS_DIR    default: workflows
  CREDENTIALS_DIR  default: credential_stubs
  DATATABLES_DIR   default: datatables
  VARIABLES_FILE   default: variable_stubs.json
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -w|--workflow) WORKFLOW="${2:-}"; shift 2;;
    -t|--to)       TARGET="${2:-}";   shift 2;;
    -e|--env)      ENV_NAME="${2:-}"; shift 2;;
    -b|--branch)   BRANCH="${2:-}";   shift 2;;
    --no-pull)     DO_PULL=0; shift;;
    --dry-run)     DRY_RUN=1; shift;;
    -y|--yes)      ASSUME_YES=1; shift;;
    -h|--help)     usage; exit 0;;
    *) die "unknown argument: $1  (try --help)";;
  esac
done

[[ -n "$WORKFLOW" ]] || { usage; die "--workflow is required"; }
command -v git     >/dev/null || die "git not found"
command -v python3 >/dev/null || die "python3 not found"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not inside a git repository"

# ------------------------------------------------------------- json helper --
# jq is not guaranteed everywhere; python3 is. Reads JSON on stdin.
pyq() { python3 -c "$1"; }

json_name() {  # stdin: workflow json -> display name
  pyq 'import json,sys;print(json.load(sys.stdin).get("name",""))'
}
json_nodes() { # stdin: workflow json -> one "Node Name  (node.type)" per line, sorted
  pyq 'import json,sys
d=json.load(sys.stdin)
for n in sorted(d.get("nodes") or [],key=lambda x:x.get("name","")):
    print("%s  (%s)"%(n.get("name",""),n.get("type","")))'
}
json_cred_names() { # stdin: workflow json -> "id<TAB>name"
  pyq 'import json,sys
d=json.load(sys.stdin);out={}
for n in d.get("nodes") or []:
    for c in (n.get("credentials") or {}).values():
        if isinstance(c,dict) and c.get("id"): out[c["id"]]=c.get("name","?")
for k,v in sorted(out.items()): print("%s\t%s"%(k,v))'
}
json_datatable_ids() { # stdin: workflow json -> "id<TAB>label" for dataTable nodes
  pyq 'import json,sys
d=json.load(sys.stdin);out={}
def walk(v):
    if isinstance(v,dict):
        for k,x in v.items():
            if k in ("dataTableId","tableId") and isinstance(x,dict) and x.get("value"):
                out[str(x["value"])]=str(x.get("cachedResultName") or "?")
            elif k in ("dataTableId","tableId") and isinstance(x,str) and x:
                out.setdefault(x,"?")
            else: walk(x)
    elif isinstance(v,list):
        for x in v: walk(x)
for n in d.get("nodes") or []:
    if "dataTable" in (n.get("type") or ""): walk(n.get("parameters") or {})
for k,v in sorted(out.items()): print("%s\t%s"%(k,v))'
}
json_version_id() {
  pyq 'import json,sys;print(json.load(sys.stdin).get("versionId","") or "")'
}
json_content_sig() { # stdin: workflow json -> hash of what actually runs
  # Deliberately ignores versionId, meta, and ordering. A revision that differs
  # only in versionId is not a different workflow, and treating it as one makes
  # "last-good" stop at a rewrite of the same broken version.
  pyq 'import json,sys,hashlib
d=json.load(sys.stdin)
nodes=sorted(
    (str(n.get("name","")), str(n.get("type","")), json.dumps(n.get("parameters") or {},sort_keys=True,default=str))
    for n in (d.get("nodes") or [])
)
payload=json.dumps({"nodes":nodes,"connections":d.get("connections") or {}},sort_keys=True,default=str)
print(hashlib.sha256(payload.encode()).hexdigest()[:12])'
}
json_node_sig() { # stdin: workflow json -> stable signature of the node set
  pyq 'import json,sys,hashlib
d=json.load(sys.stdin)
sig="\n".join(sorted("%s|%s"%(n.get("name",""),n.get("type","")) for n in (d.get("nodes") or [])))
print(hashlib.sha256(sig.encode()).hexdigest()[:12])'
}
json_var_keys() { # stdin: variable stub file -> keys
  pyq 'import json,sys
d=json.load(sys.stdin)
d=d if isinstance(d,list) else d.get("variables",[])
print("\n".join(sorted(x.get("key","") for x in d if isinstance(x,dict))))'
}

# ------------------------------------------------------------ branch setup --
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [[ -n "$BRANCH" && "$BRANCH" != "$CURRENT_BRANCH" ]]; then
  # A dry run deliberately does not switch branches, so planning against a
  # branch you are not on would silently report the wrong tree.
  [[ $DRY_RUN -eq 0 ]] || die "--dry-run cannot switch branches (on '$CURRENT_BRANCH', asked for '$BRANCH'). Check out $BRANCH first, then re-run."
  info "switching to branch $C_BLD$BRANCH$C_OFF"
  git checkout "$BRANCH" >/dev/null
  CURRENT_BRANCH="$BRANCH"
fi
if [[ $DRY_RUN -eq 0 ]] && ! git diff --quiet HEAD 2>/dev/null; then
  die "working tree is dirty. Commit or stash first — rollback must be an isolated commit."
fi
info "fetching origin"
git fetch --quiet origin || warn "could not fetch origin (offline?) — operating on local refs"
if git rev-parse --verify --quiet "origin/$CURRENT_BRANCH" >/dev/null; then
  behind=$(git rev-list --count "HEAD..origin/$CURRENT_BRANCH")
  [[ "$behind" -eq 0 ]] || die "local $CURRENT_BRANCH is $behind commit(s) behind origin. Pull first."
fi

[[ -d "$WFDIR" ]] || die "workflow directory '$WFDIR' not found. Set WORKFLOWS_DIR to match your repo layout."

# -------------------------------------------------------- resolve workflow --
WF_FILE=""
if [[ -f "$WFDIR/$WORKFLOW.json" ]]; then
  WF_FILE="$WFDIR/$WORKFLOW.json"
else
  matches=()
  while IFS= read -r f; do
    [[ -f "$f" ]] || continue
    n=$(json_name < "$f" 2>/dev/null || true)
    if [[ "$n" == "$WORKFLOW" ]]; then matches+=("$f"); fi
  done < <(find "$WFDIR" -maxdepth 1 -name '*.json' | sort)

  if [[ ${#matches[@]} -eq 1 ]]; then
    WF_FILE="${matches[0]}"
  elif [[ ${#matches[@]} -gt 1 ]]; then
    say "${C_RED}Multiple workflows named '$WORKFLOW':${C_OFF}"
    for m in "${matches[@]}"; do say "  $(basename "$m" .json)"; done
    die "re-run with the workflow ID instead of the name"
  else
    say "${C_RED}No workflow matched '$WORKFLOW'.${C_OFF} Closest names:"
    while IFS= read -r f; do
      n=$(json_name < "$f" 2>/dev/null || true)
      if [[ -n "$n" ]]; then printf '%s\n' "$n|$(basename "$f" .json)"; fi
    done < <(find "$WFDIR" -maxdepth 1 -name '*.json' | sort) \
      | { grep -iF -- "${WORKFLOW:0:6}" || true; } | head -8 \
      | awk -F'|' '{printf "  %-45s %s\n",$1,$2}'
    exit 1
  fi
fi
WF_ID=$(basename "$WF_FILE" .json)
WF_NAME=$(json_name < "$WF_FILE")

# ---------------------------------------------------------- resolve target --
if [[ "$TARGET" == "last-good" ]]; then
  # "last-good" = the most recent version of this file that (a) differs from
  # what is deployed right now and (b) has not already been rejected by an
  # earlier rollback. Without (b), rolling back twice in a row re-deploys the
  # exact version you just rolled back from — the classic yo-yo.
  REJECTED=$(git log --format=%B -- "$WF_FILE" \
             | sed -n 's/^rolled-back-from:[[:space:]]*//p' | sort -u || true)
  # Reject by content, not by commit id. The same bad workflow can sit in more
  # than one commit (a reformat, a versionId rewrite, a cherry-pick), and a
  # SHA-keyed guard only rejects the one commit whose id landed in a trailer —
  # then happily offers you its twin on the next run.
  REJECTED_SIGS=""
  if [[ -n "$REJECTED" ]]; then
    while IFS= read -r rsha; do
      [[ -n "$rsha" ]] || continue
      rsig=$(git show "$rsha:$WF_FILE" 2>/dev/null | json_content_sig 2>/dev/null || true)
      [[ -n "$rsig" ]] && REJECTED_SIGS+="$rsig"$'\n'
    done <<< "$REJECTED"
  fi
  # Compare what runs, not the bytes. A commit that only rewrote versionId (or
  # reformatted the file) is not an earlier version to roll back to.
  HEAD_SIG=$(json_content_sig < "$WF_FILE")
  SHA=""
  while IFS= read -r c; do
    [[ -n "$c" ]] || continue
    short_c=$(git rev-parse --short "$c")
    if [[ -n "$REJECTED" ]] && grep -qxF -- "$short_c" <<<"$REJECTED"; then
      continue                                   # explicitly rolled back before
    fi
    csig=$(git show "$c:$WF_FILE" 2>/dev/null | json_content_sig 2>/dev/null || true)
    [[ -n "$csig" && "$csig" != "$HEAD_SIG" ]] || continue
    if [[ -n "$REJECTED_SIGS" ]] && grep -qxF -- "$csig" <<<"$REJECTED_SIGS"; then
      continue                     # same content as something already rejected
    fi
    SHA="$c"; break
  done < <(git log --format=%H -- "$WF_FILE")
  if [[ -z "$SHA" ]]; then
    say "${C_RED}No earlier version of '$WF_NAME' is eligible.${C_OFF}"
    say "  Every prior version is either identical to what is live, or has already"
    say "  been rolled back. This file has $(git log --oneline -- "$WF_FILE" | wc -l | tr -d ' ') commit(s) in its history."
    say "  Pass an explicit SHA or tag with --to, or seed a change first:"
    say "    ${C_DIM}./scripts/demo-seed-break.sh --workflow '$WF_NAME'${C_OFF}"
    exit 1
  fi
else
  SHA=$(git rev-parse --verify --quiet "${TARGET}^{commit}") || die "cannot resolve ref '$TARGET'. Tags are only created by the prod-deploy tagger; run 'git fetch --tags' or pass a SHA."
  git cat-file -e "$SHA:$WF_FILE" 2>/dev/null || die "'$WF_FILE' did not exist at $TARGET"
fi
SHORT=$(git rev-parse --short "$SHA")
CUR_SHA=$(git log -n 1 --format=%H -- "$WF_FILE")

if [[ "$(git show "$SHA:$WF_FILE" | json_content_sig)" == "$(json_content_sig < "$WF_FILE")" ]]; then
  ok "'$WF_NAME' already runs the same nodes, parameters, and connections as $SHORT. Nothing to do."
  exit 0
fi

# ------------------------------------------------------------------ report --
rule
say "${C_BLD}Rollback plan${C_OFF}   ${C_DIM}env=$ENV_NAME branch=$CURRENT_BRANCH${C_OFF}"
rule
printf '  %-12s %s\n' "workflow"  "$WF_NAME"
printf '  %-12s %s\n' "id"        "$WF_ID"
printf '  %-12s %s\n' "file"      "$WF_FILE"
printf '  %-12s %s\n' "current"   "$(git log -n1 --format='%h  %s  (%an, %ar)' "$CUR_SHA")"
printf '  %-12s %s\n' "restoring" "$(git log -n1 --format='%h  %s  (%an, %ar)' "$SHA")"
say ""

say "${C_BLD}Node-level change${C_OFF}"
before=$(mktemp); after=$(mktemp)
git show "HEAD:$WF_FILE" | json_nodes > "$before"
git show "$SHA:$WF_FILE"  | json_nodes > "$after"
if diff -q "$before" "$after" >/dev/null; then
  say "  ${C_DIM}same node set — change is in parameters/connections only${C_OFF}"
else
  { diff "$before" "$after" || true; } | grep -E '^[<>]' | sed \
    -e "s/^< /  ${C_RED}removed${C_OFF}  /" \
    -e "s/^> /  ${C_GRN}restored${C_OFF} /"
fi
rm -f "$before" "$after"
say ""

# ------------------------------------------------------------ pre-flight ----
say "${C_BLD}Pre-flight checks${C_OFF} ${C_DIM}(the things git cannot restore)${C_OFF}"

# 1. Credentials: a stub present at the old commit but absent at HEAD means the
#    credential was deleted. The workflow will restore, then fail at runtime.
if [[ -d "$CREDDIR" ]]; then
  missing=0
  while IFS=$'\t' read -r cid cname; do
    [[ -n "$cid" ]] || continue
    if ! git cat-file -e "HEAD:$CREDDIR/$cid.json" 2>/dev/null; then
      warn "credential not in repo: $cname ($cid) — re-enter the secret on $ENV_NAME after pull"
      missing=$((missing+1))
    fi
  done < <(git show "$SHA:$WF_FILE" | json_cred_names)
  if [[ $missing -eq 0 ]]; then ok "all referenced credentials still exist in the repo"; fi
else
  info "no $CREDDIR/ directory — skipping credential check"
fi

# 2. Variables: $vars.FOO referenced by the restored version must still be
#    declared. Only worth reporting when the workflow actually uses $vars.
used=$(git show "$SHA:$WF_FILE" | grep -oE '\$vars\.[A-Za-z0-9_]+' | sed 's/^\$vars\.//' | sort -u || true)
if [[ -z "$used" ]]; then
  ok "no \$vars references in this workflow — nothing to check"
elif git cat-file -e "HEAD:$VARFILE" 2>/dev/null; then
  declared=$(git show "HEAD:$VARFILE" | json_var_keys 2>/dev/null || true)
  missing=0
  for v in $used; do
    grep -qxF "$v" <<<"$declared" || { warn "variable \$vars.$v is not declared in $VARFILE"; missing=$((missing+1)); }
  done
  if [[ $missing -eq 0 ]]; then ok "all \$vars references are declared"; fi
else
  warn "workflow references \$vars ($(tr '\n' ' ' <<<"$used")) but $VARFILE is not in the repo — set VARIABLES_FILE, or populate these on $ENV_NAME by hand"
fi

# 3. Data tables: schemas sync, row data does not — and a forced pull deletes a
#    table that exists on the instance but not in the repo, rows included.
if [[ -d "$DTDIR" ]]; then
  dt_missing=0; dt_seen=0
  while IFS=$'\t' read -r tid tname; do
    [[ -n "$tid" ]] || continue
    dt_seen=$((dt_seen+1))
    if ! git cat-file -e "HEAD:$DTDIR/$tid.json" 2>/dev/null; then
      warn "data table not in repo: $tname ($tid) — a forced pull will not create it, and row data never syncs"
      dt_missing=$((dt_missing+1))
    fi
  done < <(git show "$SHA:$WF_FILE" | json_datatable_ids)
  if [[ $dt_seen -eq 0 ]]; then
    ok "workflow uses no data tables"
  elif [[ $dt_missing -eq 0 ]]; then
    ok "all $dt_seen referenced data table schema(s) present — rows still do not sync"
  fi
else
  info "no $DTDIR/ directory — skipping data table check"
fi

# 4. Drift: has anyone edited this workflow directly on the instance?
if [[ -n "${N8N_BASE_URL:-}" && -n "${N8N_API_KEY:-}" ]]; then
  live=$(curl -sS --max-time 15 -H "X-N8N-API-KEY: $N8N_API_KEY" \
          "${N8N_BASE_URL%/}/api/v1/workflows/$WF_ID" 2>/dev/null || true)
  if [[ -n "$live" ]] && grep -q '"versionId"' <<<"$live"; then
    live_v=$(json_version_id <<<"$live")
    repo_v=$(json_version_id < "$WF_FILE")
    # Two independent signals. versionId catches an edit made ON the instance
    # (n8n mints a new one). The node signature catches the case versionId
    # cannot see: the repo changed while the instance did not, so both sides
    # still carry the same versionId but the contents differ. Reporting "no
    # drift" there is worse than saying nothing.
    live_sig=$(json_node_sig <<<"$live")
    repo_sig=$(json_node_sig < "$WF_FILE")
    if [[ "$live_sig" != "$repo_sig" ]]; then
      warn "$ENV_NAME is NOT running what the repo says it is"
      warn "  node sets differ (instance $live_sig, repo HEAD $repo_sig)"
      if [[ "$live_v" == "$repo_v" ]]; then
        warn "  versionId matches on both sides ($live_v), so this is a repo-side change"
        warn "  the instance never pulled — check its Source Control connection"
      else
        warn "  someone edited this workflow outside source control; the pull will overwrite it"
      fi
    elif [[ -n "$live_v" && -n "$repo_v" && "$live_v" != "$repo_v" ]]; then
      warn "instance drift: $ENV_NAME is running versionId $live_v, repo HEAD says $repo_v"
      warn "  same nodes, but the versions differ — parameters may have been edited on the instance"
    else
      ok "no drift — $ENV_NAME matches repo HEAD (nodes $repo_sig, version $repo_v)"
    fi
  else
    warn "could not read workflow from $N8N_BASE_URL (bad key, or workflow not yet on this instance)"
  fi
else
  info "N8N_BASE_URL / N8N_API_KEY unset — skipping drift check and pull"
  DO_PULL=0
fi

say ""
if [[ $WARNINGS -gt 0 ]]; then
  say "${C_YEL}${WARNINGS} warning(s). Read them before continuing.${C_OFF}"
else
  ok "clean — safe to roll back"
fi
rule

if [[ $DRY_RUN -eq 1 ]]; then
  say "${C_DIM}dry run — no changes made.${C_OFF}"
  exit 0
fi

if [[ $ASSUME_YES -eq 0 ]]; then
  read -r -p "Roll back '$WF_NAME' on $ENV_NAME to $SHORT? [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]] || { say "aborted."; exit 1; }
fi

# --------------------------------------------------------------- execute ----
git checkout "$SHA" -- "$WF_FILE"
git add "$WF_FILE"

ACTOR="${GITHUB_ACTOR:-$(git config user.name || echo unknown)}"
git commit --quiet -m "rollback($ENV_NAME): $WF_NAME → $SHORT" -m "$(cat <<EOF
workflow-name: $WF_NAME
workflow-id:   $WF_ID
rolled-back-from: $(git rev-parse --short "$CUR_SHA")
restored-to:      $SHORT
requested-by:     $ACTOR
warnings:         $WARNINGS
EOF
)"
NEW_SHA=$(git rev-parse --short HEAD)
ok "committed $NEW_SHA"

if ! git push --quiet origin "$CURRENT_BRANCH"; then
  say ""
  say "${C_RED}Push to origin/$CURRENT_BRANCH was rejected.${C_OFF}"
  say "  Rollback pushes a commit straight to the environment branch — that is what"
  say "  makes it one action instead of a PR round-trip. If GitHub branch protection"
  say "  requires a PR on $CURRENT_BRANCH, either allow this actor to bypass it, or"
  say "  re-run with --no-pull and open the PR yourself."
  say "  The commit is local at $NEW_SHA; 'git reset --hard HEAD~1' discards it."
  exit 1
fi
ok "pushed to origin/$CURRENT_BRANCH"

if [[ $DO_PULL -eq 1 ]]; then
  info "pulling into $ENV_NAME ($N8N_BASE_URL)"
  "$(dirname "$0")/n8n-pull.sh"
fi

rule
ok "'$WF_NAME' rolled back to $SHORT on $ENV_NAME"
say "  audit:  git show $NEW_SHA"
say "  undo:   ./scripts/n8n-rollback.sh -w '$WF_NAME' -t $(git rev-parse --short "$CUR_SHA") -e $ENV_NAME"
if [[ $WARNINGS -gt 0 ]]; then say "  ${C_YEL}$WARNINGS warning(s) above still need manual follow-up.${C_OFF}"; fi
exit 0
