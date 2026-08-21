#!/usr/bin/env bash
#
# demo-seed-break.sh — plant a reproducible "bad version" of a workflow.
#
# Rollback demos need a break to roll back FROM, and `--to last-good` needs at
# least two versions of the file in git history. This script removes one real
# integration node and drops a no-op in its place, so the rollback plan shows a
# clean node-level diff:
#
#     removed  Get PR diff  (n8n-nodes-base.github)
#     restored Get PR diff  (n8n-nodes-base.github)     <- after rollback
#
# It commits (and optionally pushes) so the break is a real prior version, not
# a dirty working tree. Reversing it is the demo itself.
#
set -euo pipefail

WORKFLOW=""
NODE=""
BRANCH=""
DO_PUSH=0
ALLOW_DEV=0
WFDIR="${WORKFLOWS_DIR:-workflows}"

usage() {
  cat <<'EOF'
Usage: demo-seed-break.sh --workflow <name|id> [options]

  -w, --workflow <name|id>  Workflow to break.
  -n, --node <node name>    Node to remove. Default: the first third-party
                            integration node found (the kind a buyer notices).
  -b, --branch <name>       Branch to commit on. Default: current branch.
      --push                Push after committing (triggers the deploy pull).
      --list                List candidate nodes for --workflow and exit.
      --allow-dev           Permit seeding on the dev branch. Refused by
                            default: a push to dev gets promoted to staging
                            automatically (promotion PR + CI auto-merge), so a
                            break seeded there does not stay on dev. Seed on
                            main for a prod rollback demo.
  -h, --help                This.
EOF
}

LIST_ONLY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -w|--workflow) WORKFLOW="${2:-}"; shift 2;;
    -n|--node)     NODE="${2:-}";     shift 2;;
    -b|--branch)   BRANCH="${2:-}";   shift 2;;
    --push)        DO_PUSH=1; shift;;
    --list)        LIST_ONLY=1; shift;;
    --allow-dev)   ALLOW_DEV=1; shift;;
    -h|--help)     usage; exit 0;;
    *) echo "unknown argument: $1" >&2; exit 1;;
  esac
done
[[ -n "$WORKFLOW" ]] || { usage; echo "✗ --workflow is required" >&2; exit 1; }

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "✗ not a git repository" >&2; exit 1; }

if [[ -n "$BRANCH" ]]; then
  git checkout "$BRANCH" >/dev/null
fi

# Seeding on dev does not stay on dev. A push to dev opens a promotion PR into
# staging, CI auto-merges it, and the merge webhook pulls the break into the
# staging instance — so the "bad version" escapes the environment you meant to
# break. Seed on main when the demo rolls back prod.
CUR_BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [[ "$CUR_BRANCH" == "dev" && $ALLOW_DEV -eq 0 && $LIST_ONLY -eq 0 ]]; then
  echo "✗ refusing to seed a break on 'dev'." >&2
  echo "  A push to dev is promoted to staging automatically, so the break will not" >&2
  echo "  stay here. For a prod rollback demo, seed on main:" >&2
  echo "    ./scripts/demo-seed-break.sh --workflow '$WORKFLOW' --branch main --push" >&2
  echo "  Pass --allow-dev if you really mean to seed on dev." >&2
  exit 1
fi

# --list only reads; it does not need a clean tree.
if [[ $LIST_ONLY -eq 0 ]]; then
  git diff --quiet HEAD || { echo "✗ working tree is dirty — commit or stash first" >&2; exit 1; }
fi

# ---- resolve the workflow file (name or id), same rules as n8n-rollback.sh --
WF_FILE=""
if [[ -f "$WFDIR/$WORKFLOW.json" ]]; then
  WF_FILE="$WFDIR/$WORKFLOW.json"
else
  while IFS= read -r f; do
    n=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("name",""))' "$f" 2>/dev/null || true)
    [[ "$n" == "$WORKFLOW" ]] && WF_FILE="$f" && break
  done < <(find "$WFDIR" -maxdepth 1 -name '*.json' | sort)
fi
[[ -n "$WF_FILE" ]] || { echo "✗ no workflow matched '$WORKFLOW'" >&2; exit 1; }

# ---- rewrite the JSON -------------------------------------------------------
python3 - "$WF_FILE" "$NODE" "$LIST_ONLY" <<'PY'
import json, sys, re, uuid

path, want_node, list_only = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
doc = json.load(open(path))
nodes = doc.get("nodes") or []

# A node worth breaking is one a buyer recognizes: a third-party integration,
# not scaffolding. Exclude core control-flow/no-op types and sticky notes.
CORE = re.compile(
    r"\.(set|if|switch|noOp|code|merge|stickyNote|splitInBatches|filter|"
    r"executeWorkflow|executeWorkflowTrigger|manualTrigger|scheduleTrigger|"
    r"webhook|respondToWebhook|wait|stopAndError|aggregate|limit|sort|"
    r"removeDuplicates|dateTime|html|xml|extractFromFile|convertToFile)$"
)
def is_integration(n):
    t = n.get("type") or ""
    if "stickyNote" in t or CORE.search(t):
        return False
    return t.startswith("n8n-nodes-base.")

cands = [n for n in nodes if is_integration(n)]

if list_only:
    for n in cands:
        print("  %-40s %s" % (n.get("name"), n.get("type")))
    if not cands:
        print("  (no third-party integration nodes in this workflow)")
    sys.exit(0)

if want_node:
    target = next((n for n in nodes if n.get("name") == want_node), None)
    if target is None:
        print("✗ no node named %r. Try --list." % want_node, file=sys.stderr)
        sys.exit(1)
else:
    if not cands:
        print("✗ no third-party integration node to break; pass --node explicitly (--list to see options).",
              file=sys.stderr)
        sys.exit(1)
    target = cands[0]

old_name = target["name"]
new_name = "%s (BROKEN)" % old_name
if any(n.get("name") == new_name for n in nodes):
    print("✗ %r already exists — this workflow is already seeded." % new_name, file=sys.stderr)
    sys.exit(1)

# Swap the node for a no-op at the same position, keeping the graph valid.
replacement = {
    "id": target.get("id"),
    "name": new_name,
    "type": "n8n-nodes-base.noOp",
    "typeVersion": 1,
    "position": target.get("position", [0, 0]),
    "parameters": {},
}
doc["nodes"] = [replacement if n is target else n for n in nodes]

# A real edit in n8n mints a new versionId. Preserving the old one makes the
# rollback plan's drift check compare two identical versions and report "no
# drift" for a workflow whose contents differ entirely — false comfort at
# exactly the wrong moment.
if doc.get("versionId"):
    doc["versionId"] = str(uuid.uuid4())

# Rename every reference to the node: connection source keys and destinations.
conns = doc.get("connections") or {}
if old_name in conns:
    conns[new_name] = conns.pop(old_name)
for outputs in conns.values():
    if not isinstance(outputs, dict):
        continue
    for group in outputs.values():
        if not isinstance(group, list):
            continue
        for branch in group:
            if not isinstance(branch, list):
                continue
            for link in branch:
                if isinstance(link, dict) and link.get("node") == old_name:
                    link["node"] = new_name
doc["connections"] = conns

with open(path, "w") as fh:
    json.dump(doc, fh, indent=2, ensure_ascii=False)
    fh.write("\n")

print("BROKE\t%s\t%s\t%s" % (doc.get("name"), old_name, target.get("type")))
PY

[[ $LIST_ONLY -eq 0 ]] || exit 0

WF_NAME=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("name",""))' "$WF_FILE")
git add "$WF_FILE"
git commit --quiet -m "Replace integration step in $WF_NAME" -m \
"Seeded by demo-seed-break.sh. This is the version the demo rolls back FROM."
echo "✓ committed $(git rev-parse --short HEAD) on $(git rev-parse --abbrev-ref HEAD)"

if [[ $DO_PUSH -eq 1 ]]; then
  git push --quiet origin "$(git rev-parse --abbrev-ref HEAD)"
  echo "✓ pushed — the connected instance will pull this break"
fi

cat <<EOF

Next:
  ./scripts/n8n-rollback.sh --workflow "$WF_NAME" --env prod --dry-run
EOF
